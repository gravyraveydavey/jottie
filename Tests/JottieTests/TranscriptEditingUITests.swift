import AppKit
import Foundation
import Testing
import JottieModels
import JottieLibrary
import JottieKnowledge
@testable import JottieUI

/// Opt-in interactive fixture. Uses invented meetings and a local directory only.
@Test(.enabled(if: ProcessInfo.processInfo.environment["JOTTIE_EDITING_QA"] == "1"))
@MainActor func interactiveTranscriptEditingFixture() async throws {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("jottie-editing-ui-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LibraryStore(root: root)
    var meeting = Meeting(sourceID: "synthetic-ui-editor", title: "Synthetic transcript editing check", segments: [
        Segment(id: "a", speaker: "them 1", startMS: 1000, endMS: 3000, text: "The lunch is ready for review."),
        Segment(id: "b", speaker: "them 1", startMS: 4000, endMS: 6000, text: "Please send feedback by Friday.")
    ], participants: ["Alex Example <alex@example.test>", "Guest Visitor <guest@example.test>"])
    meeting.calendarContext = CalendarEventContext(id: "event", calendarID: "calendar", calendarTitle: "Synthetic calendar",
        title: "Planning", start: Date(), end: Date(), invitees: meeting.participants)
    try await store.save(meeting)
    var settings = LibrarySettings(); settings.bambooEnabled = true; settings.bambooCompany = "synthetic"
    try await store.saveSettings(settings)
    let directory = try PeopleDirectory(root: root)
    try await directory.replace([DirectoryPerson(id: "alex", name: "Alex Example", workEmail: "alex@example.test", jobTitle: "Writer"),
        DirectoryPerson(id: "fi", name: "Fiona Gray", workEmail: "fi@example.test", jobTitle: "Designer", aliases: ["Fifi"])], company: "synthetic")
    try await directory.setAliases(["Fifi"], employeeID: "fi", company: "synthetic")
    let model = LibraryViewModel(store: store, coordinator: try KnowledgeCoordinator(store: store),
        account: MicrosoftAccount(), publisher: try GraphPublisher(tokens: MicrosoftAccount(), root: root))
    await model.reload(); model.selection = [meeting.id]
    let window = LibraryWindow(model: model)
    defer { window.closePreview() }
    window.show(); app.activate(ignoringOtherApps: true)
    // Pump AppKit events between suspension points so Swift Testing can also
    // dispatch the SwiftUI .task loads and asynchronous Save actions.
    app.finishLaunching()
    for tick in 0..<(240 * 60) {
        while let event = app.nextEvent(matching: .any, until: .distantPast, inMode: .default, dequeue: true) {
            app.sendEvent(event)
        }
        app.updateWindows()
        try await Task.sleep(for: .milliseconds(16))
        guard tick.isMultiple(of: 60) else { continue }
        let saved = try await store.meeting(meeting.id)
        if saved.segments[0].text == "The launch is ready for review.", saved.speakerAttributions?["a"]?.employeeID == "fi" {
            #expect(saved.speakerName(for: saved.segments[1]) == "Fiona Gray")
            #expect(saved.originalTranscript == meeting.segments)
            return
        }
    }
    Issue.record("Interactive editor check did not save the expected synthetic corrections.")
}
