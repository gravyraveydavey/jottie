import Foundation
import Testing
import JottieModels
import JottieLibrary

private func editingFixture() -> Meeting {
    Meeting(sourceID: "synthetic-editing", title: "Planning", startedAt: Date(timeIntervalSince1970: 1_700_000_000), segments: [
        Segment(id: "a", speaker: "them 1", startMS: 1000, endMS: 2000, text: "The lunch is ready."),
        Segment(id: "b", speaker: "them 1", startMS: 2200, endMS: 3000, text: "Please review it.")
    ], participants: ["Alex Example <alex@example.test>", "Guest Visitor <guest@example.test>"])
}

@Test func manualTranscriptEditsCommitTogetherAndRetainOriginalsAndHistory() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LibraryStore(root: root)
    var original = editingFixture()
    let folder = Folder(name: "Planning")
    try await store.saveFolder(folder)
    original.folderID = folder.id; original.manuallyFiled = true
    original.speakerAttributions = ["b": SpeakerAttribution(name: "Guessed Person", method: "analysis")]
    original.analysis = AnalysisRevision(transcriptRevision: original.transcriptRevision, promptRevision: "test",
        analysis: Analysis(title: "Planning", summary: "Lunch is ready.", summaryEvidence: [Evidence(segmentID: "a", quote: "lunch is ready")]))
    try await store.save(original)
    try await store.editTranscript(meetingID: original.id, text: ["a": "The launch is ready."],
        assignments: ["a": SpeakerAttribution(name: " Alex Example ", jobTitle: "Writer", employeeID: "alex", method: "manual")],
        expectedRevision: original.transcriptRevision, expectedSpeakerRevision: original.speakerRevision)
    let value = try await LibraryStore(root: root).meeting(original.id)
    #expect(value.originalTranscript == original.segments)
    #expect(value.segments[0].text == "The launch is ready.")
    #expect(value.segments[0].id == "a" && value.segments[0].startMS == 1000 && value.segments[0].speaker == "them 1")
    #expect(value.segments[1] == original.segments[1])
    #expect(value.speakerAttributions?["a"]?.name == "Alex Example" && value.speakerAttributions?["a"]?.employeeID == "alex")
    #expect(value.speakerAttributions?["b"] == nil)
    #expect(value.analysis == nil && value.sourceMetadata?["cleanupNeedsSummary"] == "true")
    #expect(value.folderID == folder.id && value.manuallyFiled)
    #expect(value.transcriptRevision != original.transcriptRevision)
    let history = store.meetingDirectory(value.id).appendingPathComponent("TranscriptHistory/\(original.transcriptRevision).json")
    #expect(try Codec.decode([Segment].self, from: Data(contentsOf: history)) == original.segments)
    #expect(FileManager.default.fileExists(atPath: store.meetingDirectory(value.id).appendingPathComponent("Analysis/\(original.analysis!.id).json").path))
    let export = root.appendingPathComponent("export")
    try await store.export([value.id], to: export)
    #expect(try String(contentsOf: export.appendingPathComponent("\(value.id.uuidString).md"), encoding: .utf8).contains("Alex Example: The launch is ready."))
    #expect(try String(contentsOf: store.meetingDirectory(value.id).appendingPathComponent("transcript.md"), encoding: .utf8).contains("Alex Example: The launch is ready."))
    var query = SearchQuery(); query.text = "launch"
    #expect(try await store.search(query).count == 1)
    try await store.restoreOriginalTranscript(meetingID: value.id, expectedRevision: value.transcriptRevision)
    let restored = try await store.meeting(value.id)
    #expect(restored.segments == original.segments && restored.sourceMetadata?["transcriptManuallyEdited"] == nil)
    #expect(restored.speakerName(for: restored.segments[0]) == "Alex Example")
}

@Test func manualTranscriptEditsRejectStaleTextAndSpeakerSnapshotsWithoutPartialWrites() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LibraryStore(root: root), original = editingFixture()
    try await store.save(original)
    try await store.setSpeakerAssignment(segmentIDs: ["a"], name: "Other Person", role: nil, employeeID: nil, meetingID: original.id)
    await #expect(throws: JottieError.self) {
        try await store.editTranscript(meetingID: original.id, text: ["a": "Overwritten"], assignments: [:],
            expectedRevision: original.transcriptRevision, expectedSpeakerRevision: original.speakerRevision)
    }
    let current = try await store.meeting(original.id)
    #expect(current.segments == original.segments)
    try await store.editTranscript(meetingID: original.id, text: ["a": "The launch is ready."], assignments: [:],
        expectedRevision: current.transcriptRevision, expectedSpeakerRevision: current.speakerRevision)
    await #expect(throws: JottieError.self) {
        try await store.editTranscript(meetingID: original.id, text: ["b": "Overwritten"], assignments: [:],
            expectedRevision: current.transcriptRevision, expectedSpeakerRevision: current.speakerRevision)
    }
    #expect(try await store.meeting(original.id).segments[1].text == original.segments[1].text)
}

@Test func manualTranscriptEditsValidateAllPassagesBeforeSaving() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LibraryStore(root: root), original = editingFixture()
    try await store.save(original)
    for text in [["missing": "Text"], ["a": " \n "], ["a": "Valid", "b": ""]] {
        await #expect(throws: JottieError.self) {
            try await store.editTranscript(meetingID: original.id, text: text, assignments: [:],
                expectedRevision: original.transcriptRevision, expectedSpeakerRevision: original.speakerRevision)
        }
    }
    for assignments in [["missing": SpeakerAttribution(name: "Alex", method: "manual")], ["a": SpeakerAttribution(name: "Alex", method: "analysis")]] {
        await #expect(throws: JottieError.self) {
            try await store.editTranscript(meetingID: original.id, text: ["a": "Valid"], assignments: assignments,
                expectedRevision: original.transcriptRevision, expectedSpeakerRevision: original.speakerRevision)
        }
    }
    #expect(try await store.meeting(original.id) == original)
}

@Test func editingCleanedPassagesRetainsSourceLinksAndPropagatesManualSpeakerChoice() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LibraryStore(root: root)
    var original = editingFixture(); original.speakerNames = ["them 1": "Previous Name"]
    try await store.save(original)
    let result = TranscriptCleanupResult(changes: [TranscriptTextChange(segmentID: "a",
        originalText: original.segments.map(\.text).joined(separator: " "), replacementText: "The lunch is ready. Please review it.",
        kind: "merge", reason: "Join fragments.", sourceSegmentIDs: ["a", "b"])])
    let cleanup = TranscriptCleanupRevision(meeting: original, promptRevision: "test", model: "synthetic", effort: "low", result: result)
    try await store.saveCleanupDraft(cleanup, meetingID: original.id)
    try await store.applyCleanup(meetingID: original.id, draftID: cleanup.id, changeIDs: ["a"], speakerIDs: [])
    let cleaned = try await store.meeting(original.id)
    try await store.editTranscript(meetingID: original.id, text: ["a": "The launch is ready. Please review it."],
        assignments: ["a": SpeakerAttribution(name: "Alex Example", employeeID: "alex", method: "manual")],
        expectedRevision: cleaned.transcriptRevision, expectedSpeakerRevision: cleaned.speakerRevision)
    let value = try await store.meeting(original.id)
    #expect(value.originalTranscript == original.segments && value.transcriptSourceSegmentIDs?["a"] == ["a", "b"])
    #expect(value.speakerAttributions?["b"]?.name == "Alex Example")
    #expect(value.cleanupDraft == nil)
    try await store.restoreOriginalTranscript(meetingID: value.id, expectedRevision: value.transcriptRevision)
    #expect(try await store.meeting(value.id).displaySpeakerNames.values.allSatisfy { $0 == "Alex Example" })
}

@Test func speakerOnlyEditingPreservesTextAndAllowsAnExplicitUnknownSpeaker() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LibraryStore(root: root)
    var original = editingFixture(); original.speakerNames = ["them 1": "Previous Name"]
    try await store.save(original)
    try await store.editTranscript(meetingID: original.id, text: [:], assignments: [:],
        expectedRevision: original.transcriptRevision, expectedSpeakerRevision: original.speakerRevision)
    #expect(try await store.meeting(original.id) == original)
    try await store.editTranscript(meetingID: original.id, text: [:],
        assignments: ["a": SpeakerAttribution(name: " ", jobTitle: "Stale role", employeeID: "stale", method: "manual")],
        expectedRevision: original.transcriptRevision, expectedSpeakerRevision: original.speakerRevision)
    let value = try await store.meeting(original.id)
    #expect(value.segments == original.segments && value.transcriptRevision == original.transcriptRevision)
    #expect(value.cleanupOriginalSegments == nil)
    #expect(value.speakerName(for: value.segments[0]).hasPrefix("Speaker "))
    #expect(value.speakerName(for: value.segments[1]) == "Previous Name")
    #expect(value.speakerAttributions?["a"]?.employeeID == nil && value.speakerAttributions?["a"]?.jobTitle == nil)
}

@Test func calendarSpeakerShortlistUsesInviteesAndUnambiguousDirectoryMatches() {
    var meeting = editingFixture()
    let people = [DirectoryPerson(id: "alex", name: "Alex Example", workEmail: "alex@example.test", jobTitle: "Writer"),
                  DirectoryPerson(id: "other", name: "Other Person", workEmail: "other@example.test")]
    meeting.calendarContext = CalendarEventContext(id: "event", calendarID: "calendar", calendarTitle: "Test", title: "Planning",
        start: Date(), end: Date(), invitees: meeting.participants + ["Alex Example <alex@example.test>"])
    let candidates = SpeakerChoice.calendarCandidates(for: meeting, people: people)
    #expect(candidates.count == 2)
    #expect(candidates[0].employeeID == "alex" && candidates[0].jobTitle == "Writer")
    #expect(candidates[1].name == "Guest Visitor" && candidates[1].employeeID == nil)
    #expect(!candidates.contains { $0.employeeID == "other" })
    meeting.calendarContext?.invitees = ["Alex Example <conflicting@example.test>"]
    #expect(SpeakerChoice.calendarCandidates(for: meeting, people: people).first?.employeeID == nil)
}

@Test func speakerAutocompleteSearchesFullDirectoryWithAliasesEmailAndDuplicateNames() {
    var people = (0..<30).map { DirectoryPerson(id: "\($0)", name: "Alex Example", workEmail: "alex\($0)@example.test", jobTitle: "Writer") }
    people.append(DirectoryPerson(id: "fi", name: "Fíona Gray", workEmail: "fi@example.test", jobTitle: "Designer", aliases: ["Fifi"]))
    #expect(SpeakerChoice.directoryMatches("Alex", people: people).count == 30)
    #expect(SpeakerChoice.directoryMatches("Fifi", people: people).first?.employeeID == "fi")
    #expect(SpeakerChoice.directoryMatches("fiona", people: people).first?.employeeID == "fi")
    #expect(SpeakerChoice.directoryMatches("fi@example.test", people: people).first?.employeeID == "fi")
    #expect(SpeakerChoice.directoryMatches("designer", people: people).first?.employeeID == "fi")
    #expect(SpeakerChoice.directoryMatches("  ", people: people).isEmpty)
}

@Test func inlineEditsMergeDifferentPassagesAndKeepTheLatestSpeakerAssignments() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LibraryStore(root: root), original = editingFixture()
    try await store.save(original)
    async let first: Void = store.editTranscriptPassage(meetingID: original.id, segmentID: "a", text: "The launch is ready.", expectedText: original.segments[0].text)
    async let second: Void = store.editTranscriptPassage(meetingID: original.id, segmentID: "b", text: "Review by Friday.", expectedText: original.segments[1].text)
    _ = try await (first, second)
    try await store.assignTranscriptSpeaker(meetingID: original.id, label: "them 1",
        assignment: SpeakerAttribution(name: "Alex Example", employeeID: "alex", method: "manual"))
    try await store.editTranscriptPassage(meetingID: original.id, segmentID: "a", text: "The launch is approved.", expectedText: "The launch is ready.")
    let saved = try await store.meeting(original.id)
    #expect(saved.segments.map(\.text) == ["The launch is approved.", "Review by Friday."])
    #expect(saved.displaySpeakerNames.values.allSatisfy { $0 == "Alex Example" })
    #expect(saved.originalTranscript == original.segments)
}

@Test func inlineEditsRejectConflictsAndMissingPassagesButAllowAnAlreadySavedValue() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LibraryStore(root: root), original = editingFixture()
    try await store.save(original)
    try await store.editTranscriptPassage(meetingID: original.id, segmentID: "a", text: "First correction.", expectedText: original.segments[0].text)
    try await store.editTranscriptPassage(meetingID: original.id, segmentID: "a", text: "First correction.", expectedText: original.segments[0].text)
    for (id, replacement) in [("a", "Conflicting correction."), ("missing", "Missing passage.")] {
        await #expect(throws: JottieError.self) {
            try await store.editTranscriptPassage(meetingID: original.id, segmentID: id, text: replacement, expectedText: original.segments[0].text)
        }
    }
    #expect(try await store.meeting(original.id).segments[0].text == "First correction.")
}

@Test func inlineSpeakerChoiceReassignsEveryInstanceOfOnlyTheSelectedAcousticSpeaker() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LibraryStore(root: root)
    var original = editingFixture()
    original.segments.append(Segment(id: "c", speaker: "me 1", text: "Keep this speaker."))
    original.transcriptRevision = Codec.hash(try Codec.encode(original.segments))
    try await store.save(original)
    try await store.assignTranscriptSpeaker(meetingID: original.id, label: "them 1",
        assignment: SpeakerAttribution(name: "Fiona Gray", jobTitle: "Designer", employeeID: "fi", method: "manual"))
    let saved = try await store.meeting(original.id)
    #expect(saved.speakerAttributions?["a"]?.employeeID == "fi")
    #expect(saved.speakerAttributions?["b"]?.employeeID == "fi")
    #expect(saved.speakerAttributions?["c"] == nil)
    #expect(saved.segments == original.segments)
}
