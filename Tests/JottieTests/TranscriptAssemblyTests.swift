import Foundation
import Testing
import JottieModels
import JottieLibrary
import JottieKnowledge

private func fragmentedMeeting() -> Meeting {
    var meeting = Meeting(sourceID: "synthetic-fragments", title: "Synthetic planning", segments: [
        Segment(id: "a", speaker: "me 1", startMS: 1000, endMS: 4000, text: "For a um"),
        Segment(id: "b", speaker: "me unknown", startMS: 5000, endMS: 5100, text: "a"),
        Segment(id: "c", speaker: "them", startMS: 5100, endMS: 8000, text: "period of time working remotely."),
        Segment(id: "d", speaker: "them 1", startMS: 9000, endMS: 10000, text: "Uh, I I can"),
        Segment(id: "e", speaker: "me 2", startMS: 10000, endMS: 12000, text: "review the roadmap."),
        Segment(id: "f", speaker: "me 1", startMS: 13000, endMS: 15000, text: "No, not Friday."),
        Segment(id: "g", speaker: "me 1", startMS: 20000, endMS: 21000, text: "Um.")
    ])
    meeting.speakerNames = ["me 1": "Dana Example", "me unknown": "Dana Example", "them": "Dana Example", "them 1": "Lee Example", "me 2": "Lee Example"]
    var preferences = TranscriptCleanupPreferences(); preferences.expectedSpeakerCount = 2
    preferences.instructions = "Only Dana and Lee attended. Join their sentence fragments."
    meeting.cleanupPreferences = preferences
    return meeting
}
private actor AssemblyRunner: StructuredRunner {
    var prompts: [String] = []
    func run(prompt: String, schema: Data) async throws -> Data {
        prompts.append(prompt)
        // The model returns compact edits only; originals and source IDs are supplied locally.
        return Data(#"{"changes":[{"segmentID":"a","replacementText":"For a period of time working remotely.","kind":"wording","duplicateOf":null,"reason":"Resolve repeated boundary word.","uncertain":false},{"segmentID":"d","replacementText":"I can review the roadmap.","kind":"wording","duplicateOf":null,"reason":"Remove repeated false start.","uncertain":false}],"speakerSuggestions":[],"notes":[]}"#.utf8)
    }
}
@Test func confirmedPeopleJoinAcrossAcousticLabelsAndRetainSentenceStartTimes() async throws {
    let meeting = fragmentedMeeting(), runner = AssemblyRunner()
    let proposal = try await TranscriptCleanupService(runner: runner).propose(for: meeting, model: "synthetic", effort: "low")
    let projected = try proposal.result.projectedSegments(against: meeting, selecting: Set(proposal.result.changes.map(\.id)))
    #expect(projected.map(\.id) == ["a", "d", "f"])
    #expect(projected.map(\.text) == ["For a period of time working remotely.", "I can review the roadmap.", "No, not Friday."])
    #expect(projected.map(\.startMS) == [1000, 9000, 13000])
    #expect(projected.map(\.endMS) == [8000, 12000, 15000])
    #expect(proposal.result.changes.first?.sourceIDs == ["a", "b", "c"])
    let input = try #require(await runner.prompts.first)
    #expect(input.contains("Dana Example") && input.contains("Lee Example") && input.contains("expectedSpeakerCount\":2"))
    #expect(!input.contains("manualAssignments"))
    #expect(input.contains("Only Dana and Lee attended"))
    #expect(!String(decoding: TranscriptCleanupService.schema, as: UTF8.self).contains("originalText"))
}
@Test func mergingKeepsOriginalEvidenceAndManualNamesThroughOverwriteRestoreAndRescan() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("jottie-assembly-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LibraryStore(root: root), original = fragmentedMeeting()
    try await store.save(original)
    let proposal = try await TranscriptCleanupService(runner: AssemblyRunner()).propose(for: original, model: "synthetic", effort: "low")
    try await store.saveCleanupDraft(proposal, meetingID: original.id)
    try await store.applyCleanup(meetingID: original.id, draftID: proposal.id, changeIDs: Set(proposal.result.changes.map(\.id)), speakerIDs: [])
    let value = try await store.meeting(original.id)
    #expect(value.segments.count == 3 && value.reconciledSpeakers.count == 2)
    #expect(value.transcriptSourceSegmentIDs?["a"] == ["a", "b", "c"])
    #expect(value.transcriptSourceSegmentIDs?["d"] == ["d", "e"])
    #expect(value.speakerNames == original.speakerNames && value.originalTranscript == original.segments)
    let restarted = try LibraryStore(root: root)
    #expect(try await restarted.meeting(original.id).transcriptSourceSegmentIDs == value.transcriptSourceSegmentIDs)
    try await restarted.restoreOriginalTranscript(meetingID: original.id, expectedRevision: value.transcriptRevision)
    let restored = try await restarted.meeting(original.id)
    #expect(restored.segments == original.segments && restored.transcriptSourceSegmentIDs == nil)
    #expect(restored.speakerNames == original.speakerNames)
}
@Test func fillersDoNotEatPunctuationWordsNegationOrMeaningfulAnswers() {
    #expect(TranscriptTurnAssembly.removingFillers("Uh, no, not Friday.") == "no, not Friday.")
    #expect(TranscriptTurnAssembly.removingFillers("Umbrella, human, uh-huh, yes.") == "Umbrella, human, uh-huh, yes.")
    #expect(TranscriptTurnAssembly.removingFillers("Uh huh.") == "Uh huh.")
    #expect(TranscriptTurnAssembly.removingFillers("um uh erm.").isEmpty)
    #expect(TranscriptTurnAssembly.removingFillers("That stays, exactly!") == "That stays, exactly!")
}
@Test func assemblyNeverCrossesAnotherPersonSilenceOrAnUnresolvedSharedChannel() throws {
    var meeting = fragmentedMeeting()
    meeting.speakerNames["me unknown"] = "Lee Example"
    let groups = TranscriptTurnAssembly.groups(in: meeting)
    #expect(!groups.contains { $0.map(\.id).contains("a") && $0.map(\.id).contains("b") })
    #expect(!groups.contains { $0.map(\.id).contains("f") && $0.map(\.id).contains("g") })
    var unknown = Meeting(sourceID: "unknown", title: "Unknown", segments: [
        Segment(id: "x", speaker: "them", startMS: 0, endMS: 1000, text: "One person."),
        Segment(id: "y", speaker: "them", startMS: 1100, endMS: 2000, text: "Possibly another.")])
    #expect(TranscriptTurnAssembly.groups(in: unknown).count == 2)
    unknown.speakerNames["them"] = "Confirmed Person"
    #expect(TranscriptTurnAssembly.groups(in: unknown).count == 1)
    let invalid = TranscriptCleanupResult(changes: [TranscriptTextChange(segmentID: "a", originalText: meeting.segments[0].text + " " + meeting.segments[1].text,
        replacementText: "For a", kind: "merge", reason: "Wrong speaker boundary", sourceSegmentIDs: ["a", "b"])])
    #expect(throws: (any Error).self) { try invalid.validate(against: meeting) }
}
@Test func removingFillersAndJoiningCanBeDisabledIndependently() {
    var meeting = fragmentedMeeting(), preferences = TranscriptCleanupPreferences()
    preferences.joinFragments = false; preferences.stripFillers = false; meeting.cleanupPreferences = preferences
    let raw = TranscriptCleanupService.prepared(meeting)
    #expect(raw.meeting.segments == meeting.segments && raw.changes.isEmpty)
    preferences.stripFillers = true; meeting.cleanupPreferences = preferences
    let stripped = TranscriptCleanupService.prepared(meeting)
    #expect(stripped.meeting.segments.count == 6 && stripped.changes.contains { $0.kind == "filler" })
    #expect(!stripped.changes.contains { $0.sourceIDs.count > 1 })
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["JOTTIE_ASSEMBLY_UI_FIXTURE"] != nil))
func exportSyntheticAssemblyReviewFixture() async throws {
    let path = try #require(ProcessInfo.processInfo.environment["JOTTIE_ASSEMBLY_UI_FIXTURE"])
    guard path.hasPrefix("/tmp/jottie-assembly-ui-") else { throw JottieError.invalid("Use a temporary synthetic fixture directory.") }
    let store = try LibraryStore(root: URL(fileURLWithPath: path))
    var meeting = fragmentedMeeting(); meeting.title = "Synthetic two-person fragment cleanup"
    try await store.save(meeting)
    let revision = try await TranscriptCleanupService(runner: AssemblyRunner()).propose(for: meeting, model: "synthetic", effort: "low")
    try await store.saveCleanupDraft(revision, meetingID: meeting.id)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["JOTTIE_ASSEMBLY_LIVE_TEST"] == "1"))
func liveInventedAssemblyPromptValidation() async throws {
    // Explicit opt-in only. Never submit any stored meeting or attached transcript.
    let store = try LibraryStore(root: LibraryStore.defaultRoot, readOnly: true)
    let settings = try await store.settings()
    let runner = CodexRunner(executable: settings.codexPath, timeout: 180, model: settings.codexModel, effort: settings.codexEffort)
    let meeting = fragmentedMeeting()
    let revision = try await TranscriptCleanupService(runner: runner).propose(for: meeting, model: settings.codexModel, effort: settings.codexEffort)
    let projected = try revision.result.projectedSegments(against: meeting, selecting: Set(revision.result.changes.map(\.id)))
    let text = projected.map(\.text).joined(separator: " ").lowercased()
    #expect(!text.contains("a a period") && !text.contains("i i can"))
    #expect(text.contains("not friday") && text.contains("review the roadmap"))
    #expect(projected.map(\.startMS) == [1000, 9000, 13000])
    #expect(!text.contains(" um") && !text.contains(" uh"))
}

@Test func correctingAJoinedPassageAlsoCorrectsItsRetainedSourceFragments() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("jottie-assembly-correction-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LibraryStore(root: root), original = fragmentedMeeting()
    try await store.save(original)
    let proposal = try await TranscriptCleanupService(runner: AssemblyRunner()).propose(for: original, model: "synthetic", effort: "low")
    try await store.saveCleanupDraft(proposal, meetingID: original.id)
    try await store.applyCleanup(meetingID: original.id, draftID: proposal.id, changeIDs: Set(proposal.result.changes.map(\.id)), speakerIDs: [])
    let joined = try await store.meeting(original.id)
    try await store.setSpeakerAssignment(segmentIDs: ["a"], name: "Lee Example", role: nil, employeeID: nil, meetingID: original.id, expectedRevision: joined.transcriptRevision)
    let corrected = try await store.meeting(original.id)
    #expect(["a", "b", "c"].allSatisfy { corrected.speakerAttributions?[$0]?.name == "Lee Example" })
    try await store.restoreOriginalTranscript(meetingID: original.id, expectedRevision: corrected.transcriptRevision)
    let restored = try await store.meeting(original.id)
    #expect(restored.speakerName(for: restored.segments[1]) == "Lee Example")
    #expect(restored.speakerName(for: restored.segments[2]) == "Lee Example")
    #expect(restored.speakerName(for: restored.segments[5]) == "Dana Example")
}
