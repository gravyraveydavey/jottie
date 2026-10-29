import Testing
@testable import amanu

struct ResidualEchoTests {
    @Test("Diarization label changes do not break a residual echo phrase")
    func fragmentedSpeakerLabels() {
        let phrase = ["Please", "review", "the", "updated", "project", "schedule", "before", "our", "next", "meeting"]
        var segments: [Transcript.Segment] = []
        for (i, word) in phrase.enumerated() {
            segments.append(.init(speaker: i < 5 ? "them 1" : "them", start_ms: i * 300, end_ms: i * 300 + 300, text: word))
            segments.append(.init(speaker: i.isMultiple(of: 2) ? "me 2" : "me unknown", start_ms: i * 300 + 50, end_ms: i * 300 + 350, text: word))
        }
        segments.append(.init(speaker: "me 1", start_ms: 4000, end_ms: 5000, text: "I have a different suggestion"))
        segments.sort { $0.start_ms < $1.start_ms }
        let result = EchoFilter.dropResidualEchoes(segments)
        #expect(result.filter { $0.speaker.hasPrefix("me") }.map(\.text) == ["I have a different suggestion"])
        #expect(result.filter { $0.speaker.hasPrefix("them") }.map(\.text) == phrase)
    }

    @Test("A delayed acoustic copy is removed despite different ASR boundaries")
    func delayedFragmentedEcho() {
        let segments: [Transcript.Segment] = [
            .init(speaker: "them", start_ms: 0, end_ms: 300, text: "Please"),
            .init(speaker: "them 1", start_ms: 300, end_ms: 2100, text: "review the updated project schedule"),
            .init(speaker: "them", start_ms: 2100, end_ms: 3000, text: "before our next meeting"),
            .init(speaker: "me unknown", start_ms: 800, end_ms: 1400, text: "Please review"),
            .init(speaker: "me 2", start_ms: 1400, end_ms: 2900, text: "the updated project schedule"),
            .init(speaker: "me unknown", start_ms: 2900, end_ms: 3800, text: "before our next meeting"),
            .init(speaker: "me 1", start_ms: 4000, end_ms: 7000, text: "Please review the updated project schedule before our next meeting"),
        ].sorted { $0.start_ms < $1.start_ms }
        let result = EchoFilter.dropResidualEchoes(segments)
        #expect(result.filter { $0.speaker.hasPrefix("me") }.map(\.speaker) == ["me 1"])
    }

    @Test("An echo match cannot delete the original words in a mixed local passage")
    func keepsPartiallyDuplicatedPassageAcrossLabels() {
        let segments: [Transcript.Segment] = [
            .init(speaker: "them 1", start_ms: 0, end_ms: 2000, text: "Please review the updated project schedule"),
            .init(speaker: "me unknown", start_ms: 50, end_ms: 600, text: "Please review"),
            .init(speaker: "me 2", start_ms: 600, end_ms: 2050, text: "the updated project schedule but I disagree"),
        ]
        let result = EchoFilter.dropResidualEchoes(segments)
        #expect(result.contains { $0.text == "the updated project schedule but I disagree" })
    }

    @Test("Short replies, later repetitions and phrases separated by silence survive")
    func doesNotBridgeSilenceOrRemoveUnprovenRepeats() {
        let segments: [Transcript.Segment] = [
            .init(speaker: "them 1", start_ms: 0, end_ms: 1000, text: "Please review the updated schedule"),
            .init(speaker: "me 2", start_ms: 1500, end_ms: 2500, text: "Please review the updated schedule"),
            .init(speaker: "me unknown", start_ms: 100, end_ms: 500, text: "Please review"),
            .init(speaker: "them", start_ms: 5000, end_ms: 5500, text: "We will"),
            .init(speaker: "them 1", start_ms: 7000, end_ms: 7500, text: "review this tomorrow"),
            .init(speaker: "me unknown", start_ms: 5050, end_ms: 5550, text: "We will"),
            .init(speaker: "me 2", start_ms: 7050, end_ms: 7550, text: "review this tomorrow"),
        ]
        #expect(EchoFilter.dropResidualEchoes(segments).map(\.text) == segments.map(\.text))
    }

    @Test("Word-sized ASR fragments are cleaned as a phrase without swallowing a local interruption")
    func wordSizedEcho() {
        let phrase = ["давайте", "сначала", "посмотрим", "на", "новый", "вариант", "этого", "экрана"]
        var segments: [Transcript.Segment] = []
        for (i, word) in phrase.enumerated() {
            segments.append(.init(speaker: "them", start_ms: i * 200, end_ms: i * 200 + 190, text: word))
            segments.append(.init(speaker: "me A", start_ms: i * 200 + 50, end_ms: i * 200 + 240, text: word))
        }
        segments.append(.init(speaker: "me B", start_ms: 1200, end_ms: 1900, text: "А что добавить?"))
        segments.sort { $0.start_ms < $1.start_ms }
        let result = EchoFilter.dropResidualEchoes(segments)
        #expect(result.filter { $0.speaker.hasPrefix("me") }.map(\.text) == ["А что добавить?"])
    }
    @Test("After audio cancellation short agreements and partly matching local sentences survive")
    func preservesLocalWords() {
        let segments: [Transcript.Segment] = [
            .init(speaker: "them", start_ms: 0, end_ms: 4000, text: "Да, в пятницу мы можем встретиться после обеда"),
            .init(speaker: "me", start_ms: 1000, end_ms: 1500, text: "Да, в пятницу"),
            .init(speaker: "me", start_ms: 1600, end_ms: 3000, text: "В пятницу мы можем встретиться только вечером"),
        ]
        #expect(EchoFilter.dropResidualEchoes(segments).count == 3)
    }

    @Test("Only a whole identical long overlapping phrase is a residual text duplicate")
    func exactWholePhrase() {
        let text = "мы можем встретиться в пятницу после обеда"
        let segments: [Transcript.Segment] = [
            .init(speaker: "them A", start_ms: 0, end_ms: 4000, text: text),
            .init(speaker: "me A", start_ms: 100, end_ms: 4100, text: text),
            .init(speaker: "me A", start_ms: 5000, end_ms: 9000, text: text),
        ]
        let result = EchoFilter.dropResidualEchoes(segments)
        #expect(result.count == 2)
        #expect(result.last?.start_ms == 5000)
    }
}
