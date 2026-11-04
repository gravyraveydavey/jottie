import Foundation
import JottieModels
import JottieLibrary

struct LocalVoiceResult: Sendable {
    var intervals: [SpeakerInterval]
    var samples: [VoiceSample]
    var modelID: String
}

actor VoiceCaptureCollector {
    private var samples: [VoiceSample] = []
    private var modelID = ""
    func append(_ result: LocalVoiceResult, side: String, offsetMS: Int) throws {
        guard modelID.isEmpty || modelID == result.modelID else { throw VoiceCaptureError.modelsChanged }
        modelID = result.modelID
        let names = LocalSpeakerSeparation.names(for: result.intervals, side: side)
        for var sample in result.samples {
            guard let name = names[sample.speaker] else { continue }
            sample.id = side + ":" + sample.id; sample.speaker = name
            sample.startMS += offsetMS; sample.endMS += offsetMS
            if sample.isValid { samples.append(sample) }
        }
    }
    func snapshot() -> ([VoiceSample], String) { (samples, modelID) }
}

enum VoiceCaptureError: LocalizedError, TranscriptionFailure {
    case separationRequired, modelsChanged
    var isPermanent: Bool { false }
    var isEnvironmental: Bool { true }
    var errorDescription: String? {
        switch self {
        case .separationRequired: "Voice learning requires local speaker separation and a per-track local transcription engine such as Parakeet. Enable separation or disable voice learning. Audio is retained for retry."
        case .modelsChanged: "Speaker models changed during transcription. Audio is retained for retry."
        }
    }
}

struct VoiceCaptureContext: Sendable {
    var settings: LibrarySettings
    var store: LibraryStore
    var analyse: @Sendable (URL) async throws -> LocalVoiceResult = { try await LocalSpeakerSeparation.analyseForVoiceLearning($0) }
    static func current() async throws -> VoiceCaptureContext? {
        let root = Home.current.url.appendingPathComponent("Library/Application Support/Jottie")
        let settings = try await LibraryStore(root: root, readOnly: true).settings()
        guard settings.voiceLearningEnabled else { return nil }
        return VoiceCaptureContext(settings: settings, store: try LibraryStore(root: root),
            analyse: { try await LocalSpeakerSeparation.analyseForVoiceLearning($0, tuning: settings.voiceTuning) })
    }
}
