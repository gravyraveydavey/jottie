import AppKit
import Foundation
import Testing
import JottieModels
import JottieLibrary
import JottieKnowledge
@testable import JottieUI

@Test(.enabled(if: ProcessInfo.processInfo.environment["JOTTIE_RENDER_PREVIEW"] == "1"))
@MainActor func syntheticLibraryPreview() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("jottie-preview-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LibraryStore(root: root)
    let client = Folder(name: "Acme"), project = Folder(name: "Launch", parentID: client.id)
    try await store.saveFolder(client); try await store.saveFolder(project)
    let meeting = Meeting(sourceID: "synthetic-preview", title: "Launch planning",
        segments: [Segment(id: "s1", speaker: "me", text: "We approved the launch plan. Alex will prepare the briefing."),
                   Segment(id: "s2", speaker: "them", text: "We still need to confirm the launch date.")])
    try await store.save(meeting)
    let evidence = [Evidence(segmentID: "s1", quote: "We approved the launch plan.")]
    let analysis = Analysis(title: "Launch plan approved", summary: "The launch plan is approved. Alex will prepare the briefing while the team confirms the launch date.",
        summaryEvidence: evidence, topics: ["Launch preparation", "Date confirmation"], tags: ["launch", "planning"], primaryTag: "Launch",
        decisions: [Finding(text: "Proceed with the launch plan", status: "confirmed", evidence: evidence)],
        actions: [Finding(text: "Prepare the briefing", status: "committed", owner: "Alex",
                         evidence: [Evidence(segmentID: "s1", quote: "Alex will prepare the briefing.")])],
        questions: [Finding(text: "What is the launch date?", status: "open",
                           evidence: [Evidence(segmentID: "s2", quote: "confirm the launch date")])])
    try await store.apply(AnalysisRevision(transcriptRevision: meeting.transcriptRevision, promptRevision: "preview", analysis: analysis), to: meeting.id)
    let account = MicrosoftAccount(), publisher = try GraphPublisher(tokens: MicrosoftAccount(), root: root)
    let coordinator = try KnowledgeCoordinator(store: store)
    let model = LibraryViewModel(store: store, coordinator: coordinator, account: account, publisher: publisher)
    await model.reload()
    model.selection = [meeting.id]
    let window = LibraryWindow(model: model)
    defer { window.closePreview() }
    let image = try window.renderedPreview()
    #expect(image.count > 10_000)
    let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(".build/qa")
    try LibraryStore.directory(output)
    try image.write(to: output.appendingPathComponent("jottie-library.png"))
}
