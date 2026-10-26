import CryptoKit
import Darwin
import Foundation

protocol EchoCancellationBackend: AnyObject {
    var sampleRate: Int { get }
    var hopSize: Int { get }
    func process(microphone: [Float], reference: [Float]) throws -> [Float]
}

enum LocalVQEAssets {
    static let modelName = "localvqe-v1.4-aec-200K-f32.gguf"
    static let modelSHA256 = "b6e43138588a83bfe903ab5e143b4020b91c1e1629f5a575ac5855ff0003c731"
    static let processorVersion = "localvqe-v1.4-aec-200k-f32-jottie-v3"

    struct URLs {
        let library: URL
        let model: URL
    }

    static var areAvailable: Bool { (try? resolve()) != nil }

    /// A bundled CLI may have been reached through ~/.local/bin/jottie, so the
    /// app path comes from Runtime.appBundle rather than Bundle.main.
    static func resolve() throws -> URLs {
        let urls: URLs
        if let bundle = Runtime.appBundle {
            urls = URLs(
                library: bundle.bundleURL
                    .appendingPathComponent("Contents/Frameworks/liblocalvqe.dylib"),
                model: bundle.bundleURL
                    .appendingPathComponent("Contents/Resources/Models")
                    .appendingPathComponent(modelName))
        } else {
            let repository = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent() // Audio
                .deletingLastPathComponent() // jottie
                .deletingLastPathComponent() // Sources
                .deletingLastPathComponent() // repository
            let root = repository.appendingPathComponent(".build/localvqe")
            urls = URLs(
                library: root.appendingPathComponent("lib/liblocalvqe.dylib"),
                model: root.appendingPathComponent("model").appendingPathComponent(modelName))
        }
        guard FileManager.default.isReadableFile(atPath: urls.library.path) else {
            throw EchoCancellationError.missingAsset(urls.library)
        }
        guard FileManager.default.isReadableFile(atPath: urls.model.path) else {
            throw EchoCancellationError.missingAsset(urls.model)
        }
        return urls
    }
}

enum EchoCancellationError: Error, CustomStringConvertible {
    case missingAsset(URL)
    case invalidModel(URL)
    case nativeLibrary(URL, String)
    case missingSymbol(String)
    case modelLoad(String)
    case unsupportedFormat(sampleRate: Int, hopSize: Int)
    case invalidFrame(expected: Int, microphone: Int, reference: Int)
    case processing(code: Int32, message: String)
    case invalidOutput
    case alreadyFinished

    var description: String {
        switch self {
        case .missingAsset(let url):
            return "LocalVQE asset is missing: \(url.path)"
        case .invalidModel(let url):
            return "LocalVQE model failed its SHA-256 check: \(url.path)"
        case .nativeLibrary(let url, let message):
            return "could not load LocalVQE library at \(url.path): \(message)"
        case .missingSymbol(let name):
            return "LocalVQE library is missing required symbol \(name)"
        case .modelLoad(let message):
            return "could not load the LocalVQE echo model: \(message)"
        case .unsupportedFormat(let sampleRate, let hopSize):
            return "unsupported LocalVQE format: \(sampleRate) Hz, \(hopSize)-sample hops"
        case .invalidFrame(let expected, let microphone, let reference):
            return "LocalVQE needs \(expected) samples per hop; got mic \(microphone), reference \(reference)"
        case .processing(let code, let message):
            return "LocalVQE processing failed (\(code)): \(message)"
        case .invalidOutput:
            return "LocalVQE returned non-finite audio"
        case .alreadyFinished:
            return "LocalVQE stream was already finished"
        }
    }
}

/// Dynamically loaded so SwiftPM can build and test without linking a
/// machine-specific binary. `make localvqe` creates the universal dylib that
/// `make app` embeds and signs beside Sparkle.
private final class LocalVQEBackend: EchoCancellationBackend {
    private typealias New = @convention(c) (UnsafePointer<CChar>?) -> UInt
    private typealias Free = @convention(c) (UInt) -> Void
    private typealias Process = @convention(c) (
        UInt, UnsafePointer<Float>?, UnsafePointer<Float>?, Int32,
        UnsafeMutablePointer<Float>?
    ) -> Int32
    private typealias IntegerProperty = @convention(c) (UInt) -> Int32
    private typealias LastError = @convention(c) (UInt) -> UnsafePointer<CChar>?
    private typealias SetNoiseGate = @convention(c) (UInt, Int32, Float) -> Int32

    let sampleRate: Int
    let hopSize: Int

    private let library: UnsafeMutableRawPointer
    private let context: UInt
    private let freeContext: Free
    private let processFrame: Process
    private let lastError: LastError

    init(libraryURL: URL, modelURL: URL) throws {
        let model = try Data(contentsOf: modelURL, options: .mappedIfSafe)
        let digest = SHA256.hash(data: model).map { String(format: "%02x", $0) }.joined()
        guard digest == LocalVQEAssets.modelSHA256 else {
            throw EchoCancellationError.invalidModel(modelURL)
        }

        guard let library = dlopen(libraryURL.path, RTLD_NOW | RTLD_LOCAL) else {
            let message: String
            if let error = dlerror() {
                message = String(cString: error)
            } else {
                message = "unknown loader error"
            }
            throw EchoCancellationError.nativeLibrary(libraryURL, message)
        }
        self.library = library

        func symbol(_ name: String) throws -> UnsafeMutableRawPointer {
            guard let value = dlsym(library, name) else {
                throw EchoCancellationError.missingSymbol(name)
            }
            return value
        }

        do {
            let newContext = unsafeBitCast(try symbol("localvqe_new"), to: New.self)
            freeContext = unsafeBitCast(try symbol("localvqe_free"), to: Free.self)
            processFrame = unsafeBitCast(
                try symbol("localvqe_process_frame_f32"), to: Process.self)
            lastError = unsafeBitCast(
                try symbol("localvqe_last_error"), to: LastError.self)
            let sampleRateProperty = unsafeBitCast(
                try symbol("localvqe_sample_rate"), to: IntegerProperty.self)
            let hopSizeProperty = unsafeBitCast(
                try symbol("localvqe_hop_length"), to: IntegerProperty.self)
            let setNoiseGate = unsafeBitCast(
                try symbol("localvqe_set_noise_gate"), to: SetNoiseGate.self)

            context = modelURL.path.withCString { newContext($0) }
            guard context != 0 else {
                throw EchoCancellationError.modelLoad("native loader returned an empty context")
            }
            sampleRate = Int(sampleRateProperty(context))
            hopSize = Int(hopSizeProperty(context))
            guard sampleRate == 16_000, hopSize == 256 else {
                freeContext(context)
                throw EchoCancellationError.unsupportedFormat(
                    sampleRate: sampleRate, hopSize: hopSize)
            }
            let gateResult = setNoiseGate(context, 0, -45)
            guard gateResult == 0 else {
                freeContext(context)
                throw EchoCancellationError.processing(
                    code: gateResult, message: "could not disable the residual noise gate")
            }
        } catch {
            dlclose(library)
            throw error
        }
    }

    deinit {
        freeContext(context)
        dlclose(library)
    }

    func process(microphone: [Float], reference: [Float]) throws -> [Float] {
        guard microphone.count == hopSize, reference.count == hopSize else {
            throw EchoCancellationError.invalidFrame(
                expected: hopSize,
                microphone: microphone.count,
                reference: reference.count)
        }
        var output = [Float](repeating: 0, count: hopSize)
        let result = microphone.withUnsafeBufferPointer { mic in
            reference.withUnsafeBufferPointer { far in
                output.withUnsafeMutableBufferPointer { cleaned in
                    processFrame(
                        context, mic.baseAddress, far.baseAddress,
                        Int32(hopSize), cleaned.baseAddress)
                }
            }
        }
        guard result == 0 else {
            let message = lastError(context).map(String.init(cString:)) ?? "unknown error"
            throw EchoCancellationError.processing(code: result, message: message)
        }
        guard output.allSatisfy(\.isFinite) else {
            throw EchoCancellationError.invalidOutput
        }
        return output
    }
}

/// Offline, independent of AVAudioEngine and the computer's playback route.
///
/// LocalVQE's v1.4-AEC file model emits the preceding 256-sample hop. The
/// stream keeps one input hop pending, drops the startup output, and flushes
/// once at the end so the derived microphone remains sample-aligned and the
/// final 16 ms is not lost.
final class EchoCanceller {
    static let sampleRate = 16_000
    static let frameSize = 256
    static let referenceHangoverSamples = sampleRate

    private enum Preservation {
        case none
        case all
        case mixed([Bool])
    }

    private struct Pending {
        let microphone: [Float]
        let preservation: Preservation
    }

    private let backend: EchoCancellationBackend
    private var pending: Pending?
    private var hasSeenActiveReference = false
    private var silentReferenceSamples = 0
    private var finished = false

    convenience init() throws {
        let assets = try LocalVQEAssets.resolve()
        try self.init(backend: LocalVQEBackend(
            libraryURL: assets.library,
            modelURL: assets.model))
    }

    init(backend: EchoCancellationBackend) throws {
        guard backend.sampleRate == Self.sampleRate,
              backend.hopSize == Self.frameSize else {
            throw EchoCancellationError.unsupportedFormat(
                sampleRate: backend.sampleRate,
                hopSize: backend.hopSize)
        }
        self.backend = backend
    }

    /// Returns the preceding input hop, now aligned with LocalVQE's output.
    /// The first call returns nil because its native output is startup state.
    func process(
        microphone: [Float],
        reference: [Float],
        preserveOriginal: Bool = false
    ) throws -> [Float]? {
        guard !finished else { throw EchoCancellationError.alreadyFinished }
        guard microphone.count == Self.frameSize,
              reference.count == Self.frameSize else {
            throw EchoCancellationError.invalidFrame(
                expected: Self.frameSize,
                microphone: microphone.count,
                reference: reference.count)
        }

        let candidate = try backend.process(microphone: microphone, reference: reference)
        let previous = pending
        pending = Pending(
            microphone: microphone,
            preservation: preservation(
                for: reference, forceOriginal: preserveOriginal))
        guard let previous else { return nil }
        return select(candidate: candidate, pending: previous)
    }

    /// Feeds one zero hop to obtain the delayed output for the final input.
    func finish() throws -> [Float]? {
        guard !finished else { return nil }
        finished = true
        guard let pending else { return nil }
        self.pending = nil
        let zeros = [Float](repeating: 0, count: Self.frameSize)
        let candidate = try backend.process(microphone: zeros, reference: zeros)
        return select(candidate: candidate, pending: pending)
    }

    /// A zero reference at stream start proves that no playback has occurred,
    /// so the microphone can be returned exactly. Once playback has occurred,
    /// LocalVQE keeps control for one second of reference silence to cover
    /// device delay and room decay. Counting samples also handles a transition
    /// in the middle of a hop without extending or shortening the holdoff.
    private func preservation(
        for reference: [Float],
        forceOriginal: Bool
    ) -> Preservation {
        var first: Bool?
        var mixed: [Bool]?

        for index in reference.indices {
            let preserve: Bool
            if reference[index] != 0 {
                hasSeenActiveReference = true
                silentReferenceSamples = 0
                preserve = forceOriginal
            } else if !hasSeenActiveReference {
                preserve = true
            } else {
                silentReferenceSamples = min(
                    silentReferenceSamples + 1,
                    Self.referenceHangoverSamples + 1)
                preserve = forceOriginal
                    || silentReferenceSamples > Self.referenceHangoverSamples
            }

            if let first, preserve != first, mixed == nil {
                mixed = [Bool](repeating: first, count: Self.frameSize)
            } else if first == nil {
                first = preserve
            }
            mixed?[index] = preserve
        }

        if let mixed { return .mixed(mixed) }
        return first == true ? .all : .none
    }

    private func select(candidate: [Float], pending: Pending) -> [Float] {
        switch pending.preservation {
        case .none:
            return candidate
        case .all:
            return pending.microphone
        case .mixed(let preserve):
            var output = candidate
            for index in output.indices where preserve[index] {
                output[index] = pending.microphone[index]
            }
            return output
        }
    }
}
