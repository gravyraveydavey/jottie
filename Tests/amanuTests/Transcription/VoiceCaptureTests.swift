import AVFoundation
import Foundation
import Testing
import JottieModels
import JottieLibrary
@testable import amanu

@Suite(.serialized) struct VoiceCaptureTests {
    private actor Engine: TranscriptionEngine {
        nonisolated let name = "voice-test"
        nonisolated let model = "synthetic"
        nonisolated let input: TranscriptionInput = .perTrack
        func prepare() async throws {}
        func release() async {}
        func transcribe(_ audio: URL) async throws -> [TranscriptSegment] {
            [TranscriptSegment(start: 0, end: 10, text: "Invented speech one."),
             TranscriptSegment(start: 10, end: 20, text: "Invented speech two.")]
        }
    }
    private func fixture(badKey: Bool = false) async throws -> (URL, VoiceCaptureContext) {
        Config.update(path: ["transcription", "separate_speakers"], value: true)
        Config.update(path: ["keep_audio"], value: false)
        let root = Home.current.url.appendingPathComponent("recording")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 320000)!
        buffer.frameLength = 320000
        buffer.floatChannelData![0].initialize(repeating: 0, count: 320000)
        let file = try AVAudioFile(forWriting: root.appendingPathComponent("system.caf"), settings: format.settings)
        try file.write(from: buffer)
        try Data(#"{"files":{"system":"system.caf"},"start_offset_ms":{"system":500},"started":"2026-11-04T09:00:00Z"}"#.utf8)
            .write(to: root.appendingPathComponent("meta.json"))
        let library = try LibraryStore(root: Home.current.url.appendingPathComponent("library"), voiceStorageKey: Data(repeating: 7, count: badKey ? 1 : 32))
        var settings = LibrarySettings(); settings.bambooEnabled = true; settings.bambooCompany = "test"
        try await library.saveSettings(settings)
        settings = try await library.settings(); settings.voiceLearningEnabled = true; try await library.saveSettings(settings)
        settings = try await library.settings()
        let context = VoiceCaptureContext(settings: settings, store: library, analyse: { _ in
            var vector = [Float](repeating: 0, count: 256); vector[0] = 1
            return LocalVoiceResult(intervals: [SpeakerInterval(speaker: "S1", start: 0, end: 20)],
                samples: [VoiceSample(id: "one", speaker: "S1", startMS: 0, endMS: 10000, embedding: vector),
                          VoiceSample(id: "two", speaker: "S1", startMS: 10000, endMS: 20000, embedding: vector)], modelID: "synthetic-model")
        })
        return (root, context)
    }
    @Test(.freshHome) func evidencePrecedesDurableTranscriptAndAudioDeletion() async throws {
        let (root, context) = try await fixture()
        let coordinator = TranscriptionCoordinator(engine: Engine(), onStop: { nil }, voiceCapture: { context })
        try await coordinator.transcribeNow(root)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("transcript.json").path))
        #expect(FileManager.default.fileExists(atPath: context.store.root.appendingPathComponent("Voiceprints/\(Codec.hash(root.standardizedFileURL.path)).aes").path))
        let meeting = try await context.store.importAmanu(root, defaultSpeakerName: "Configured Owner")
        #expect(meeting.segments.map(\.startMS) == [500,10500])
        #expect(try await context.store.refreshVoiceMatches().recordings == 1)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("system.caf").path))
    }
    @Test(.freshHome) func failedEncryptedEvidenceWritePreservesAudioAndLeavesTranscriptionPending() async throws {
        let (root, context) = try await fixture(badKey: true)
        let coordinator = TranscriptionCoordinator(engine: Engine(), onStop: { nil }, voiceCapture: { context })
        await #expect(throws: (any Error).self) { try await coordinator.transcribeNow(root) }
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("system.caf").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("transcript.json").path))
    }
    @Test(.freshHome) func voiceLearningRequiresSpeakerSeparationBeforeDiscardingAudio() async throws {
        let (root, context) = try await fixture()
        Config.update(path: ["transcription", "separate_speakers"], value: false)
        await #expect(throws: VoiceCaptureError.self) {
            try await TranscriptionCoordinator(engine: Engine(), onStop: { nil }, voiceCapture: { context }).transcribeNow(root)
        }
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("system.caf").path))
    }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["JOTTIE_VOICE_MODEL_AUDIO"] != nil))
func voiceEmbeddingExtractionWithInstalledModelsAndSyntheticSpeech() async throws {
    let path = try #require(ProcessInfo.processInfo.environment["JOTTIE_VOICE_MODEL_AUDIO"])
    let modelRoot = try #require(ProcessInfo.processInfo.environment["JOTTIE_VOICE_MODEL_ROOT"])
    guard path.hasPrefix("/tmp/jottie-voice-model-") else { throw VoiceCaptureError.modelsChanged }
    let result = try await LocalSpeakerSeparation.analyseForVoiceLearning(URL(fileURLWithPath: path),
        models: LocalSpeakerModels(root: URL(fileURLWithPath: modelRoot)))
    #expect(!result.intervals.isEmpty && result.samples.count >= 2)
    #expect(result.samples.allSatisfy { $0.isValid })
    #expect(result.modelID.count == 64)
}
