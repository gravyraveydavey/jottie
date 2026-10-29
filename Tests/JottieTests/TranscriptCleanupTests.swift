import Foundation
import SQLite3
import Testing
import JottieModels
import JottieLibrary
import JottieKnowledge
@testable import JottieUI
import JottieMCP

private func cleanupFixture() -> Meeting {
    var meeting = Meeting(sourceID: "synthetic-cleanup", title: "Synthetic launch planning", segments: [
        Segment(id: "intro", speaker: "them 1", startMS: 0, endMS: 1500, text: "I'm Alex. Please review the launch plan."),
        Segment(id: "echo", speaker: "me 2", startMS: 800, endMS: 2300, text: "I'm Alex. Please review the launch plan."),
        Segment(id: "local", speaker: "me 1", startMS: 3000, endMS: 5000, text: "I will check the lunch plan on Friday.")
    ], participants: ["Alex Example <alex@example.test>"])
    var context = RecordingContext()
    context.routes = [AudioRouteContext(at: Date(timeIntervalSince1970: 0),
        input: AudioDeviceContext(name: "Test microphone", transport: "usb", kind: "microphone", source: "core_audio_terminal"),
        output: AudioDeviceContext(name: "Test speakers", transport: "built_in", kind: "speakers", source: "core_audio_terminal"), outputSource: "call_app")]
    meeting.recordingContext = context
    return meeting
}
private func cleanupResult() -> TranscriptCleanupResult {
    TranscriptCleanupResult(changes: [
        TranscriptTextChange(segmentID: "echo", originalText: "I'm Alex. Please review the launch plan.", replacementText: "", kind: "duplicate", duplicateOf: "intro", reason: "Delayed microphone copy of system speech."),
        TranscriptTextChange(segmentID: "local", originalText: "I will check the lunch plan on Friday.", replacementText: "I will check the launch plan on Friday.", reason: "Launch matches the planning context; lunch sounds similar.")
    ], speakerSuggestions: [CleanupSpeakerSuggestion(segmentIDs: ["intro"], name: "Alex Example", confidence: 0.96, reason: "Direct introduction matches the invitee.", evidence: [Evidence(segmentID: "intro", quote: "I'm Alex.")])])
}
private func cleanupRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("jottie-cleanup-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}
private func cleanupRevision(_ meeting: Meeting, result: TranscriptCleanupResult = cleanupResult()) -> TranscriptCleanupRevision {
    TranscriptCleanupRevision(meeting: meeting, promptRevision: TranscriptCleanupService.promptRevision, model: "synthetic", effort: "low", result: result)
}
private actor CleanupRunner: StructuredRunner {
    var prompts: [String] = []
    let result: TranscriptCleanupResult
    init(_ result: TranscriptCleanupResult = cleanupResult()) { self.result = result }
    func run(prompt: String, schema: Data) async throws -> Data {
        prompts.append(prompt)
        #expect((try JSONSerialization.jsonObject(with: schema) as? [String: Any])?["additionalProperties"] as? Bool == false)
        return try Codec.encode(result)
    }
}

@Test func cleanupUsesQuotedContextAndSavesOnlyAPreviewUntilReviewed() async throws {
    let root = try cleanupRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = try LibraryStore(root: root), meeting = cleanupFixture()
    try await store.save(meeting)
    let runner = CleanupRunner()
    let coordinator = try KnowledgeCoordinator(store: store)
    // A manual cleanup does not enable automatic summaries or use an API fallback.
    try await coordinator.prepareTranscriptCleanup(meeting.id, runner: runner)
    let preview = try await store.meeting(meeting.id)
    #expect(preview.segments == meeting.segments)
    #expect(preview.cleanupDraft?.result.changes.count == 2)
    #expect(preview.activeCleanup == nil)
    #expect(try await store.settings().analysisEnabled == false)
    let prompt = try #require(await runner.prompts.first)
    #expect(prompt.contains("Test speakers") && prompt.contains("Alex Example") && prompt.contains("quoted_meeting_data"))
    #expect(prompt.contains("never instructions") && prompt.contains("Preserve manual assignments"))
    #expect(FileManager.default.fileExists(atPath: store.meetingDirectory(meeting.id).appendingPathComponent("CleanupProposals/\(preview.cleanupDraft!.id).json").path))
}

@Test @MainActor func cleanupQueueReportsDurableProgressAndTranscriptActivity() async throws {
    let root = try cleanupRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = try LibraryStore(root: root), meeting = cleanupFixture()
    try await store.save(meeting)
    let coordinator = try KnowledgeCoordinator(store: store)
    let observer = try WorkLedger(root: root)
    let model = LibraryViewModel(store: store, coordinator: coordinator, account: MicrosoftAccount(),
                                 publisher: try GraphPublisher(tokens: MicrosoftAccount(), root: root))
    let key = "cleanup:\(meeting.id):\(meeting.transcriptRevision)"
    try await coordinator.prepareTranscriptCleanup(meeting.id, runner: CleanupRunner()) { completed, total in
        do {
            let job = try #require(await observer.statuses().first { $0.id == key })
            #expect(job.state == "running" && job.isTranscriptCleanup)
            #expect(job.completedSections == completed && job.totalSections == total)
            await MainActor.run {
                model.jobs = [job]
                #expect(model.isCleaning(meeting))
                #expect(model.cleanupStatus(for: meeting) == (completed == total ? "Preparing review…" : "Cleaning section \(completed + 1) of \(total)…"))
                #expect(!model.isCleaning(Meeting(sourceID: "another-meeting", title: "Another invented meeting", segments: [])))
            }
        } catch { Issue.record(error) }
    }
    await model.reload()
    #expect(model.jobs.isEmpty && !model.isCleaning(meeting))
    let progress = try await coordinator.processingProgress()
    #expect(progress.completed == 1 && progress.total == 1)
    // A subsequent manual run starts with fresh section counters.
    #expect(try await observer.begin(key, stage: "Transcript cleanup preview", allowCompleted: true))
    try await observer.reportSections(key, completed: 1, total: 3)
    let reopened = try WorkLedger(root: root)
    let running = try #require(await reopened.statuses().first)
    #expect(running.sectionProgress == "Cleaning section 2 of 3…")
    try await reopened.finish(key)
    #expect(try await reopened.begin(key, stage: "Transcript cleanup preview", allowCompleted: true))
    #expect(try await reopened.statuses().first?.completedSections == nil)
    #expect(try await reopened.statuses().first?.totalSections == nil)
}

@Test func cleanupProgressMigratesExistingQueueWithoutLosingJobs() async throws {
    let root = try cleanupRoot(); defer { try? FileManager.default.removeItem(at: root) }
    var old: OpaquePointer?
    try #require(sqlite3_open(root.appendingPathComponent("work.sqlite").path, &old) == SQLITE_OK)
    try #require(sqlite3_exec(old, "CREATE TABLE jobs(id TEXT PRIMARY KEY,stage TEXT NOT NULL,state TEXT NOT NULL,attempts INTEGER NOT NULL DEFAULT 0,next REAL NOT NULL DEFAULT 0,message TEXT,receipt BLOB); INSERT INTO jobs(id,stage,state,message) VALUES('analysis:old','Summary','held','Retained error');", nil, nil, nil) == SQLITE_OK)
    sqlite3_close(old)
    let ledger = try WorkLedger(root: root)
    let previous = try #require(await ledger.statuses().first)
    #expect(previous.id == "analysis:old" && previous.message == "Retained error" && previous.completedSections == nil)
    #expect(try await ledger.begin("cleanup:new", stage: "Transcript cleanup preview"))
    try await ledger.reportSections("cleanup:new", completed: 1, total: 2)
    #expect(try await ledger.statuses().first { $0.id == "cleanup:new" }?.sectionProgress == "Cleaning section 2 of 2…")
}

@Test func reviewedCleanupPreservesOriginalHistoryFilingManualNamesAndSearch() async throws {
    let root = try cleanupRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = try LibraryStore(root: root)
    var original = cleanupFixture(); original.speakerNames["me 1"] = "Casey Example"
    original.manuallyFiled = true; original.starred = true
    try await store.save(original)
    let analysis = AnalysisRevision(transcriptRevision: original.transcriptRevision, promptRevision: "test", analysis: Analysis(title: "Planning", summary: "Review the launch plan.", summaryEvidence: [Evidence(segmentID: "intro", quote: "Please review the launch plan.")]))
    try await store.apply(analysis, to: original.id)
    let revision = cleanupRevision(try await store.meeting(original.id))
    try await store.saveCleanupDraft(revision, meetingID: original.id)
    try await store.applyCleanup(meetingID: original.id, draftID: revision.id, changeIDs: ["echo", "local"], speakerIDs: [])
    let cleaned = try await store.meeting(original.id)
    #expect(cleaned.segments.map(\.id) == ["intro", "local"])
    #expect(cleaned.segments.last?.text == "I will check the launch plan on Friday.")
    #expect(cleaned.originalTranscript == original.segments)
    #expect(cleaned.displaySpeakerNames["intro"] == original.displaySpeakerNames["intro"])
    #expect(cleaned.reconciledSpeakers.first { $0.label == "them 1" }?.name == original.reconciledSpeakers.first { $0.label == "them 1" }?.name)
    #expect(cleaned.segments.last?.startMS == 3000 && cleaned.segments.last?.speaker == "me 1")
    #expect(cleaned.speakerNames == original.speakerNames && cleaned.manuallyFiled && cleaned.starred == true)
    #expect(cleaned.analysis == nil && cleaned.sourceMetadata?["cleanupNeedsSummary"] == "true")
    #expect(cleaned.cleanupDraft == nil && cleaned.activeCleanup?.selectedSpeakerIDs == [])
    #expect(try await store.cleanupHistory(meetingID: original.id).count == 1)
    #expect(FileManager.default.fileExists(atPath: store.meetingDirectory(original.id).appendingPathComponent("Analysis/\(analysis.id).json").path))
    #expect(try Codec.decode([Segment].self, from: Data(contentsOf: store.meetingDirectory(original.id).appendingPathComponent("TranscriptHistory/\(original.transcriptRevision).json"))) == original.segments)
    var query = SearchQuery(); query.text = "lunch"
    #expect(try await store.search(query).isEmpty)
    let restarted = try LibraryStore(root: root)
    #expect(try await restarted.meeting(original.id).originalTranscript == original.segments)
    try await restarted.restoreOriginalTranscript(meetingID: original.id, expectedRevision: cleaned.transcriptRevision)
    let restored = try await restarted.meeting(original.id)
    #expect(restored.segments == original.segments && restored.cleanupOriginalSegments == nil)
    #expect(try await restarted.cleanupHistory(meetingID: original.id).count == 1)
    #expect(try await restarted.search(query).count == 1)
}

@Test func cleanupSpeakerSuggestionsAreIndependentlySelectedAndCannotOverrideManualCorrections() async throws {
    let root = try cleanupRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = try LibraryStore(root: root), meeting = cleanupFixture()
    try await store.save(meeting)
    let revision = cleanupRevision(meeting)
    try await store.saveCleanupDraft(revision, meetingID: meeting.id)
    try await store.applyCleanup(meetingID: meeting.id, draftID: revision.id, changeIDs: [], speakerIDs: [revision.result.speakerSuggestions[0].id])
    let named = try await store.meeting(meeting.id)
    #expect(named.segments == meeting.segments && named.speakerAttributions?["intro"]?.name == "Alex Example")
    #expect(named.speakerAttributions?["intro"]?.method == "manual")
    let next = cleanupRevision(named)
    try await store.saveCleanupDraft(next, meetingID: meeting.id)
    await #expect(throws: (any Error).self) {
        try await store.applyCleanup(meetingID: meeting.id, draftID: next.id, changeIDs: [], speakerIDs: [next.result.speakerSuggestions[0].id])
    }
    #expect(try await store.meeting(meeting.id).speakerAttributions?["intro"] == named.speakerAttributions?["intro"])
}

@Test func changedRecordingContextOrSpeakerAssignmentsInvalidateCleanupPreview() async throws {
    let root = try cleanupRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = try LibraryStore(root: root), meeting = cleanupFixture()
    try await store.save(meeting)
    let revision = cleanupRevision(meeting)
    try await store.saveCleanupDraft(revision, meetingID: meeting.id)
    try await store.setRecordingContext(playback: "headphones", note: "USB headset", meetingID: meeting.id)
    await #expect(throws: (any Error).self) { try await store.applyCleanup(meetingID: meeting.id, draftID: revision.id, changeIDs: ["echo"], speakerIDs: []) }
    let refreshed = try await store.meeting(meeting.id)
    let fresh = cleanupRevision(refreshed)
    try await store.saveCleanupDraft(fresh, meetingID: meeting.id)
    try await store.setSpeakerAssignment(segmentIDs: ["local"], name: "Casey", role: nil, employeeID: nil, meetingID: meeting.id)
    await #expect(throws: (any Error).self) { try await store.applyCleanup(meetingID: meeting.id, draftID: fresh.id, changeIDs: ["echo"], speakerIDs: []) }
    #expect(try await store.meeting(meeting.id).segments == meeting.segments)
}

@Test func malformedCleanupCannotInventPassagesQuotesOrDeleteEveryCopy() async throws {
    let meeting = cleanupFixture()
    var invalid = cleanupResult(); invalid.changes[0].originalText = "Invented original"
    #expect(throws: (any Error).self) { try invalid.validate(against: meeting) }
    invalid = cleanupResult(); invalid.speakerSuggestions[0].evidence[0].quote = "Never said this"
    #expect(throws: (any Error).self) { try invalid.validate(against: meeting) }
    invalid = cleanupResult(); invalid.changes[0].duplicateOf = "echo"
    #expect(throws: (any Error).self) { try invalid.validate(against: meeting) }
    let root = try cleanupRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = try LibraryStore(root: root); try await store.save(meeting)
    var cycle = cleanupResult()
    cycle.changes = [cycle.changes[0], TranscriptTextChange(segmentID: "intro", originalText: meeting.segments[0].text, replacementText: "", kind: "duplicate", duplicateOf: "echo", reason: "Duplicate")]
    let revision = cleanupRevision(meeting, result: cycle)
    try await store.saveCleanupDraft(revision, meetingID: meeting.id)
    await #expect(throws: (any Error).self) { try await store.applyCleanup(meetingID: meeting.id, draftID: revision.id, changeIDs: ["intro", "echo"], speakerIDs: []) }
}

@Test func cleanupChunksRetainEveryPassageAndRejectEditsToContextOnlyPassages() async throws {
    var meeting = cleanupFixture()
    meeting.segments = (0..<12).map { Segment(id: "s\($0)", speaker: "them", text: String(repeating: "sample ", count: 30)) }
    meeting.transcriptRevision = Codec.hash(try Codec.encode(meeting.segments))
    let runner = CleanupRunner(TranscriptCleanupResult())
    _ = try await TranscriptCleanupService(runner: runner).propose(for: meeting, model: "test", effort: "", chunkLimit: 512)
    let prompts = await runner.prompts
    #expect(prompts.count > 1)
    var submitted: [String] = []
    for prompt in prompts {
        let json = try #require(prompt.components(separatedBy: "<quoted_meeting_data>\n").last?.components(separatedBy: "\n</quoted_meeting_data>").first)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        submitted += object["editablePassageIDs"] as? [String] ?? []
    }
    #expect(submitted == meeting.segments.map(\.id))
    let malicious = CleanupRunner(TranscriptCleanupResult(changes: [TranscriptTextChange(segmentID: "s1", originalText: meeting.segments[1].text, replacementText: "Changed", reason: "Wrong scope")]))
    await #expect(throws: (any Error).self) { _ = try await TranscriptCleanupService(runner: malicious).propose(for: meeting, model: "test", effort: "", chunkLimit: 512) }
}

private actor CleanedAnalyzer: MeetingAnalyzer {
    var seen: Meeting?
    func analyze(_ meeting: Meeting, prompt: String, folders: [Folder]) async throws -> Analysis {
        seen = meeting
        return Analysis(title: "Launch", summary: "Check the launch plan on Friday.", summaryEvidence: [Evidence(segmentID: "local", quote: "check the launch plan on Friday")])
    }
}
@Test func acceptedCleanupWaitsForExplicitRegenerationAndSummaryCitesSelectedRevision() async throws {
    let root = try cleanupRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = try LibraryStore(root: root), meeting = cleanupFixture()
    try await store.save(meeting)
    var settings = LibrarySettings(); settings.analysisEnabled = true
    _ = try await store.saveSettings(settings)
    let revision = cleanupRevision(meeting)
    try await store.saveCleanupDraft(revision, meetingID: meeting.id)
    try await store.applyCleanup(meetingID: meeting.id, draftID: revision.id, changeIDs: ["local", "echo"], speakerIDs: [])
    let analyzer = CleanedAnalyzer(), coordinator = try KnowledgeCoordinator(store: store, analyzer: analyzer)
    await coordinator.run()
    #expect(await analyzer.seen == nil)
    try await coordinator.regenerate(meeting.id)
    let value = try await store.meeting(meeting.id)
    #expect(value.analysis?.transcriptRevision == value.transcriptRevision)
    #expect(value.analysis?.transcriptRevision != meeting.transcriptRevision)
    #expect(value.sourceMetadata?["cleanupNeedsSummary"] == nil)
    #expect(await analyzer.seen?.segments == value.segments)
    #expect(value.originalTranscript[2].text.contains("lunch"))
}

@Test func captureRescanPreservesReviewedCleanupAndConfirmedRecordingContext() async throws {
    let root = try cleanupRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = try LibraryStore(root: root), capture = root.appendingPathComponent("capture")
    try FileManager.default.createDirectory(at: capture, withIntermediateDirectories: true)
    let original = cleanupFixture()
    struct Source: Encodable {
        struct Part: Encodable { var speaker: String; var start_ms: Int; var end_ms: Int; var text: String }
        var engine = "parakeet"; var segments: [Part]
    }
    let parts = original.segments.map { Source.Part(speaker: $0.speaker, start_ms: $0.startMS, end_ms: $0.endMS, text: $0.text) }
    try Codec.encode(Source(segments: parts)).write(to: capture.appendingPathComponent("transcript.json"))
    let context = try JSONSerialization.jsonObject(with: Codec.encode(original.recordingContext!))
    let meta: [String: Any] = ["started": "2026-10-29T09:00:00Z", "recording_context": context,
        "audio_echo_cancellation": ["processor": "synthetic-aec"], "echo_filter": ["dropped_segments": 2]]
    try JSONSerialization.data(withJSONObject: meta).write(to: capture.appendingPathComponent("meta.json"))
    let imported = try await store.importAmanu(capture)
    #expect(imported.recordingContext?.routes.first?.output.transport == "built_in")
    #expect(imported.recordingContext?.echoCancellation == "synthetic-aec" && imported.cleanupRecommendation.contains("both audio tracks"))
    try await store.setRecordingContext(playback: "speakers", note: "Confirmed in the meeting", meetingID: imported.id)
    let current = try await store.meeting(imported.id)
    let edit = TranscriptTextChange(segmentID: "s3", originalText: current.segments[2].text, replacementText: "I will check the launch plan on Friday.", reason: "Launch context")
    let revision = cleanupRevision(current, result: TranscriptCleanupResult(changes: [edit]))
    try await store.saveCleanupDraft(revision, meetingID: imported.id)
    try await store.applyCleanup(meetingID: imported.id, draftID: revision.id, changeIDs: ["s3"], speakerIDs: [])
    let rescanned = try await store.importAmanu(capture)
    #expect(rescanned.segments[2].text.contains("launch"))
    #expect(rescanned.cleanupOriginalSegments == imported.segments)
    #expect(rescanned.recordingContext?.playbackOverride == "speakers")
    #expect(rescanned.recordingContext?.userNote == "Confirmed in the meeting")
}

@Test func transportAloneDoesNotImplyAnEchoFreeRoute() {
    var context = RecordingContext()
    context.routes = [AudioRouteContext(input: AudioDeviceContext(), output: AudioDeviceContext(name: "USB peripheral", transport: "usb"), outputSource: "system_default")]
    #expect(context.playbackDescription.contains("unknown") && context.echoRisk.isEmpty)
    context.playbackOverride = "speakers"
    #expect(!context.echoRisk.isEmpty)
    context.playbackOverride = "headphones"
    #expect(context.echoRisk.isEmpty)
    context.echoSegmentsRemoved = 4
    #expect(!context.echoRisk.isEmpty)
}

private struct CancelledCleanupRunner: StructuredRunner {
    func run(prompt: String, schema: Data) async throws -> Data { throw CancellationError() }
}
@Test func failedOrCancelledCleanupDoesNotWriteAPartialRevision() async throws {
    let root = try cleanupRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = try LibraryStore(root: root), meeting = cleanupFixture()
    try await store.save(meeting)
    let before = try await store.meeting(meeting.id)
    let coordinator = try KnowledgeCoordinator(store: store)
    await #expect(throws: CancellationError.self) { try await coordinator.prepareTranscriptCleanup(meeting.id, runner: CancelledCleanupRunner()) }
    let value = try await store.meeting(meeting.id)
    #expect(value == before)
    #expect(try await store.cleanupHistory(meetingID: meeting.id).isEmpty)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["JOTTIE_CLEANUP_UI_FIXTURE"] != nil))
func exportSyntheticCleanupReviewFixture() async throws {
    let path = try #require(ProcessInfo.processInfo.environment["JOTTIE_CLEANUP_UI_FIXTURE"])
    guard path.hasPrefix("/tmp/jottie-cleanup-ui-") else { throw JottieError.invalid("Use an isolated temporary fixture directory.") }
    let root = URL(fileURLWithPath: path), store = try LibraryStore(root: root)
    var meeting = cleanupFixture()
    meeting.sourceID = "synthetic-cleanup-ui"; meeting.title = "Synthetic transcript cleanup review"
    try await store.save(meeting)
    try await store.saveCleanupDraft(cleanupRevision(meeting), meetingID: meeting.id)
    let settings = LibrarySettings()
    _ = try await store.saveSettings(settings)
}

@Test func mcpExposesBothReviewedTextAndPaginatedOriginalEvidence() async throws {
    let root = try cleanupRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = try LibraryStore(root: root), meeting = cleanupFixture()
    try await store.save(meeting)
    let revision = cleanupRevision(meeting)
    try await store.saveCleanupDraft(revision, meetingID: meeting.id)
    try await store.applyCleanup(meetingID: meeting.id, draftID: revision.id, changeIDs: ["echo", "local"], speakerIDs: [])
    let server = try JottieServer(root: root)
    let current = try await server.call(name: "get_transcript", arguments: ["meetingID": .string(meeting.id.uuidString)])
    let original = try await server.call(name: "get_transcript", arguments: ["meetingID": .string(meeting.id.uuidString), "view": .string("original"), "cursor": .string("2"), "limit": .int(1)])
    let object = try #require(try JSONSerialization.jsonObject(with: Data(original.utf8)) as? [String: Any])
    #expect(object["revision"] as? String == meeting.transcriptRevision)
    #expect(original.contains("lunch") && !current.contains("lunch"))
    #expect(current.contains(revision.id) && original.contains("local"))
    #expect(try await store.meeting(meeting.id).markdown.contains("Original revision: \(meeting.transcriptRevision)"))
    await #expect(throws: (any Error).self) { _ = try await server.call(name: "get_transcript", arguments: ["meetingID": .string(meeting.id.uuidString), "view": .string("invented")]) }
}

@Test func cleanupHonoursAnExistingCrossProcessLeaseAndCancellationDoesNotQueueAnUpload() async throws {
    let root = try cleanupRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = try LibraryStore(root: root), meeting = cleanupFixture()
    try await store.save(meeting)
    let coordinator = try KnowledgeCoordinator(store: store), ledger = try WorkLedger(root: root)
    let key = "cleanup:\(meeting.id):\(meeting.transcriptRevision)"
    #expect(try await ledger.begin(key, stage: "Transcript cleanup preview"))
    let runner = CleanupRunner()
    await #expect(throws: (any Error).self) { try await coordinator.prepareTranscriptCleanup(meeting.id, runner: runner) }
    #expect(await runner.prompts.isEmpty)
    try await ledger.finish(key)
    await #expect(throws: CancellationError.self) { try await coordinator.prepareTranscriptCleanup(meeting.id, runner: CancelledCleanupRunner()) }
    #expect(try await ledger.statuses().isEmpty)
    try await coordinator.prepareTranscriptCleanup(meeting.id, runner: runner)
    #expect(await runner.prompts.count == 1)
    #expect(try await ledger.statuses().isEmpty)
}

@Test func publicationExcludesCleanupDraftsRemovedSourceTextAndDeviceNotes() async throws {
    let root = try cleanupRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = try LibraryStore(root: root)
    var meeting = cleanupFixture(); meeting.recordingContext?.userNote = "Local device note only"
    try await store.save(meeting)
    let revision = cleanupRevision(meeting)
    try await store.saveCleanupDraft(revision, meetingID: meeting.id)
    let draft = try await store.meeting(meeting.id)
    let withoutDraft = try GraphPublisher.publicationMetadata(meeting)
    #expect(try GraphPublisher.publicationMetadata(draft) == withoutDraft)
    try await store.applyCleanup(meetingID: meeting.id, draftID: revision.id, changeIDs: ["echo", "local"], speakerIDs: [])
    let cleaned = try await store.meeting(meeting.id)
    let metadata = String(decoding: try GraphPublisher.publicationMetadata(cleaned), as: UTF8.self)
    #expect(!metadata.contains("lunch") && !metadata.contains("Test speakers") && !metadata.contains("Local device note only"))
    #expect(!metadata.contains("speakerSuggestions") && !metadata.contains("cleanupOriginalSegments"))
    #expect(metadata.contains("cleanupProvenance") && metadata.contains(meeting.transcriptRevision))
    #expect(metadata.contains("launch plan on Friday"))
}
