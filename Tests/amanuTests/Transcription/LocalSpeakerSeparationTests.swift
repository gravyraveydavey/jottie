import AVFoundation
import Foundation
import Testing
@testable import amanu

@Suite(.serialized) struct LocalSpeakerSeparationTests {
    @Test func timedWordsSeparateSharedChannelWithoutLosingText() {
        let words = [TranscriptWord(start: 0, end: 0.5, text: "Hello"), TranscriptWord(start: 0.5, end: 1, text: "Jamie."),
                     TranscriptWord(start: 1, end: 1.5, text: "Hello"), TranscriptWord(start: 1.5, end: 2, text: "Sam.")]
        let source = [TranscriptSegment(start: 0, end: 2, text: "Hello Jamie. Hello Sam.", words: words)]
        let intervals = [SpeakerInterval(speaker: "x", start: 0, end: 1), SpeakerInterval(speaker: "y", start: 1, end: 2)]
        let result = LocalSpeakerSeparation.applying(intervals, to: source, side: "them")
        #expect(result.map(\.speaker) == ["them 1", "them 2"])
        #expect(result.map(\.text).joined(separator: " ") == source[0].text)
        #expect(result.map(\.start) == [0,1] && result.map(\.end) == [1,2])
        let overlap = LocalSpeakerSeparation.applying([SpeakerInterval(speaker: "x", start: 0, end: 2), SpeakerInterval(speaker: "y", start: 0, end: 2)], to: source, side: "them")
        #expect(overlap.allSatisfy { $0.speaker == nil })
        let coarse = LocalSpeakerSeparation.applying(intervals, to: [TranscriptSegment(start: 0, end: 2, text: "Both voices")], side: "them")
        #expect(coarse[0].speaker == nil && coarse[0].text == "Both voices")
        let mismatched = LocalSpeakerSeparation.applying(intervals, to: [TranscriptSegment(start: 0, end: 2, text: "Keep the original", words: words)], side: "them")
        #expect(mismatched[0].text == "Keep the original")
        let duplicate = LocalSpeakerSeparation.applying([intervals[0], intervals[0], SpeakerInterval(speaker: "y", start: 0, end: 1)], to: [source[0]], side: "them")
        #expect(duplicate.allSatisfy { $0.speaker == nil })
    }
    private actor MockEngine: TranscriptionEngine {
        nonisolated let name = "test"
        nonisolated let model = "synthetic"
        nonisolated let input: TranscriptionInput = .perTrack
        func prepare() async throws {}
        func release() async {}
        func transcribe(_ audio: URL) async throws -> [TranscriptSegment] {
            [TranscriptSegment(start: 0, end: 2, text: "One. Two.", words: [TranscriptWord(start: 0, end: 1, text: "One."), TranscriptWord(start: 1, end: 2, text: "Two.")])]
        }
    }
    private func recording() throws -> URL {
        let root = Home.current.url.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32000)!
        buffer.frameLength = 32000
        buffer.floatChannelData![0].initialize(repeating: 0, count: 32000)
        let file = try AVAudioFile(forWriting: root.appendingPathComponent("system.caf"), settings: format.settings)
        try file.write(from: buffer)
        try Data(#"{"files":{"system":"system.caf"},"start_offset_ms":{"system":500},"started":"2026-10-27T09:00:00Z"}"#.utf8).write(to: root.appendingPathComponent("meta.json"))
        return root
    }
    @Test(.freshHome) func actualPerTrackPipelineKeepsSeparatedVoicesAndOffsets() async throws {
        let root = try recording()
        let inputs = TranscriptionInputs(session: root, audio: root, meta: try SessionMeta.read(from: root), engine: MockEngine(), separateSpeakers: true,
            speakerIntervals: { _ in [SpeakerInterval(speaker: "x", start: 0, end: 1), SpeakerInterval(speaker: "y", start: 1, end: 2)] })
        let result = try await inputs.perTrack()
        #expect(result.map(\.speaker) == ["them 1", "them 2"])
        #expect(result.map(\.start_ms) == [500,1500])
        #expect(result.map(\.text) == ["One.", "Two."])
    }
    @Test(.freshHome) func missingSpeakerModelsKeepRecordingForRetry() async throws {
        let root = try recording()
        Config.update(path: ["transcription", "separate_speakers"], value: true)
        await #expect(throws: (any Error).self) { try await TranscriptionCoordinator(engine: MockEngine(), onStop: { nil }).transcribeNow(root) }
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("system.caf").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("transcript.json").path))
    }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["JOTTIE_SPEAKER_MODEL_VALIDATION"] != nil))
func validateDownloadedSpeakerModelAssets() async throws {
    let path = try #require(ProcessInfo.processInfo.environment["JOTTIE_SPEAKER_MODEL_VALIDATION"])
    guard path.hasPrefix("/tmp/jottie-speaker-model-") else { throw LocalSpeakerModels.ModelError.invalidParameters }
    let models = LocalSpeakerModels(root: URL(fileURLWithPath: path))
    try await models.download()
    #expect(models.isReady)
    _ = try models.load()
}
