import Foundation
import Darwin
import JottieModels

public struct TranscriptImportReport: Sendable {
    public var imported = 0
    public var unchanged = 0
    public var failures: [String] = []
    public init() {}
}

enum TranscriptDocuments {
    static let extensions: Set<String> = ["md", "markdown", "txt", "doc", "docx"]
    struct Scan { var files: [URL] = []; var legacy: [URL] = []; var failures: [String] = [] }
    static func scan(_ roots: [URL], excluding library: URL) throws -> Scan {
        var result = Scan(), seen = Set<String>()
        let fm = FileManager.default
        let libraryPath = library.resolvingSymlinksInPath().path
        func excluded(_ url: URL) -> Bool {
            let path = url.resolvingSymlinksInPath().path
            return path == libraryPath || path.hasPrefix(libraryPath + "/")
        }
        func legacy(_ url: URL) -> Bool {
            fm.fileExists(atPath: url.appendingPathComponent("transcript.json").path)
                && fm.fileExists(atPath: url.appendingPathComponent("meta.json").path)
        }
        for root in roots {
            guard !excluded(root) else { continue }
            let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { continue }
            if values.isDirectory != true {
                if extensions.contains(root.pathExtension.lowercased()), seen.insert(root.standardizedFileURL.path).inserted { result.files.append(root) }
                continue
            }
            if legacy(root) {
                if seen.insert(root.standardizedFileURL.path).inserted { result.legacy.append(root) }
                continue
            }
            guard let iterator = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { url, _ in
                result.failures.append("Could not read \(url.lastPathComponent)"); return true
            }) else { continue }
            var scanned = 0
            while let url = iterator.nextObject() as? URL {
                scanned += 1
                guard scanned <= 100_000 else { throw JottieError.invalid("Import folder is too large. Choose a smaller subtree.") }
                let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if excluded(url) || values.isSymbolicLink == true { iterator.skipDescendants(); continue }
                if values.isDirectory == true {
                    if legacy(url) {
                        if seen.insert(url.standardizedFileURL.path).inserted { result.legacy.append(url) }
                        iterator.skipDescendants()
                    }
                } else if extensions.contains(url.pathExtension.lowercased()), seen.insert(url.standardizedFileURL.path).inserted {
                    result.files.append(url)
                }
            }
        }
        return result
    }
    static func text(_ url: URL) throws -> (text: String, digest: String) {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 32_000_000 else { throw JottieError.invalid("Document exceeds 32 MB.") }
        let bytes = try Data(contentsOf: url)
        let digest = Codec.hash(bytes)
        if ["doc", "docx"].contains(url.pathExtension.lowercased()) {
            return (try wordText(url, bytes: bytes), digest)
        }
        if let text = String(data: bytes, encoding: .utf8) { return (text, digest) }
        if bytes.starts(with: [0xff, 0xfe]) || bytes.starts(with: [0xfe, 0xff]), let text = String(data: bytes, encoding: .utf16) { return (text, digest) }
        throw JottieError.invalid("Use a UTF-8 or UTF-16 text document.")
    }
    /// Native macOS conversion runs locally, with bounded time and output; binaries are never copied into the library.
    private static func wordText(_ url: URL, bytes: Data) throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("jottie-word-import-\(UUID())")
        try LibraryStore.directory(dir)
        defer { try? FileManager.default.removeItem(at: dir) }
        let output = dir.appendingPathComponent("transcript.txt")
        let input = dir.appendingPathComponent("source." + url.pathExtension.lowercased())
        try bytes.write(to: input, options: .atomic)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
        process.arguments = ["-convert", "txt", "-format", url.pathExtension.lowercased(), "-encoding", "UTF-8", "-noload", "-strip", "-output", output.path, "--", input.path]
        process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(20)
        while process.isRunning {
            let size = (try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? NSNumber)?.intValue ?? 0
            if Task.isCancelled || Date() > deadline || size > 64_000_000 {
                process.terminate()
                let until = Date().addingTimeInterval(1)
                while process.isRunning && Date() < until { Thread.sleep(forTimeInterval: 0.02) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
                throw JottieError.unavailable("Word text extraction timed out or exceeded the size limit.")
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        guard process.terminationStatus == 0 else { throw JottieError.invalid("Could not read this Word document.") }
        let bytes = try Data(contentsOf: output)
        guard bytes.count <= 64_000_000, let text = String(data: bytes, encoding: .utf8) else { throw JottieError.invalid("Invalid Word text output.") }
        return text
    }
}
