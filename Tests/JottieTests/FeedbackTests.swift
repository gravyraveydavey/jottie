import AppKit
import Foundation
import Testing
import JottieModels
import JottieLibrary
import JottieKnowledge

private func feedbackDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("jottie-feedback-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    return root
}
private actor FeedbackRunner: StructuredRunner {
    var prompts: [String] = []
    var outputs: [Data]
    init(_ outputs: [Data]) { self.outputs = outputs }
    func run(prompt: String, schema: Data) throws -> Data {
        prompts.append(prompt)
        guard !outputs.isEmpty else { throw JottieError.invalid("Unexpected extra analysis call") }
        return outputs.removeFirst()
    }
}

@Test func modelEffortAndBothPromptsMigrateAndRoundTrip() async throws {
    let root = try feedbackDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try Data(#"{"schemaVersion":1,"summaryPrompt":"Keep this format","analysisEnabled":true,"codexPath":"/chosen/codex"}"#.utf8).write(to: root.appendingPathComponent("settings.json"))
    let store = try LibraryStore(root: root)
    var settings = try await store.settings()
    #expect(settings.summaryPrompt == "Keep this format")
    #expect(settings.analysisEnabled)
    #expect(settings.folderContextPrompt == Prompts.folderContext)
    #expect(settings.codexModel.isEmpty && settings.codexEffort.isEmpty)
    let oldRevision = settings.analysisRevision, oldContext = settings.contextRevision
    settings.codexModel = "test-model"; settings.codexEffort = "high"
    settings.folderContextPrompt = "Lead with objectives, then risks."
    try await store.saveSettings(settings)
    #expect(try await LibraryStore(root: root).settings() == settings)
    #expect(settings.analysisRevision != oldRevision)
    #expect(settings.contextRevision != oldContext)
    let args = CodexRunner.arguments(schema: root.appendingPathComponent("schema"), output: root.appendingPathComponent("answer"), model: settings.codexModel, effort: settings.codexEffort)
    #expect(args.contains("--model"))
    #expect(args.contains("test-model"))
    #expect(args.contains("model_reasoning_effort=\"high\""))
    #expect(args.contains("forced_login_method=\"chatgpt\""))
}

@Test func modelPickerUsesTheChosenCLICatalogAndSupportedEfforts() async throws {
    let root = try feedbackDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = root.appendingPathComponent("codex")
    let script = """
    #!/bin/sh
    [ "$1" = '--no-daemon' ] && [ "$2" = 'debug' ] && [ "$3" = 'models' ] && [ "$4" = '--bundled' ] || exit 9
    /bin/cat <<'CATALOG'
    {"models":[{"slug":"test-model","display_name":"Test model","visibility":"list","supported_reasoning_levels":[{"effort":"low"},{"effort":"high"},{"effort":"unsupported"}]},{"slug":"hidden-model","visibility":"hide"}]}
    CATALOG
    """
    try Data(script.utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let models = await CodexInstallation.models(path: executable.path)
    #expect(models.map(\.id) == ["test-model"])
    #expect(models[0].name == "Test model")
    #expect(models[0].efforts == ["low", "high"])
}

@Test func folderContextHasOnlySummaryEvidenceAndRebuildsForPromptChanges() async throws {
    var meeting = Meeting(sourceID: "synthetic-context", title: "Plan", segments: [
        Segment(id: "s1", speaker: "me", text: "The launch plan was approved. EVIDENCE_ONLY_9944"),
        Segment(id: "private", speaker: "them", text: "RAW_TRANSCRIPT_ONLY_7813")])
    meeting.analysis = AnalysisRevision(transcriptRevision: meeting.transcriptRevision, promptRevision: "test",
        analysis: Analysis(title: "Plan approved", summary: "The launch plan was approved.",
                           summaryEvidence: [Evidence(segmentID: "s1", quote: "The launch plan was approved. EVIDENCE_ONLY_9944")]))
    let summary = MeetingSummary(meeting)!, folder = Folder(name: "Plans")
    func response(_ overview: String, segment: String = "s1") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["overview": overview, "decisions": [], "actions": [], "questions": [], "recentChanges": [],
            "sources": [["meetingID": meeting.id.uuidString, "revision": summary.analysis.id, "segmentID": segment]]])
    }
    let runner = FeedbackRunner([try response("OLD_CONTEXT_FORMAT"), try response("New overview")])
    let first = try await CodexFolderContext(runner: runner).update(folder: folder, summaries: [summary], previous: nil)
    _ = try await CodexFolderContext(runner: runner, prompt: "NEW_FOLDER_FORMAT").update(folder: folder, summaries: [summary], previous: first)
    let prompts = await runner.prompts
    #expect(prompts.count == 2)
    #expect(prompts.allSatisfy { !$0.contains("RAW_TRANSCRIPT_ONLY_7813") })
    #expect(prompts.allSatisfy { !$0.contains("EVIDENCE_ONLY_9944") })
    #expect(prompts[1].contains("NEW_FOLDER_FORMAT"))
    #expect(!prompts[1].contains("OLD_CONTEXT_FORMAT"))
    var settings = LibrarySettings()
    let original = LibraryStore.contextFingerprint(folder: folder, folders: [folder], meetings: [meeting], settings: settings)
    settings.folderContextPrompt = "New format"
    #expect(LibraryStore.contextFingerprint(folder: folder, folders: [folder], meetings: [meeting], settings: settings) != original)
    let unsupported = FeedbackRunner([try response("Unsupported", segment: "private")])
    do {
        _ = try await CodexFolderContext(runner: unsupported).update(folder: folder, summaries: [summary], previous: nil)
        Issue.record("Context should reject a transcript segment absent from summary evidence")
    } catch { #expect(error is JottieError) }
}

@Test func tagsReuseCatalogAndStayWithinTenIncludingPrimary() async throws {
    let meeting = Meeting(sourceID: "synthetic-tags", title: "Plan", segments: [Segment(id: "s1", speaker: "me", text: "The plan was approved.")])
    let raw = Analysis(title: "Approved", summary: "The plan was approved.", summaryEvidence: [Evidence(segmentID: "s1", quote: "The plan was approved.")],
        tags: ["PROJECT delivery", "cafe", "Cafe"] + (1...14).map { "Tag \($0)" }, primaryTag: "project_delivery")
    let runner = FeedbackRunner([try Codec.encode(raw)])
    let result = try await CodexAnalyzer(runner: runner, existingTags: ["Project delivery", "Café"]).analyze(meeting, prompt: Prompts.summary, folders: [])
    #expect(result.tags.count == 10)
    #expect(result.primaryTag == "Project delivery")
    #expect(result.tags.first == "Project delivery")
    #expect(result.tags.contains("Café"))
    #expect(Set(result.tags.map(MeetingTags.key)).count == 10)
    #expect(await runner.prompts.first?.contains("Existing tag catalog") == true)
    #expect(await runner.prompts.first?.contains("Project delivery") == true)
}

@Test func existingOverlimitTagsReceiveALocalRevisionWithoutLosingHistory() async throws {
    let root = try feedbackDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LibraryStore(root: root)
    var meeting = Meeting(sourceID: "synthetic-old-tags", title: "Plan", segments: [Segment(id: "s1", speaker: "me", text: "The plan was approved.")])
    try await store.save(meeting)
    let original = AnalysisRevision(transcriptRevision: meeting.transcriptRevision, promptRevision: "old-prompt",
        analysis: Analysis(title: "Approved", summary: "The plan was approved.", summaryEvidence: [Evidence(segmentID: "s1", quote: "The plan was approved.")],
            tags: (1...14).map { "Tag \($0)" }, primaryTag: "Tag 14"))
    meeting.analysis = original
    let directory = store.meetingDirectory(meeting.id)
    try FileManager.default.createDirectory(at: directory.appendingPathComponent("Analysis"), withIntermediateDirectories: true)
    let history = directory.appendingPathComponent("Analysis/\(original.id).json")
    let originalBytes = try Codec.encode(original)
    try originalBytes.write(to: history)
    try Codec.encode(meeting).write(to: directory.appendingPathComponent("meeting.json"))
    try await store.reconcile()
    let updated = try await store.meeting(meeting.id)
    #expect(updated.analysis?.analysis.tags.count == 10)
    #expect(updated.analysis?.analysis.tags.contains("Tag 14") == true)
    #expect(updated.analysis?.id != original.id)
    #expect(try Data(contentsOf: history) == originalBytes)
}

@Test @MainActor func recursiveTranscriptImportReadsTextAndWordWithoutAudioOrDuplicateCopies() async throws {
    let root = try feedbackDirectory(), library = try feedbackDirectory()
    defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: library) }
    let nested = root.appendingPathComponent("nested")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
    let markdown = root.appendingPathComponent("Planning.md"), text = nested.appendingPathComponent("Notes.txt")
    try Data("# Planning\n\nA full Markdown transcript.\n".utf8).write(to: markdown)
    try Data("Accented text: café and 日本語.\n".utf8).write(to: text)
    try "A UTF-16 transcript.".data(using: .utf16)!.write(to: nested.appendingPathComponent("Unicode.txt"))
    for (extensionName, type) in [("doc", NSAttributedString.DocumentType.docFormat), ("docx", .officeOpenXML)] {
        let contents = NSAttributedString(string: "Word \(extensionName) transcript, with an agreed next step.")
        let data = try contents.data(from: NSRange(location: 0, length: contents.length), documentAttributes: [.documentType: type])
        try data.write(to: nested.appendingPathComponent("Meeting.\(extensionName)"))
    }
    try Data("audio should not be copied".utf8).write(to: root.appendingPathComponent("recording.wav"))
    try Data("not a Word document".utf8).write(to: nested.appendingPathComponent("Broken.docx"))
    try FileManager.default.copyItem(at: markdown, to: nested.appendingPathComponent("Duplicate.md"))
    let originals = try Data(contentsOf: markdown)
    let store = try LibraryStore(root: library)
    let report = try await store.importTranscripts(from: [root, nested])
    #expect(report.imported == 5)
    #expect(report.unchanged == 1)
    #expect(report.failures.count == 1)
    var meetings = try await store.meetings()
    #expect(meetings.count == 5)
    #expect(meetings.contains { $0.segments[0].text.contains("Word docx transcript") })
    #expect(meetings.contains { $0.segments[0].text.contains("café and 日本語") })
    #expect(try Data(contentsOf: markdown) == originals)
    let again = try await store.importTranscripts(from: [root])
    #expect(again.imported == 0)
    #expect(again.unchanged == 6)
    let folder = Folder(name: "Project")
    try await store.saveFolder(folder)
    let selected = meetings.first { $0.segments[0].text.contains("Accented text") }!
    try await store.file([selected.id], into: folder.id)
    try Data("Updated complete transcript.".utf8).write(to: text)
    _ = try await store.importTranscripts(from: [text])
    let updated = try await store.meeting(selected.id)
    #expect(updated.segments[0].text == "Updated complete transcript.")
    #expect(updated.folderID == folder.id && updated.manuallyFiled)
    meetings = try await store.meetings()
    #expect(meetings.count == 5)
    let files = FileManager.default.enumerator(at: library, includingPropertiesForKeys: nil)!.allObjects as! [URL]
    #expect(!files.contains { ["wav", "doc", "docx"].contains($0.pathExtension) })
}

@Test func legacyMeetingFoldersDoNotAlsoImportTheirMarkdownProjections() async throws {
    let root = try feedbackDirectory(), library = try feedbackDirectory()
    defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: library) }
    try Data(#"{"segments":[{"speaker":"me","start_ms":0,"end_ms":1000,"text":"Legacy complete transcript."}]}"#.utf8).write(to: root.appendingPathComponent("transcript.json"))
    try Data(#"{"started":"2026-10-26T12:00:00Z","title":"Legacy"}"#.utf8).write(to: root.appendingPathComponent("meta.json"))
    try Data("Legacy summary".utf8).write(to: root.appendingPathComponent("summary.md"))
    try Data("Legacy complete transcript.".utf8).write(to: root.appendingPathComponent("transcript.md"))
    let store = try LibraryStore(root: library)
    #expect(try await store.importTranscripts(from: [root]).imported == 1)
    let meetings = try await store.meetings()
    #expect(meetings.count == 1)
    #expect(meetings[0].importedSummary == "Legacy summary")
}

@Test func batchProgressExcludesHistoricalJobsAndCountsSuccessfulCompletions() async throws {
    let root = try feedbackDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let ledger = try WorkLedger(root: root)
    _ = try await ledger.begin("old", stage: "Old work"); try await ledger.finish("old")
    _ = try await ledger.begin("one", stage: "Meeting analysis"); try await ledger.finish("one")
    _ = try await ledger.begin("two", stage: "Meeting analysis"); try await ledger.fail("two", message: "Offline")
    let progress = try await ledger.progress(ids: ["one", "two"])
    #expect(progress.label == "Processing 1 of 2 items (50%)")
    try await ledger.retry("two"); _ = try await ledger.begin("two", stage: "Meeting analysis"); try await ledger.finish("two")
    #expect(try await ledger.progress(ids: ["one", "two"]).percent == 100)
    #expect(ProcessingProgress().label == "Processing 0 of 0 items (0%)")
    _ = try await ledger.begin("analysis:old-prompt", stage: "Meeting analysis")
    try await ledger.fail("analysis:old-prompt", message: "Old preferences")
    try await ledger.supersede(prefix: "analysis:", keeping: [])
    #expect(try await !ledger.statuses().contains(where: { $0.id == "analysis:old-prompt" }))
}
