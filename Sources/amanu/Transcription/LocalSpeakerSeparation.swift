import Foundation
@preconcurrency import CoreML
import FluidAudio

/// Speaker vectors exist only in the diarizer's memory. Only anonymous timed labels leave this adapter.
struct SpeakerInterval: Sendable {
    var speaker: String
    var start: Double
    var end: Double
}
struct LocalSpeakerModels: Sendable {
    let root: URL
    init(root: URL = Home.current.url.appendingPathComponent("Library/Application Support/Jottie/models/speakers")) { self.root = root }
    var directory: URL { root.appendingPathComponent(Repo.diarizer.folderName) }
    static let required = ["Segmentation.mlmodelc", "FBank.mlmodelc", "Embedding.mlmodelc", "PldaRho.mlmodelc", "plda-parameters.json"]
    var isReady: Bool { Self.required.allSatisfy { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) } }
    func download() async throws {
        try await ModelHub.download(.diarizer, to: root, variant: "offline")
        guard isReady else { throw ModelError.missing }
        // Validate every model now. Runtime loading below cannot access the network.
        _ = try load()
    }
    enum ModelError: LocalizedError, TranscriptionFailure {
        case missing, invalidParameters
        var isPermanent: Bool { false }
        var isEnvironmental: Bool { true }
        var errorDescription: String? {
            switch self {
            case .missing: return "Local speaker separation models are missing. Download them under Settings → Recording, or switch separation off to transcribe with shared channels. Audio is retained for retry."
            case .invalidParameters: return "Speaker separation models are incomplete. Repair them under Settings → Recording. Audio is retained for retry."
            }
        }
    }
    /// Manual Core ML loading avoids the SDK's download-on-error fallback during transcription.
    func load() throws -> OfflineDiarizerModels {
        guard isReady else { throw ModelError.missing }
        func model(_ name: String, cpuOnly: Bool = false) throws -> MLModel {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = cpuOnly ? .cpuOnly : .cpuAndNeuralEngine
            return try MLModel(contentsOf: directory.appendingPathComponent(name + ".mlmodelc"), configuration: configuration)
        }
        let data = try Data(contentsOf: directory.appendingPathComponent("plda-parameters.json"))
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tensors = json["tensors"] as? [String: Any], let psi = tensors["psi"] as? [String: Any],
              let encoded = psi["data_base64"] as? String, let bytes = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters),
              bytes.count > 0, bytes.count <= 16_384, bytes.count % MemoryLayout<Float>.size == 0
        else { throw ModelError.invalidParameters }
        var values = [Float](repeating: 0, count: bytes.count / MemoryLayout<Float>.size)
        _ = values.withUnsafeMutableBytes { bytes.copyBytes(to: $0) }
        guard values.count == 128, values.allSatisfy({ $0.isFinite && $0 >= 0 }) else { throw ModelError.invalidParameters }
        return try OfflineDiarizerModels(segmentationModel: model("Segmentation"), fbankModel: model("FBank", cpuOnly: true),
            embeddingModel: model("Embedding"), pldaRhoModel: model("PldaRho"), pldaPsi: values.map(Double.init), compilationDuration: 0)
    }
}

enum LocalSpeakerSeparation {
    static func intervals(for audio: URL) async throws -> [SpeakerInterval] {
        try Task.checkCancellation()
        let manager = OfflineDiarizerManager()
        manager.initialize(models: try LocalSpeakerModels().load())
        let result = try await manager.process(audio)
        try Task.checkCancellation()
        return result.segments.map { SpeakerInterval(speaker: $0.speakerId, start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds)) }
    }
    /// Assign actual timed words; never divide text proportionally or invent words/voice identities.
    static func applying(_ intervals: [SpeakerInterval], to segments: [TranscriptSegment], side: String) -> [TranscriptSegment] {
        let ordered = intervals.filter { $0.start.isFinite && $0.end.isFinite && $0.end > $0.start }
            .sorted { $0.start == $1.start ? $0.speaker < $1.speaker : $0.start < $1.start }
        var names: [String: String] = [:]
        for interval in ordered where names[interval.speaker] == nil { names[interval.speaker] = "\(side) \(names.count + 1)" }
        // One mic voice retains the configured owner's label. A shared mic
        // must never assign every acoustic cluster that same identity.
        if side == "me", names.count == 1, let key = names.keys.first { names[key] = "me" }
        func label(start: Double, end: Double) -> String? {
            let unknown: String? = side == "me" ? "me unknown" : nil
            guard start.isFinite, end.isFinite, end > start else { return unknown }
            var ranges: [String: [(Double, Double)]] = [:]
            for interval in ordered where interval.start < end && interval.end > start {
                ranges[interval.speaker, default: []].append((max(start, interval.start), min(end, interval.end)))
            }
            let overlap = ranges.mapValues { spans -> Double in
                var covered = 0.0; var previousEnd = -Double.infinity
                for span in spans.sorted(by: { $0.0 < $1.0 }) {
                    covered += max(0, span.1 - max(previousEnd, span.0)); previousEnd = max(previousEnd, span.1)
                }
                return covered
            }
            let ranked = overlap.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            guard let first = ranked.first, first.value / (end - start) >= 0.65,
                  first.value - (ranked.dropFirst().first?.value ?? 0) >= (end - start) * 0.2 else { return unknown }
            return names[first.key]
        }
        var output: [TranscriptSegment] = []
        for segment in segments {
            guard let words = segment.words, !words.isEmpty, words.map(\.text).joined(separator: " ") == segment.text else {
                output.append(TranscriptSegment(start: segment.start, end: segment.end, text: segment.text,
                    speaker: label(start: segment.start, end: segment.end)))
                continue
            }
            var current: [TranscriptWord] = []; var currentLabel: String?
            func flush() {
                guard let first = current.first, let last = current.last else { return }
                output.append(TranscriptSegment(start: first.start, end: last.end, text: current.map(\.text).joined(separator: " "), speaker: currentLabel, words: current))
                current = []
            }
            for word in words {
                let next = label(start: word.start, end: word.end)
                if !current.isEmpty && next != currentLabel { flush() }
                currentLabel = next; current.append(word)
            }
            flush()
        }
        return output
    }
}
