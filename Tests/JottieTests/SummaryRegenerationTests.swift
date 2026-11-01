import Foundation
import AppKit
import Testing
import JottieModels
import JottieLibrary
import JottieKnowledge
@testable import JottieUI

private actor PausedSummaryAnalyzer: MeetingAnalyzer {
    private var started = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var completion: CheckedContinuation<Void, Never>?
    private var shouldFail = false
    var meetingIDs: [UUID] = []
    var prompts: [String] = []

    func analyze(_ meeting: Meeting, prompt: String, folders: [Folder]) async throws -> Analysis {
        meetingIDs.append(meeting.id); prompts.append(prompt)
        await withCheckedContinuation { continuation in
            completion = continuation; started = true
            startWaiter?.resume(); startWaiter = nil
        }
        if shouldFail { throw JottieError.unavailable("Synthetic summary failure") }
        return Analysis(title: "Updated plan", summary: "The plan was approved.",
            summaryEvidence: [Evidence(segmentID: "s1", quote: "The plan was approved.")])
    }
    func waitUntilStarted() async {
        if !started { await withCheckedContinuation { startWaiter = $0 } }
    }
    func finish(failing: Bool = false) {
        shouldFail = failing; started = false
        completion?.resume(); completion = nil
    }
}

private func summaryFixture() async throws -> (LibraryStore, Meeting, Meeting, LibrarySettings) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("jottie-summary-\(UUID())")
    let store = try LibraryStore(root: root)
    var settings = LibrarySettings(); settings.analysisEnabled = true
    settings.summaryPrompt += "\nUse the updated synthetic format."
    try await store.saveSettings(settings)
    var values: [Meeting] = []
    for index in 0..<2 {
        let meeting = Meeting(sourceID: "synthetic-summary-\(index)", title: "Plan \(index)",
            segments: [Segment(id: "s1", speaker: "voice", text: "The plan was approved.")])
        try await store.save(meeting)
        try await store.apply(AnalysisRevision(transcriptRevision: meeting.transcriptRevision, promptRevision: "earlier-prompt",
            analysis: Analysis(title: meeting.title, summary: "Previous summary",
                summaryEvidence: [Evidence(segmentID: "s1", quote: "The plan was approved.")])), to: meeting.id)
        values.append(try await store.meeting(meeting.id))
    }
    return (store, values[0], values[1], settings)
}

@Test func summaryRegenerationIsVisibleInQueueAndOnlyReplacesTheRequestedMeeting() async throws {
    let (store, meeting, other, settings) = try await summaryFixture()
    defer { try? FileManager.default.removeItem(at: store.root) }
    let analyzer = PausedSummaryAnalyzer()
    let coordinator = try KnowledgeCoordinator(store: store, analyzer: analyzer)
    let task = Task { try await coordinator.regenerate(meeting.id) }
    await analyzer.waitUntilStarted()
    let jobs = try await coordinator.ledger.statuses()
    #expect(jobs.count == 1)
    #expect(jobs.first?.id.hasPrefix("analysis:\(meeting.id):") == true)
    #expect(jobs.first?.state == "running")
    #expect(try await coordinator.processingProgress() == ProcessingProgress(completed: 0, total: 1))
    #expect(try await store.meeting(meeting.id).analysis == meeting.analysis)
    await analyzer.finish()
    try await task.value
    #expect(await analyzer.meetingIDs == [meeting.id])
    #expect(await analyzer.prompts == [settings.summaryPrompt])
    #expect(try await store.meeting(meeting.id).analysis?.promptRevision == settings.analysisRevision)
    #expect(try await store.meeting(other.id).analysis == other.analysis)
    #expect(try await coordinator.ledger.statuses().isEmpty)
    #expect(try await coordinator.processingProgress() == ProcessingProgress(completed: 1, total: 1))
}

@Test func failedSummaryRegenerationKeepsPreviousSummaryAndCanBeRetriedFromQueue() async throws {
    let (store, meeting, other, settings) = try await summaryFixture()
    defer { try? FileManager.default.removeItem(at: store.root) }
    let analyzer = PausedSummaryAnalyzer()
    let coordinator = try KnowledgeCoordinator(store: store, analyzer: analyzer)
    let task = Task { try await coordinator.regenerate(meeting.id) }
    await analyzer.waitUntilStarted(); await analyzer.finish(failing: true)
    await #expect(throws: JottieError.self) { try await task.value }
    #expect(try await store.meeting(meeting.id).analysis == meeting.analysis)
    let jobs = try await coordinator.ledger.statuses()
    #expect(jobs.first?.state == "deferred")
    // Avoid waiting on an analyzer that was never scheduled if queue registration fails.
    guard let job = jobs.first else { return }
    try await coordinator.ledger.retry(job.id)
    let retry = Task { await coordinator.run(updateNow: true) }
    await analyzer.waitUntilStarted(); await analyzer.finish()
    await retry.value
    #expect(await analyzer.meetingIDs == [meeting.id, meeting.id])
    #expect(try await store.meeting(meeting.id).analysis?.promptRevision == settings.analysisRevision)
    #expect(try await store.meeting(other.id).analysis == other.analysis)
    #expect(try await coordinator.ledger.statuses().isEmpty)
}

@Test @MainActor func summaryPresentationTracksOnlyTheActiveMeetingAndRefreshesImmediately() async throws {
    let (store, meeting, other, _) = try await summaryFixture()
    defer { try? FileManager.default.removeItem(at: store.root) }
    let analyzer = PausedSummaryAnalyzer()
    let coordinator = try KnowledgeCoordinator(store: store, analyzer: analyzer)
    let model = LibraryViewModel(store: store, coordinator: coordinator, account: MicrosoftAccount(),
        publisher: try GraphPublisher(tokens: MicrosoftAccount(), root: store.root))
    await model.reload(); model.select(meeting.id)
    // Other operations must not make every meeting claim its summary is processing.
    model.working = true
    #expect(model.summaryStatus(for: meeting) == "Earlier prompt · update available")
    #expect(model.processingStatus(for: other) == nil)
    model.working = false
    let task = Task { await model.regenerate(meeting) }
    await analyzer.waitUntilStarted()
    #expect(model.working && !model.updatingAllSummaries)
    #expect(model.isSummarizing(meeting))
    #expect(!model.isSummarizing(other))
    #expect(model.processingStatus(for: meeting) == "Updating summary…")
    #expect(model.summaryStatus(for: meeting).contains("previous summary remains available"))
    #expect(model.summaryStatus(for: other) == "Earlier prompt · update available")
    #expect(model.jobs.count == 1 && model.jobs.first?.state == "running")
    #expect(model.selectedMeeting?.analysis == meeting.analysis)
    if ProcessInfo.processInfo.environment["JOTTIE_RENDER_SUMMARY"] == "1" {
        _ = NSApplication.shared
        model.appearance = "light"
        let window = LibraryWindow(model: model)
        window.show()
        try await Task.sleep(for: .milliseconds(300))
        let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/qa")
        try LibraryStore.directory(output)
        try window.renderedPreview().write(to: output.appendingPathComponent("summary-regenerating.png"))
        model.navigate("queue"); await model.search()
        try await Task.sleep(for: .milliseconds(100))
        try window.renderedPreview().write(to: output.appendingPathComponent("summary-queue.png"))
        window.closePreview()
        model.navigate("all"); model.select(meeting.id); await model.search()
    }
    await analyzer.finish(); await task.value
    let updated = try #require(model.selectedMeeting)
    #expect(model.summaryStatus(for: updated).hasPrefix("Summary up to date"))
    #expect(model.jobs.isEmpty && !model.working && !model.isSummarizing(updated))
    #expect(model.outdatedMeetings.map(\.id) == [other.id])
    // A second explicit regeneration with the same saved prompt must reuse the completed job.
    let repeated = Task { await model.regenerate(updated) }
    await analyzer.waitUntilStarted()
    #expect(model.jobs.count == 1 && model.jobs.first?.state == "running")
    await analyzer.finish(); await repeated.value
    #expect(await analyzer.meetingIDs == [meeting.id, meeting.id])
}
