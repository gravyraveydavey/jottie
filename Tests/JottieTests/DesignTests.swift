import AppKit
import Foundation
import Testing
import JottieModels
import JottieLibrary
import JottieKnowledge
@testable import JottieUI

@Test func starredSearchPaginatesSortsAndSurvivesRebuild() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LibraryStore(root: root)
    let folder = Folder(name: "Design")
    try await store.saveFolder(folder)
    var values: [Meeting] = []
    for index in 0..<105 {
        var meeting = Meeting(sourceID: "design-\(index)", title: "Design session \(index)", startedAt: Date(timeIntervalSince1970: Double(index * 3600)), segments: [Segment(id: "s1", speaker: "voice", text: "A native library for design conversations.")])
        meeting.folderID = folder.id
        try await store.save(meeting); values.append(meeting)
    }
    try await store.setStarred(true, meetingID: values[0].id)
    try await store.setStarred(true, meetingID: values[104].id)
    var query = SearchQuery(); query.starredOnly = true; query.text = "design"; query.folderID = folder.id; query.limit = 1
    #expect(try await store.search(query).map(\.id) == [values[104].id])
    query.offset = 1
    #expect(try await store.search(query).map(\.id) == [values[0].id])
    query.offset = 0; query.oldestFirst = true
    #expect(try await store.search(query).map(\.id) == [values[0].id])
    try await store.rebuildIndex()
    let reopened = try LibraryStore(root: root)
    #expect(try await reopened.search(query).map(\.id) == [values[0].id])
    try await reopened.setStarred(false, meetingID: values[0].id)
    #expect(try await reopened.search(query).map(\.id) == [values[104].id])
}

@Test func speakerDetailsPreserveTranscriptAndRejectUnknownChannels() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LibraryStore(root: root)
    let original = Meeting(sourceID: "speakers", title: "Names", segments: [Segment(id: "s1", speaker: "remote", text: "We approved the design.")])
    try await store.save(original)
    try await store.setSpeakers(names: ["remote": "  Jamie Chen  "], roles: ["remote": "Designer"], meetingID: original.id)
    let saved = try await LibraryStore(root: root).meeting(original.id)
    #expect(saved.speakerNames["remote"] == "Jamie Chen")
    #expect(saved.speakerRoles?["remote"] == "Designer")
    #expect(saved.transcript.contains("Jamie Chen"))
    #expect(saved.segments == original.segments && saved.transcriptRevision == original.transcriptRevision)
    await #expect(throws: JottieError.self) { try await store.setSpeakers(names: ["unknown": "Name"], roles: [:], meetingID: original.id) }
    try await store.setSpeakers(names: ["remote": " "], roles: [:], meetingID: original.id)
    #expect(try await store.meeting(original.id).transcript.contains("Speaker 1:"))
    let oldData = try Codec.encode(original)
    let oldMeeting = try Codec.decode(Meeting.self, from: oldData)
    #expect(oldMeeting.starred == nil && oldMeeting.speakerRoles == nil)
}

@Test @MainActor func nativeLibrarySelectionAndFonts() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LibraryStore(root: root)
    for index in 0..<3 { try await store.save(Meeting(sourceID: "selection-\(index)", title: "Meeting", startedAt: Date(timeIntervalSince1970: Double(index)), segments: [Segment(id: "s1", speaker: "voice", text: "Design discussion.")])) }
    let model = LibraryViewModel(store: store, coordinator: try KnowledgeCoordinator(store: store), account: MicrosoftAccount(), publisher: try GraphPublisher(tokens: MicrosoftAccount(), root: root))
    await model.reload()
    model.selection = []; model.focusedMeetingID = nil
    model.selectAdjacent(1)
    #expect(model.selection == [model.hits[0].id])
    model.select(model.hits[2].id, range: true)
    #expect(model.selection.count == 3)
    #expect(model.selectedMeeting?.id == model.hits[2].id)
    model.select(model.hits[1].id, extending: true)
    #expect(model.selection.count == 2)
    model.navigate("starred"); await model.search()
    #expect(model.selection.isEmpty && model.hits.isEmpty && model.selectedMeeting == nil)
    model.navigate("all"); await model.search()
    model.query = "no-matching-meeting"; await model.search()
    #expect(model.selectedMeeting == nil)
    _ = JottieStyle.font(14, .semibold)
    #expect(NSFont(name: "Geist-Regular", size: 14) != nil)
    #expect(NSFont(name: "Geist-SemiBold", size: 14) != nil)
}

private struct PrototypeFixture: Decodable {
    struct FolderValue: Decodable { let id: String; let name: String; let children: [FolderValue]? }
    struct MeetingValue: Decodable {
        struct Action: Decodable { let task: String; let owner: String }
        struct Line: Decodable { let time: String; let speaker: String; let text: String }
        let id: String; let title: String; let date: String; let time: String; let duration: String
        let folder: String?; let tags: [String]; let participants: [String]; let summary: String
        let highlights: [String]; let decisions: [String]; let actions: [Action]; let transcript: [Line]; let starred: Bool?
    }
    let demoFolders: [FolderValue]
    let demoMeetings: [MeetingValue]
}

/// Opt-in, synthetic-only visual QA library; it never touches the user's library or providers.
@Test(.enabled(if: ProcessInfo.processInfo.environment["JOTTIE_DESIGN_LIBRARY"] != nil))
func exportNativeDesignFixture() async throws {
    let path = try #require(ProcessInfo.processInfo.environment["JOTTIE_DESIGN_LIBRARY"])
    let destination = URL(fileURLWithPath: path).standardizedFileURL
    guard destination.path.hasPrefix("/tmp/jottie-native-design-") || destination.path.hasPrefix("/private/tmp/jottie-native-design-") else {
        throw JottieError.invalid("Visual fixtures require an isolated jottie-native-design directory in /tmp.")
    }
    let store = try LibraryStore(root: destination)
    let url = try #require(Bundle.module.url(forResource: "design-library", withExtension: "json", subdirectory: "Fixtures"))
    let fixture = try JSONDecoder().decode(PrototypeFixture.self, from: Data(contentsOf: url))
    let existing = try await store.meetings()
    if !existing.isEmpty {
        guard Set(existing.map(\.sourceID)) == Set(fixture.demoMeetings.map { "synthetic-prototype-" + $0.id }), existing.count == fixture.demoMeetings.count else {
            throw JottieError.invalid("The preview directory contains unrelated records; choose a fresh temporary directory.")
        }
        return
    }
    var folders: [String: Folder] = [:]
    func folderTree(_ values: [PrototypeFixture.FolderValue], parent: UUID?) -> [Folder] {
        values.flatMap { value in
            let folder = Folder(name: value.name, parentID: parent)
            folders[value.id] = folder
            return [folder] + folderTree(value.children ?? [], parent: folder.id)
        }
    }
    for folder in folderTree(fixture.demoFolders, parent: nil) { try await store.saveFolder(folder) }
    let settings = LibrarySettings(); try await store.saveSettings(settings)
    let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_GB"); formatter.dateFormat = "d MMM yyyy HH:mm"
    for value in fixture.demoMeetings {
        let duration = (Int(value.duration.split(separator: " ").first ?? "0") ?? 0) * 60000
        let segments = value.transcript.enumerated().map { index, line in
            let parts = line.time.split(separator: ":").compactMap { Int($0) }
            let start = parts.count == 2 ? (parts[0] * 60 + parts[1]) * 1000 : 0
            return Segment(id: "s\(index + 1)", speaker: line.speaker, startMS: start, endMS: index == value.transcript.count - 1 ? duration : start + 10000, text: line.text)
        }
        var meeting = Meeting(sourceID: "synthetic-prototype-\(value.id)", title: value.title, startedAt: try #require(formatter.date(from: value.date + " " + value.time)), segments: segments, participants: value.participants)
        meeting.folderID = value.folder.flatMap { folders[$0]?.id }; meeting.manuallyFiled = true; meeting.starred = value.starred
        let first = try #require(segments.first)
        let evidence = [Evidence(segmentID: first.id, quote: first.text)]
        let analysis = Analysis(title: value.title, summary: value.summary, summaryEvidence: evidence, topics: value.highlights, tags: value.tags,
                                decisions: value.decisions.map { Finding(text: $0, status: "confirmed", evidence: evidence) },
                                actions: value.actions.map { Finding(text: $0.task, status: "committed", owner: $0.owner, evidence: evidence) })
        try await store.save(meeting)
        try await store.apply(AnalysisRevision(transcriptRevision: meeting.transcriptRevision, promptRevision: settings.analysisRevision, analysis: analysis), to: meeting.id)
    }
    let all = try await store.meetings(), tree = try await store.folders()
    for folder in tree {
        let subtree = LibraryStore.descendants(folder.id, in: tree)
        let members = all.filter { $0.folderID.map(subtree.contains) == true }
        let sources = members.compactMap { meeting -> ContextSource? in
            guard let revision = meeting.analysis, let evidence = revision.analysis.summaryEvidence.first else { return nil }
            return ContextSource(meetingID: meeting.id, revision: revision.id, segmentID: evidence.segmentID)
        }
        let context = FolderContext(folderID: folder.id, inputRevision: LibraryStore.contextFingerprint(folder: folder, folders: tree, meetings: all, settings: settings),
            overview: "Jottie is a local meeting companion that helps you return to the useful parts of a conversation. This folder brings together product direction, interface exploration and research for the meeting workspace.", sources: sources)
        try await store.saveContext(context)
    }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["JOTTIE_RENDER_DESIGN"] == "1"))
@MainActor func renderNativeDesignFixture() async throws {
    let path = try #require(ProcessInfo.processInfo.environment["JOTTIE_DESIGN_LIBRARY"])
    let store = try LibraryStore(root: URL(fileURLWithPath: path))
    let meetings = try await store.meetings()
    #expect(meetings.count == 8)
    #expect(meetings.allSatisfy { $0.sourceID.hasPrefix("synthetic-prototype-") })
    guard meetings.count == 8 && meetings.allSatisfy({ $0.sourceID.hasPrefix("synthetic-prototype-") }) else { return }
    _ = NSApplication.shared
    let model = LibraryViewModel(store: store, coordinator: try KnowledgeCoordinator(store: store), account: MicrosoftAccount(), publisher: try GraphPublisher(tokens: MicrosoftAccount(), root: store.root))
    await model.reload()
    model.appearance = "light" // Temporary libraries never persist user presentation preferences.
    let selected = try #require(meetings.first { $0.title == "Design review: small details, less friction" })
    model.select(selected.id)
    let window = LibraryWindow(model: model)
    defer { window.closePreview() }
    window.show()
    try await Task.sleep(for: .milliseconds(300)) // Allow the hosting/split views to complete their first layout.
    let data = try window.renderedPreview()
    let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build/qa")
    try LibraryStore.directory(output)
    try data.write(to: output.appendingPathComponent("native-design-summary.png"))
    #expect(data.count > 20000)
}
