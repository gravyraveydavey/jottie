import AppKit
import Foundation
import Testing
import JottieModels
import JottieLibrary
import JottieKnowledge

private let teamsTranscript = """
Synthetic project planning-Meeting Recording
September 28, 2026, 3:39PM
32m 18s
\u{2028}Casey Lane started transcription
\u{2028}Alex Morgan   0:03\u{2028}We approved the pilot.\u{2028}Keep the original recording.
\u{2028}Jamie Chen   1:00\u{2028}I will check it.
\u{2028}Taylor Reed   1:00\u{2028}Thank you.
\u{2028}Alex Morgan   1:02:03\u{2028}The final section.
\u{2028}Casey Lane stopped transcription
"""

private func importDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("jottie-doc-speakers-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@Test @MainActor func wordImportPreservesTeamsSpeakerTurnsAndUnicodeLineBreaks() async throws {
    let root = try importDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let document = root.appendingPathComponent("Planning.docx")
    let string = NSAttributedString(string: teamsTranscript)
    let bytes = try string.data(from: NSRange(location: 0, length: string.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
    try bytes.write(to: document)
    let store = try LibraryStore(root: root.appendingPathComponent("library"))
    let report = try await store.importTranscripts(from: [document])
    #expect(report.imported == 1 && report.failures.isEmpty)
    let meeting = try #require(try await store.meetings().first)
    #expect(meeting.segments.map(\.speaker) == ["Alex Morgan", "Jamie Chen", "Taylor Reed", "Alex Morgan"])
    #expect(meeting.segments.map(\.startMS) == [3000, 60000, 60000, 3723000])
    #expect(meeting.segments[0].text == "We approved the pilot.\nKeep the original recording.")
    #expect(meeting.segments.last?.text == "The final section.")
    #expect(meeting.reconciledSpeakers.count == 3)
    #expect(meeting.reconciledSpeakers.allSatisfy { $0.sources.contains("Transcript label") && !$0.sources.contains("Voice detected") })
    #expect(meeting.participants.isEmpty) // document names are not invitations
    let again = try await store.importTranscripts(from: [document])
    #expect(again.unchanged == 1)
    #expect(try Data(contentsOf: document) == bytes)
}

@Test func savedCollapsedDocumentRepairsLocallyWithoutDuplicateOrLostHistory() async throws {
    let root = try importDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LibraryStore(root: root)
    let folder = Folder(name: "Manual filing")
    try await store.saveFolder(folder)
    var original = Meeting(sourceID: "document:legacy", title: "Planning", segments: [Segment(id: "s1", speaker: "unknown", text: teamsTranscript)])
    let digest = Codec.hash("synthetic Word bytes")
    original.sourceMetadata = ["documentSHA256": digest, "importFormat": "docx"]
    original.folderID = folder.id; original.manuallyFiled = true; original.starred = true
    original.analysis = AnalysisRevision(transcriptRevision: original.transcriptRevision, promptRevision: "old-parser",
        analysis: Analysis(title: "Pilot", summary: "The pilot was approved.", summaryEvidence: [Evidence(segmentID: "s1", quote: "We approved the pilot.")]))
    try await store.save(original)
    let history = store.meetingDirectory(original.id).appendingPathComponent("SourceTextHistory")
    try LibraryStore.directory(history)
    try Data(teamsTranscript.utf8).write(to: history.appendingPathComponent(digest + ".txt"))
    try await store.reconcile()
    let repaired = try await store.meeting(original.id)
    #expect(repaired.segments.count == 4)
    #expect(repaired.id == original.id && repaired.folderID == folder.id && repaired.manuallyFiled && repaired.starred == true)
    #expect(repaired.transcriptRevision != original.transcriptRevision)
    #expect(repaired.analysis == nil)
    #expect(FileManager.default.fileExists(atPath: store.meetingDirectory(original.id).appendingPathComponent("Analysis/\(original.analysis!.id).json").path))
    #expect(FileManager.default.fileExists(atPath: store.meetingDirectory(original.id).appendingPathComponent("TranscriptHistory/\(original.transcriptRevision).json").path))
    #expect(try await store.meetings().count == 1)
    try await store.reconcile()
    #expect(try await store.meeting(original.id).transcriptRevision == repaired.transcriptRevision)
}

@Test func automaticDocumentRepairLeavesManualSpeakerCorrectionsUntouched() async throws {
    let root = try importDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LibraryStore(root: root)
    var meeting = Meeting(sourceID: "document:corrected", title: "Planning", segments: [Segment(id: "s1", speaker: "unknown", text: teamsTranscript)])
    let digest = Codec.hash("synthetic corrected Word bytes")
    meeting.sourceMetadata = ["documentSHA256": digest, "importFormat": "docx"]
    meeting.speakerAttributions = ["s1": SpeakerAttribution(name: "", method: "manual")]
    try await store.save(meeting)
    let canonical = store.meetingDirectory(meeting.id).appendingPathComponent("meeting.json")
    let saved = try Data(contentsOf: canonical)
    let history = store.meetingDirectory(meeting.id).appendingPathComponent("SourceTextHistory")
    try LibraryStore.directory(history)
    try Data(teamsTranscript.utf8).write(to: history.appendingPathComponent(digest + ".txt"))
    try await store.reconcile()
    #expect(try Data(contentsOf: canonical) == saved)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["JOTTIE_WORD_IMPORT_VALIDATION"] != nil))
func validateProvidedWordDocumentLocally() async throws {
    let source = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["JOTTIE_WORD_IMPORT_VALIDATION"]))
    let original = try Data(contentsOf: source)
    let root = try importDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LibraryStore(root: root)
    let result = try await store.importTranscripts(from: [source])
    #expect(result.failures.isEmpty && result.imported == 1)
    let meeting = try #require(try await store.meetings().first)
    #expect(meeting.segments.count == 215)
    #expect(meeting.reconciledSpeakers.count == 3)
    #expect(meeting.segments.map(\.startMS).min() == 3000)
    #expect(meeting.segments.map(\.endMS).max() == 1938000)
    #expect(meeting.analysis == nil) // pure local import, no model or network
    #expect(try Data(contentsOf: source) == original)
}

@Test func ordinaryDocumentsRemainIntactAndDoNotInventSpeakers() async throws {
    let root = try importDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("Notes.txt")
    let text = "# Agenda\nLunch break   1:00\nNotes containing names and times are not necessarily a transcript.\n"
    try Data(text.utf8).write(to: url)
    let store = try LibraryStore(root: root.appendingPathComponent("library"))
    _ = try await store.importTranscripts(from: [url])
    let meeting = try #require(try await store.meetings().first)
    #expect(meeting.segments == [Segment(id: "s1", speaker: "unknown", text: text)])
}

@Test func reimportSameDocumentBytesUpgradesOldParserOnce() async throws {
    let root = try importDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("Planning.txt")
    try Data(teamsTranscript.utf8).write(to: url)
    let store = try LibraryStore(root: root.appendingPathComponent("library"))
    _ = try await store.importTranscripts(from: [url])
    var old = try #require(try await store.meetings().first)
    let segments = [Segment(id: "s1", speaker: "unknown", text: teamsTranscript)]
    old.segments = segments; old.transcriptRevision = Codec.hash(try Codec.encode(segments))
    old.sourceMetadata?.removeValue(forKey: "documentParserRevision")
    try await store.save(old)
    let updated = try await store.importTranscripts(from: [url])
    #expect(updated.imported == 1)
    #expect(try await store.meetings().count == 1)
    #expect(try await store.meeting(old.id).segments.count == 4)
    let again = try await store.importTranscripts(from: [url])
    #expect(again.unchanged == 1 && again.imported == 0)
}

@Test func documentNamesMatchDirectoryWithoutClaimingAnInvitation() {
    var meeting = Meeting(sourceID: "document", title: "Planning", segments: [Segment(id: "s1", speaker: "Jamie Chen", text: "I will check it.")])
    meeting.sourceMetadata = ["documentSHA256": "synthetic"]
    meeting.participantContext = [ParticipantIdentity(invitee: "Jamie Chen", employeeID: "1", name: "Jamie Chen", workEmail: nil,
        jobTitle: "Engineer", company: "test", matchedBy: "unique-name", syncedAt: Date())]
    let row = meeting.reconciledSpeakers[0]
    #expect(meeting.directoryIdentityCandidates == ["Jamie Chen"])
    #expect(row.jobTitle == "Engineer")
    #expect(row.sources.contains("BambooHR") && !row.sources.contains("Meeting invite"))
}
