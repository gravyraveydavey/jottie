import Foundation
import Darwin
import JottieModels

/// Shared by capture diagnostics and the library; probes never submit meeting text.
public enum CodexInstallation {
    public struct ModelChoice: Sendable, Identifiable {
        public let id: String
        public let name: String
        public let efforts: [String]
    }
    public struct Status: Sendable {
        public let executable: String
        public let version: String?
        public let ready: Bool
        public let message: String
    }

    public static func candidates(environment: [String: String], home: String) -> [String] {
        let paths = (environment["PATH"] ?? "").split(separator: ":")
            .filter { $0.hasPrefix("/") }.map { String($0) + "/codex" }
        let standard = [home + "/.local/bin/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
        let bundles = ["/Applications", home + "/Applications"].flatMap { root in
            [root + "/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
             root + "/ChatGPT.app/Contents/Resources/codex",
             root + "/Codex.app/Contents/Resources/codex"]
        }
        var seen = Set<String>()
        return (paths + standard + bundles).filter { seen.insert($0).inserted }
    }

    public static func discover() -> String {
        let fm = FileManager.default
        let environment = ProcessInfo.processInfo.environment
        if let path = candidates(environment: environment, home: fm.homeDirectoryForCurrentUser.path)
            .first(where: { fm.isExecutableFile(atPath: $0) }) { return path }
        // Finder does not inherit a terminal's PATH (including Node version managers).
        let shell = environment["SHELL"] ?? getpwuid(getuid()).flatMap { $0.pointee.pw_shell.map { String(cString: $0) } } ?? "/bin/zsh"
        guard let result = try? command(shell, ["-lic", "command -v codex"], timeout: 8), result.status == 0 else { return "" }
        return result.output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .last { $0.hasPrefix("/") && fm.isExecutableFile(atPath: $0) } ?? ""
    }

    public static func probe(path: String = "") async -> Status {
        await Task.detached(priority: .utility) {
            let executable = CodexRunner(executable: path).executable
            guard !executable.isEmpty, FileManager.default.isExecutableFile(atPath: executable) else {
                return Status(executable: executable, version: nil, ready: false,
                              message: "Codex CLI was not found. Install it or choose its executable below.")
            }
            do {
                let version = try command(executable, ["--version"])
                guard version.status == 0, let line = version.output.split(separator: "\n").first(where: { $0.hasPrefix("codex") }) else {
                    return Status(executable: executable, version: nil, ready: false,
                                  message: "The selected executable did not answer as Codex CLI. Check its path and installation.")
                }
                let versionText = String(line.prefix(100))
                let login = try command(executable, ["--no-daemon", "login", "status"])
                let text = login.output.lowercased()
                let ready = login.status == 0 && text.contains("chatgpt") && text.contains("logged in")
                let message = ready ? "Codex CLI is installed and signed in with ChatGPT."
                    : text.contains("api key") || text.contains("api_key")
                    ? "Codex is using an API key. Sign in with ChatGPT to use your subscription for Jottie."
                    : "Codex is installed but ChatGPT sign-in could not be confirmed. Run this executable with ‘login’, then check again."
                return Status(executable: executable, version: versionText, ready: ready, message: message)
            } catch {
                return Status(executable: executable, version: nil, ready: false,
                              message: "Codex could not run or did not respond in time. Check its executable and try again.")
            }
        }.value
    }

    /// Read the selected CLI's bundled catalog locally; this does not spend model usage.
    public static func models(path: String) async -> [ModelChoice] {
        await Task.detached(priority: .utility) { () -> [ModelChoice] in
            guard let result = try? command(path, ["--no-daemon", "debug", "models", "--bundled"]), result.status == 0,
                  let start = result.output.firstIndex(of: "{"), let end = result.output.lastIndex(of: "}"),
                  let catalog = try? JSONSerialization.jsonObject(with: Data(result.output[start...end].utf8)) as? [String: Any],
                  let models = catalog["models"] as? [[String: Any]] else { return [] }
            var seen = Set<String>()
            return models.compactMap { item in
                guard let id = item["slug"] as? String, item["visibility"] as? String == "list", seen.insert(id).inserted else { return nil }
                let levels = (item["supported_reasoning_levels"] as? [[String: Any]] ?? []).compactMap { $0["effort"] as? String }.filter(LibrarySettings.efforts.contains)
                return ModelChoice(id: id, name: item["display_name"] as? String ?? id, efforts: levels)
            }
        }.value
    }

    /// Bounded file output avoids pipe deadlock; no authentication output is logged.
    private static func command(_ executable: String, _ arguments: [String], timeout: TimeInterval = 15) throws -> (status: Int32, output: String) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("jottie-codex-check-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: dir) }
        let output = dir.appendingPathComponent("output")
        guard FileManager.default.createFile(atPath: output.path, contents: Data(), attributes: [.posixPermissions: 0o600]) else { throw ProbeError.outputUnavailable }
        let handle = try FileHandle(forUpdating: output)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments; process.currentDirectoryURL = dir
        process.environment = CodexRunner.environment(executable: executable)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = handle; process.standardError = handle
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            let bytes = try handle.seekToEnd()
            if Task.isCancelled || Date() > deadline || bytes > 1_000_000 {
                process.terminate()
                let until = Date().addingTimeInterval(1)
                while process.isRunning && Date() < until { Thread.sleep(forTimeInterval: 0.02) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
                throw ProbeError.timedOut
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return (process.terminationStatus, String(decoding: try Data(contentsOf: output), as: UTF8.self))
    }

    private enum ProbeError: Error { case timedOut, outputUnavailable }
}
