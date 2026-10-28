import AppKit
import Foundation
import Testing
import JottieModels
import JottieLibrary
import JottieKnowledge
@testable import JottieUI

@Test @MainActor func managerImportsMultipleMediaFilesAndOpensQueue() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("jottie-media-ui-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LibraryStore(root: root)
    let model = LibraryViewModel(store: store, coordinator: try KnowledgeCoordinator(store: store),
        account: MicrosoftAccount(), publisher: try GraphPublisher(tokens: MicrosoftAccount(), root: root))
    let sources = [URL(fileURLWithPath: "/tmp/interview.mp4"), URL(fileURLWithPath: "/tmp/discussion.wav"), URL(fileURLWithPath: "/tmp/meeting.m4a")]
    var received: [URL] = []
    model.onImportMedia = { received = $0 }
    model.importURLs(sources)
    #expect(received == sources)
    #expect(model.location == "queue")
    #expect(model.message == nil)
    model.onImportMedia = nil
    model.importURLs([sources[0]])
    #expect(model.message?.contains("full Jottie app") == true)
}

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

@Test @MainActor func managerReusesItsWindowAfterCloseAndReopen() throws {
    let app = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LibraryStore(root: root)
    let model = LibraryViewModel(store: store, coordinator: try KnowledgeCoordinator(store: store),
        account: MicrosoftAccount(), publisher: try GraphPublisher(tokens: MicrosoftAccount(), root: root))
    let previous = Set(app.windows.map(ObjectIdentifier.init))
    let manager = LibraryWindow(model: model)
    defer { manager.closePreview() }
    manager.show()
    let created = app.windows.filter { !previous.contains(ObjectIdentifier($0)) && $0.title == "Jottie" }
    #expect(created.count == 1)
    manager.closePreview()
    manager.show(); manager.show()
    let reopened = app.windows.filter { !previous.contains(ObjectIdentifier($0)) && $0.title == "Jottie" }
    #expect(reopened.count == 1)
    #expect(reopened.first === created.first)
    #expect(reopened.first?.isVisible == true)
}
