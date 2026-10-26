import Foundation
import Darwin
import JottieModels

public protocol StructuredRunner: Sendable {
    func run(prompt: String, schema: Data) async throws -> Data
}

/// No shell interpolation, no inherited API keys, no tools, no transcript logs.
public struct CodexRunner: StructuredRunner {
    public let executable: String
    public var timeout: TimeInterval
    public var model: String
    public var effort: String
    public init(executable: String, timeout: TimeInterval = 1800, model: String = "", effort: String = "") {
        let value = executable.trimmingCharacters(in: .whitespacesAndNewlines)
        self.executable = value.isEmpty ? Self.discover() : NSString(string: value).expandingTildeInPath
        self.timeout = timeout
        self.model = model; self.effort = effort
    }
    public static func discover() -> String {
        CodexInstallation.discover()
    }
    public static func environment(_ values: [String: String] = ProcessInfo.processInfo.environment, executable: String? = nil) -> [String: String] {
        var result = values.filter { ["PATH", "HOME", "TMPDIR", "LANG", "LC_ALL", "USER", "LOGNAME", "CODEX_HOME", "SSL_CERT_FILE", "SSL_CERT_DIR"].contains($0.key) }
        // Node-based CLI installations need the same common executable locations as discovery.
        let paths = ["/opt/homebrew/bin", "/usr/local/bin", FileManager.default.homeDirectoryForCurrentUser.path + "/.local/bin", "/usr/bin", "/bin"]
        let executableDirectory = executable.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path }
        result["PATH"] = ([executableDirectory, values["PATH"]].compactMap { $0 } + paths).joined(separator: ":")
        return result
    }
    public func testConnection() async throws {
        let schema = Data(#"{"type":"object","properties":{"ready":{"type":"boolean","const":true}},"required":["ready"],"additionalProperties":false}"#.utf8)
        let data = try await run(prompt: "This is a Jottie connection test using invented data only. Return ready=true. Do not use tools.", schema: schema)
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any], result["ready"] as? Bool == true else {
            throw JottieError.invalid("Codex answered but did not return the expected connection-test result.")
        }
    }
    public static func arguments(schema: URL, output: URL, model: String = "", effort: String = "") -> [String] {
        var args = ["--no-daemon", "exec", "--ignore-user-config", "--ephemeral", "--skip-git-repo-check",
                    "--sandbox", "read-only", "--color", "never", "--json"]
        var configuration = ["forced_login_method=\"chatgpt\"", "model_provider=\"openai\"",
                             "approval_policy=\"never\"", "web_search=\"disabled\"", "project_doc_max_bytes=0"]
        configuration += ["shell_tool", "unified_exec", "apps", "plugins", "remote_plugin", "hooks",
                          "memories", "multi_agent", "browser_use", "browser_use_external", "computer_use",
                          "in_app_browser", "view_image", "image_generation", "code_mode", "code_mode_host",
                          "skill_search", "sleep_tool"].map { "features.\($0)=false" }
        configuration.append("features.skip_host_skill_discovery=true")
        if !model.isEmpty { args += ["--model", model] }
        if !effort.isEmpty { configuration.append("model_reasoning_effort=\"\(effort)\"") }
        for value in configuration { args += ["-c", value] }
        return args + ["--output-schema", schema.path, "-o", output.path, "-"]
    }
    public func run(prompt: String, schema: Data) async throws -> Data {
        guard LibrarySettings.efforts.contains(effort) else { throw JottieError.invalid("Choose a supported Codex reasoning effort in Settings.") }
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw JottieError.unavailable("Codex was not found. Choose its executable in Library Settings.")
        }
        let job = Task.detached(priority: .utility) { try execute(prompt: prompt, schema: schema) }
        return try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
    }
    private func execute(prompt: String, schema: Data) throws -> Data {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("jottie-analysis-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: dir) }
        let schemaURL = dir.appendingPathComponent("schema.json"), output = dir.appendingPathComponent("answer.json")
        try schema.write(to: schemaURL)
        // Files, rather than pipes, avoid deadlock on large input/output.
        func handle(_ name: String, data: Data = Data()) throws -> FileHandle {
            let path = dir.appendingPathComponent(name).path
            guard FileManager.default.createFile(atPath: path, contents: data, attributes: [.posixPermissions: 0o600])
            else { throw JottieError.unavailable("Cannot prepare analysis input.") }
            return try FileHandle(forUpdating: URL(fileURLWithPath: path))
        }
        let stdin = try handle("input", data: Data(prompt.utf8)), stdout = try handle("events"), stderr = try handle("errors")
        defer { try? stdin.close(); try? stdout.close(); try? stderr.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Self.arguments(schema: schemaURL, output: output, model: model, effort: effort)
        process.currentDirectoryURL = dir
        process.environment = Self.environment(executable: executable)
        process.standardInput = stdin; process.standardOutput = stdout; process.standardError = stderr
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        func terminate() {
            if process.isRunning { process.terminate() }
            let until = Date().addingTimeInterval(1)
            while process.isRunning && Date() < until { Thread.sleep(forTimeInterval: 0.02) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }
        while process.isRunning {
            if Task.isCancelled || Date() > deadline {
                terminate()
                throw JottieError.unavailable("Codex analysis was cancelled or timed out; retry when ready.")
            }
            let bytes = (try stdout.seekToEnd()) + (try stderr.seekToEnd())
            if bytes > 16_000_000 { terminate(); throw JottieError.invalid("Codex output exceeded the safety limit.") }
            Thread.sleep(forTimeInterval: 0.1)
        }
        guard process.terminationStatus == 0 else {
            let diagnostic = String(decoding: (try? Data(contentsOf: dir.appendingPathComponent("errors"))) ?? Data(), as: UTF8.self).lowercased()
            let message: String
            if diagnostic.contains("unexpected argument") || diagnostic.contains("unrecognized") {
                message = "Codex rejected the command-line options. Update the CLI or choose a compatible executable in Jottie Settings."
            } else if (diagnostic.contains("model") || diagnostic.contains("reasoning effort")) && (diagnostic.contains("not supported") || diagnostic.contains("not available") || diagnostic.contains("does not exist")) {
                message = "The selected Codex model or reasoning effort is unavailable. Choose a model supported by your account and retry."
            } else if diagnostic.contains("usage limit") || diagnostic.contains("quota") || diagnostic.contains("rate limit") {
                message = "Codex usage is currently limited. Retry after your allowance resets."
            } else if diagnostic.contains("unauthorized") || diagnostic.contains("not logged in") || diagnostic.contains("authentication") {
                message = "Codex could not authenticate. Sign in with ChatGPT using this executable, then retry."
            } else {
                message = "Codex could not complete analysis. Check its sign-in, connection and usage allowance, then retry."
            }
            // Do not expose raw CLI diagnostics, which may include private input or credentials.
            throw JottieError.unavailable(message)
        }
        try stdout.seek(toOffset: 0)
        let events = try stdout.readToEnd() ?? Data()
        for line in String(decoding: events, as: UTF8.self).split(separator: "\n") {
            guard let event = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let item = event["item"] as? [String: Any], let type = item["type"] as? String else { continue }
            guard !["command_execution", "mcp_tool_call", "web_search", "file_change"].contains(type) else {
                throw JottieError.invalid("Codex attempted a tool call; the result was rejected.")
            }
        }
        let data = try Data(contentsOf: output)
        guard data.count <= 8_000_000 else { throw JottieError.invalid("Analysis is too large.") }
        return data
    }
}

enum Schemas {
    static func object(_ properties: [String: Any]) -> [String: Any] {
        ["type": "object", "additionalProperties": false, "properties": properties, "required": properties.keys.sorted()]
    }
    static var string: [String: Any] { ["type": "string"] }
    static var nullable: [String: Any] { ["type": ["string", "null"]] }
    static func array(_ item: [String: Any]) -> [String: Any] { ["type": "array", "items": item] }
    static var evidence: [String: Any] { object(["segmentID": string, "quote": string]) }
    static func finding(_ statuses: [String]) -> [String: Any] {
        object(["id": string, "text": string, "status": ["type": "string", "enum": statuses],
                "owner": nullable, "dueDate": nullable, "evidence": array(evidence)])
    }
    static var analysis: Data {
        get throws {
            try JSONSerialization.data(withJSONObject: object([
                "schemaVersion": ["type": "integer", "const": 1], "title": string, "summary": string,
                "summaryEvidence": array(evidence), "topics": array(string), "tags": ["type": "array", "items": string, "maxItems": 10],
                "primaryTag": nullable, "decisions": array(finding(["proposed", "confirmed", "rejected", "superseded", "unclear"])),
                "actions": array(finding(["proposed", "committed", "in_progress", "blocked", "completed", "unclear"])),
                "questions": array(finding(["open", "resolved", "unclear"])), "uncertainties": array(string),
                "sensitivity": ["type": "string", "enum": ["normal", "sensitive", "uncertain"]]
                , "speakerCandidates": array(object(["label": string, "name": string, "evidence": array(evidence)]))
            ]))
        }
    }
    static var context: Data {
        get throws {
            let source = object(["meetingID": string, "revision": string, "segmentID": string])
            let entry = object(["id": string, "text": string, "status": string, "owner": nullable, "dueDate": nullable,
                                "sources": array(source)])
            return try JSONSerialization.data(withJSONObject: object(["overview": string, "sources": array(source),
                "decisions": array(entry), "actions": array(entry), "questions": array(entry), "recentChanges": array(entry)]))
        }
    }
}
