import Foundation
import Testing
import JottieModels
import JottieLibrary
@testable import JottieKnowledge
import JottieMCP

private func temporary() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("jottie-test-\(UUID())")
    try LibraryStore.directory(url)
    return url
}
private func sample(_ title: String = "Planning") -> Meeting {
    Meeting(sourceID: UUID().uuidString, title: title, startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            segments: [Segment(id: "s1", speaker: "me", text: "We approved the café launch. Alex will send the plan."),
                       Segment(id: "s2", speaker: "them", text: "The deadline is still uncertain.")])
}
private func extraction(_ meeting: Meeting, tag: String = "Launch") -> AnalysisRevision {
    let a = Analysis(title: "Café launch", summary: "The launch was approved; the deadline remains uncertain.",
        summaryEvidence: [Evidence(segmentID: "s1", quote: "We approved the café launch.")],
        topics: ["Launch planning"], tags: [tag], primaryTag: tag,
        decisions: [Finding(text: "Approve launch", status: "confirmed", evidence: [Evidence(segmentID: "s1", quote: "We approved")])],
        actions: [Finding(text: "Send the plan", status: "committed", owner: "Alex", evidence: [Evidence(segmentID: "s1", quote: "Alex will send the plan.")])])
    return AnalysisRevision(transcriptRevision: meeting.transcriptRevision, promptRevision: "test", analysis: a)
}

@Test func filesSurviveIndexRebuildAndReopen() async throws {
    let root = try temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LibraryStore(root: root)
    let parent = Folder(name: "Client"), child = Folder(name: "Launch", aliases: ["Café"])
    try await store.saveFolder(parent)
    var nested = child; nested.parentID = parent.id
    try await store.saveFolder(nested)
    let meeting = sample()
    try await store.save(meeting)
    try await store.apply(extraction(meeting), to: meeting.id)
    #expect(try await store.meeting(meeting.id).folderID == child.id)
    let ledger = try WorkLedger(root: root)
    #expect(try await ledger.begin("job", stage: "Test"))
    try await ledger.fail("job", message: "Offline")
    try await store.rebuildIndex()
    #expect(try await ledger.statuses().count == 1)
    let reopened = try LibraryStore(root: root)
    var query = SearchQuery()
    query.text = "café"; query.folderID = parent.id
    #expect(try await reopened.search(query).map(\.id) == [meeting.id])
    query.tag = "LAUNCH"
    #expect(try await reopened.search(query).count == 1)
    query.inbox = true
    #expect(try await reopened.search(query).isEmpty)
}

@Test func manualFilingWinsAndAliasesAreAmbiguitySafe() async throws {
    let root = try temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LibraryStore(root: root)
    var first = Folder(name: "Launch"), second = Folder(name: "Other", aliases: ["launch"])
    try await store.saveFolder(first); try await store.saveFolder(second)
    let meeting = sample()
    try await store.save(meeting); try await store.apply(extraction(meeting), to: meeting.id)
    #expect(try await store.meeting(meeting.id).folderID == nil)
    try await store.file([meeting.id], into: second.id)
    try await store.apply(extraction(meeting), to: meeting.id)
    #expect(try await store.meeting(meeting.id).folderID == second.id)
    first.name = "Renamed"; try await store.saveFolder(first)
    #expect(try await store.meeting(meeting.id).manuallyFiled == true)
    var cycle = first; cycle.parentID = second.id; try await store.saveFolder(cycle)
    var reverse = second; reverse.parentID = first.id
    await #expect(throws: (any Error).self) { try await store.saveFolder(reverse) }
}

@Test func importsOnlyTextAndDeduplicates() async throws {
    let root = try temporary(), source = try temporary()
    defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: source) }
    let transcript = Data(#"{"segments":[{"speaker":"me","start_ms":0,"end_ms":100,"text":"Hello"}]}"#.utf8)
    try transcript.write(to: source.appendingPathComponent("transcript.json"))
    try Data(#"{"started":"2026-10-25T10:00:00Z","title":"Test"}"#.utf8).write(to: source.appendingPathComponent("meta.json"))
    try Data("private audio".utf8).write(to: source.appendingPathComponent("audio.m4a"))
    try Data("An existing meeting summary.".utf8).write(to: source.appendingPathComponent("summary.md"))
    let store = try LibraryStore(root: root)
    let first = try await store.importAmanu(source), second = try await store.importAmanu(source)
    #expect(first.id == second.id)
    #expect(first.importedSummary == "An existing meeting summary.")
    #expect(try Data(contentsOf: store.meetingDirectory(first.id).appendingPathComponent("SourceTranscriptHistory/\(Codec.hash(transcript)).json")) == transcript)
    #expect(try await store.meetings().count == 1)
    #expect(try Data(contentsOf: source.appendingPathComponent("transcript.json")) == transcript)
    #expect(!FileManager.default.fileExists(atPath: store.meetingDirectory(first.id).appendingPathComponent("audio.m4a").path))
    #expect(FileManager.default.fileExists(atPath: source.appendingPathComponent("audio.m4a").path))
}

@Test func invalidEvidenceCannotCommit() async throws {
    let root = try temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LibraryStore(root: root), meeting = sample()
    try await store.save(meeting)
    var revision = extraction(meeting)
    revision.analysis.summaryEvidence = [Evidence(segmentID: "s1", quote: "Words never spoken")]
    await #expect(throws: (any Error).self) { try await store.apply(revision, to: meeting.id) }
    var unsafe = extraction(meeting); unsafe.id = "../../outside-library"
    await #expect(throws: (any Error).self) { try await store.apply(unsafe, to: meeting.id) }
    #expect(try await store.meeting(meeting.id).analysis == nil)
}

@Test func contextIsInvalidatedWhenMeetingMovesOrIsTrashed() async throws {
    let root = try temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LibraryStore(root: root), a = Folder(name: "Launch"), b = Folder(name: "Elsewhere")
    try await store.saveFolder(a); try await store.saveFolder(b)
    let meeting = sample(); try await store.save(meeting)
    try await store.apply(extraction(meeting), to: meeting.id)
    let folders = try await store.folders()
    let original = LibraryStore.contextFingerprint(folder: a, folders: folders, meetings: try await store.meetings())
    let context = FolderContext(folderID: a.id, inputRevision: original, overview: "Launch approved.")
    try await store.saveContext(context)
    try await store.file([meeting.id], into: b.id)
    #expect(LibraryStore.contextFingerprint(folder: a, folders: folders, meetings: try await store.meetings()) != original)
    await #expect(throws: (any Error).self) { try await store.saveContext(context) }
    try await store.trash([meeting.id])
    #expect(try await store.meetings().isEmpty)
    #expect(try await store.context(a.id)?.overview == "Launch approved.")
}

@Test func durableLeasesPreventConcurrentWorkAndRetriesStop() async throws {
    let root = try temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let a = try WorkLedger(root: root), b = try WorkLedger(root: root)
    let now = Date()
    #expect(try await a.begin("analysis", stage: "Analysis", now: now))
    #expect(try await b.begin("analysis", stage: "Analysis", now: now) == false)
    for index in 0..<5 {
        try await a.fail("analysis", message: "Offline", now: now)
        if index < 4 { #expect(try await a.begin("analysis", stage: "Analysis", now: now.addingTimeInterval(Double(index + 1) * 4000))) }
    }
    #expect(try await a.statuses().first?.state == "held")
    try await b.retry("analysis")
    #expect(try await a.begin("analysis", stage: "Analysis"))
}

@Test func mcpIsReadOnlyAndPaginatesEvidence() async throws {
    let root = try temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LibraryStore(root: root), meeting = sample()
    try await store.save(meeting)
    let before = try Data(contentsOf: store.meetingDirectory(meeting.id).appendingPathComponent("meeting.json"))
    let server = try JottieServer(root: root)
    let text = try await server.call(name: "get_transcript", arguments: ["meetingID": .string(meeting.id.uuidString), "limit": .int(1)])
    let value = try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
    #expect((value["segments"] as? [[String: Any]])?.count == 1)
    #expect(value["nextCursor"] as? String == "1")
    #expect(try Data(contentsOf: store.meetingDirectory(meeting.id).appendingPathComponent("meeting.json")) == before)
    await #expect(throws: (any Error).self) { try await server.call(name: "get_meeting", arguments: ["meetingID": .string("../../elsewhere")]) }
    await #expect(throws: (any Error).self) { try await server.call(name: "delete_meeting", arguments: [:]) }
    let reader = try LibraryStore(root: root, readOnly: true)
    await #expect(throws: (any Error).self) { try await reader.save(meeting) }
}

private actor FakeRunner: StructuredRunner {
    var values: [Data]
    var prompts: [String] = []
    init(_ values: [Data]) { self.values = values }
    func run(prompt: String, schema: Data) throws -> Data {
        prompts.append(prompt)
        guard !values.isEmpty else { throw JottieError.unavailable("No fixture response") }
        return values.removeFirst()
    }
}

@Test func longMeetingsKeepExtractedActionsDuringSynthesis() async throws {
    var meeting = sample()
    meeting.segments[0].text += String(repeating: " additional material", count: 3000)
    let sections = CodexAnalyzer.chunks(meeting.segments, limit: 48_000)
    #expect(sections.allSatisfy { $0.reduce(0) { $0 + $1.text.utf8.count } <= 48_000 })
    #expect(sections.flatMap { $0 }.filter { $0.id == "s1" }.map(\.text).joined() == meeting.segments[0].text)
    let a = extraction(meeting).analysis
    var b = a; b.actions = []; b.decisions = []
    let runner = FakeRunner([try Codec.encode(a), try Codec.encode(b), try Codec.encode(b)])
    let result = try await CodexAnalyzer(runner: runner).analyze(meeting, prompt: Prompts.summary, folders: [])
    #expect(result.actions.count == 1)
    #expect(result.decisions.count == 1)
    #expect(await runner.prompts.count == 3)
}

@Test func codexIsIsolatedAndHasNoPaidFallback() {
    let args = CodexRunner.arguments(schema: URL(fileURLWithPath: "/tmp/schema"), output: URL(fileURLWithPath: "/tmp/out"))
    #expect(args.contains("--ignore-user-config"))
    #expect(args.contains("--ephemeral"))
    #expect(args.contains("forced_login_method=\"chatgpt\""))
    #expect(args.contains("features.shell_tool=false"))
    #expect(args.contains("features.plugins=false"))
    #expect(!args.contains("--dangerously-bypass-approvals-and-sandbox"))
}

private actor CountingAnalyzer: MeetingAnalyzer {
    var calls = 0
    func analyze(_ meeting: Meeting, prompt: String, folders: [Folder]) -> Analysis {
        calls += 1
        return extraction(meeting).analysis
    }
}
private actor CountingContext: FolderContextService {
    var calls = 0
    func update(folder: Folder, meetings: [Meeting], previous: FolderContext?) -> FolderContext {
        calls += 1
        return FolderContext(folderID: folder.id, inputRevision: "", overview: "\(meetings.count) meetings",
            sources: meetings.compactMap { meeting in
                meeting.analysis.map { ContextSource(meetingID: meeting.id, revision: $0.id, segmentID: "s1") }
            })
    }
}

@Test func nativePipelineFilesAndRefreshesOnlyChangedFolders() async throws {
    let root = try temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LibraryStore(root: root)
    let parent = Folder(name: "Client")
    var launch = Folder(name: "Launch"); launch.parentID = parent.id
    let other = Folder(name: "Other")
    try await store.saveFolder(parent); try await store.saveFolder(launch); try await store.saveFolder(other)
    let meeting = sample(); try await store.save(meeting)
    var settings = LibrarySettings(); settings.analysisEnabled = true
    try await store.saveSettings(settings)
    let analyzer = CountingAnalyzer(), contexts = CountingContext()
    let coordinator = try KnowledgeCoordinator(store: store, analyzer: analyzer, contexts: contexts)
    await coordinator.run(updateNow: true)
    #expect(try await store.meeting(meeting.id).folderID == launch.id)
    #expect(try await store.context(parent.id)?.overview == "1 meetings")
    let count = await contexts.calls
    await coordinator.run(updateNow: true)
    #expect(await contexts.calls == count)
    settings.summaryPrompt += "\nUse clear language."
    try await store.saveSettings(settings)
    await coordinator.run(updateNow: true)
    #expect(await analyzer.calls == 1) // prompt changes do not silently regenerate history
    try await store.file([meeting.id], into: other.id)
    await coordinator.run(updateNow: true)
    #expect(try await store.context(launch.id)?.overview == "0 meetings")
    #expect(try await store.context(parent.id)?.overview == "0 meetings")
    try await store.file([meeting.id], into: launch.id)
    await coordinator.run(updateNow: true)
    #expect(try await store.context(parent.id)?.overview == "1 meetings") // completed old fingerprint is reusable
    try await coordinator.regenerate(meeting.id)
    #expect(await analyzer.calls == 2)
    #expect(try await store.meeting(meeting.id).manuallyFiled == true)
}

@Test func removedFolderEvidenceIsNotSentToTheNextReduction() async throws {
    let current = sample()
    let revision = extraction(current)
    var meeting = current; meeting.analysis = revision
    let source = ContextSource(meetingID: meeting.id, revision: revision.id, segmentID: "s1")
    let response: [String: Any] = ["overview": "Current launch approved", "decisions": [], "actions": [],
        "questions": [], "recentChanges": [], "sources": [["meetingID": meeting.id.uuidString, "revision": revision.id, "segmentID": "s1"]]]
    let runner = FakeRunner([try JSONSerialization.data(withJSONObject: response)])
    let folder = Folder(name: "Current")
    let old = FolderContext(folderID: folder.id, inputRevision: "old", overview: "OLD SECRET",
        sources: [ContextSource(meetingID: UUID(), revision: "removed", segmentID: "s1")])
    let result = try await CodexFolderContext(runner: runner).update(folder: folder, meetings: [meeting], previous: old)
    #expect(result.sources == [source])
    #expect(await runner.prompts.first?.contains("OLD SECRET") == false)
}

@Test func interruptedBundlesAndExternalEditsReconcileSafely() async throws {
    let root = try temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LibraryStore(root: root)
    var meeting = sample()
    try await store.save(meeting); try await store.rebuildIndex()
    let incomplete = store.meetingDirectory(UUID())
    try LibraryStore.directory(incomplete)
    try Data("unfinished".utf8).write(to: incomplete.appendingPathComponent("transcript.md"))
    #expect(try await store.meetings().count == 1)
    meeting.title = "Externally renamed"
    try Codec.encode(meeting).write(to: store.meetingDirectory(meeting.id).appendingPathComponent("meeting.json"), options: .atomic)
    var query = SearchQuery(); query.text = "Externally"
    let reader = try LibraryStore(root: root, readOnly: true)
    #expect(try await reader.search(query).count == 1) // stale SQL must not hide canonical edits
    try await store.reconcile()
    #expect(try await store.search(query).count == 1)
    #expect(try String(contentsOf: store.meetingDirectory(meeting.id).appendingPathComponent("meeting.md"), encoding: .utf8).hasPrefix("# Externally renamed"))
}
