import Foundation
import Testing
import JottieModels
import JottieLibrary
import JottieKnowledge

@Test func trashRetentionRestorationAndCaptureTombstones() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let capture = root.appendingPathComponent("capture")
    let store = try LibraryStore(root: root)
    var meeting = Meeting(sourceID: Codec.hash(capture.standardizedFileURL.path), title: "Disposable fixture", segments: [Segment(id: "s1", speaker: "me", text: "A synthetic discussion.")])
    let folder = Folder(name: "Design"); try await store.saveFolder(folder)
    meeting.folderID = folder.id; meeting.manuallyFiled = true
    try await store.save(meeting)
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    try await store.trash([meeting.id], now: now)
    #expect(try await store.meetings().isEmpty)
    #expect(try await store.search(SearchQuery()).isEmpty)
    #expect(try await !store.shouldImportAmanu(capture))
    let item = try #require(await store.trashEntries(now: now).first)
    #expect(item.expiresAt == now.addingTimeInterval(172800))
    #expect(try await store.purgeTrash(now: now.addingTimeInterval(172799)) == 0)
    try await store.restoreTrash(item.id)
    let restored = try await store.meeting(meeting.id)
    #expect(restored.manuallyFiled && restored.folderID == folder.id)
    #expect(try await store.shouldImportAmanu(capture))
    #expect(try await store.search(SearchQuery()).count == 1)
    try await store.trash([meeting.id], now: now)
    #expect(try await store.purgeTrash(now: now.addingTimeInterval(172800)) == 1)
    let reopened = try LibraryStore(root: root)
    #expect(try await reopened.trashEntries().isEmpty)
    #expect(try await !reopened.shouldImportAmanu(capture))
    try await reopened.rebuildIndex()
    #expect(try await reopened.search(SearchQuery()).isEmpty)
}

@Test func legacyTrashGetsGracePeriodAndEmptyTrashKeepsActiveMeetings() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LibraryStore(root: root)
    let source = root.appendingPathComponent("legacy-capture")
    let old = Meeting(sourceID: Codec.hash(source.standardizedFileURL.path), title: "Old trash", segments: [])
    let active = Meeting(sourceID: "active", title: "Active", segments: [])
    try await store.save(old); try await store.save(active)
    let legacy = root.appendingPathComponent("Trash/legacy")
    try FileManager.default.moveItem(at: store.meetingDirectory(old.id), to: legacy)
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    #expect(try await store.purgeTrash(now: now) == 0)
    #expect(try await !store.shouldImportAmanu(source))
    #expect(try await store.trashEntries(now: now).first?.trashedAt == now)
    await #expect(throws: JottieError.self) { try await store.restoreTrash("../Meetings") }
    #expect(try await store.purgeTrash(now: now, emptyAll: true) == 1)
    #expect(try await store.meeting(active.id).id == active.id)
}

@Test func bambooRequestsStayOnValidatedCompanyAndDecodeOnlyDirectoryFields() throws {
    #expect(try BambooHR.company(" https://Acme.bamboohr.com/ ") == "acme")
    for invalid in ["http://acme.bamboohr.com", "acme.bamboohr.com.evil.test", "acme/path", "acme@evil.test", ""] {
        #expect(throws: JottieError.self) { try BambooHR.company(invalid) }
    }
    let request = try BambooHR.request(company: "acme", key: "synthetic-key")
    #expect(request.url?.absoluteString == "https://acme.bamboohr.com/api/v1/employees/directory")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Basic " + Data("synthetic-key:x".utf8).base64EncodedString())
    let response = Data(#"{"employees":[{"id":"7","displayName":"Jamie Chen","workEmail":"jamie@example.test","jobTitle":"Designer","salary":"NOT STORED","homeEmail":"NOT STORED"}]}"#.utf8)
    let people = try BambooHR.decode(response, status: 200)
    #expect(people == [DirectoryPerson(id: "7", name: "Jamie Chen", workEmail: "jamie@example.test", jobTitle: "Designer")])
    #expect(!String(decoding: try Codec.encode(people), as: UTF8.self).contains("NOT STORED"))
    for status in [401,403,404,429,500] { #expect(throws: JottieError.self) { try BambooHR.decode(response, status: status) } }
    #expect(throws: JottieError.self) { try BambooHR.decode(Data("{broken}".utf8), status: 200) }
}

@Test func directoryMatchingIsUniqueEmailFirstTenantScopedAndSurvivesSearchRebuild() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let people = [DirectoryPerson(id: "1", name: "Jamie Chen", workEmail: "jamie@example.test", jobTitle: "Designer"),
                  DirectoryPerson(id: "2", name: "Sam Ellis", workEmail: "sam@example.test", jobTitle: "Engineer"),
                  DirectoryPerson(id: "3", name: "Sam Ellis", workEmail: "other@example.test", jobTitle: "Manager")]
    let directory = try PeopleDirectory(root: root)
    try await directory.replace(people, company: "acme", now: Date(timeIntervalSince1970: 1800000000))
    let matches = try await directory.matching(["Jamie Chen <JAMIE@example.test>", "Sam Ellis", "Sam Ellis <sam@example.test>", "Jamie Chen <wrong@example.test>"], company: "acme")
    #expect(matches.map(\.employeeID) == ["1", "2"])
    #expect(matches.allSatisfy { $0.matchedBy == "email" })
    #expect(try await directory.matching(["Jamie Chen"], company: "other").isEmpty)
    #expect(try await directory.matching(["Jamie Chen"], company: "acme").first?.matchedBy == "unique-name")
    let store = try LibraryStore(root: root); try await store.rebuildIndex()
    #expect(try await PeopleDirectory(root: root).snapshot(company: "acme").people == people)
    await #expect(throws: JottieError.self) { try await directory.replace([people[0],people[0]], company: "acme") }
    #expect(try await directory.snapshot(company: "acme").people == people)
    try await directory.replace([], company: "other")
    #expect(try await directory.snapshot(company: "acme").people.isEmpty)
}

private actor DirectoryRunner: StructuredRunner {
    var prompt = ""
    func run(prompt: String, schema: Data) async throws -> Data {
        self.prompt = prompt
        return try Codec.encode(Analysis(title: "Design", summary: "Approved the design.", summaryEvidence: [Evidence(segmentID: "s1", quote: "Approved the design.")]))
    }
}
@Test func directoryContextReachesAnalysisWithoutBecomingSpeakerIdentity() async throws {
    let runner = DirectoryRunner()
    var meeting = Meeting(sourceID: "directory", title: "Design", segments: [Segment(id: "s1", speaker: "remote", text: "Approved the design.")], participants: ["Jamie Chen"])
    meeting.participantContext = [ParticipantIdentity(invitee: "Jamie Chen", employeeID: "1", name: "Jamie Chen", workEmail: nil, jobTitle: "Designer", company: "acme", matchedBy: "unique-name", syncedAt: Date())]
    _ = try await CodexAnalyzer(runner: runner).analyze(meeting, prompt: Prompts.summary, folders: [])
    let prompt = await runner.prompt
    #expect(prompt.contains("Designer") && prompt.contains("not proof they spoke"))
    #expect(meeting.speakerNames.isEmpty)
    let old = try Codec.decode(LibrarySettings.self, from: Data("{}".utf8))
    #expect(!old.bambooEnabled && old.bambooCompany.isEmpty)
}

@Test func calendarMetadataRefreshesExistingCaptureWithoutLosingCorrections() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let capture = root.appendingPathComponent("source")
    try FileManager.default.createDirectory(at: capture, withIntermediateDirectories: true)
    let transcript = Data(#"{"segments":[{"speaker":"them","start_ms":0,"end_ms":1000,"text":"Hello Jamie."}]}"#.utf8)
    try transcript.write(to: capture.appendingPathComponent("transcript.json"))
    try Data(#"{"started":"2026-10-27T09:00:00Z"}"#.utf8).write(to: capture.appendingPathComponent("meta.json"))
    let store = try LibraryStore(root: root.appendingPathComponent("library"))
    let first = try await store.importAmanu(capture)
    try await store.setSpeaker("them", name: "Manual correction", meetingID: first.id)
    try Data(#"{"started":"2026-10-27T09:00:00Z","calendar":{"attendeeIdentities":["Jamie Chen <jamie@example.test>"]}}"#.utf8).write(to: capture.appendingPathComponent("meta.json"))
    let refreshed = try await store.importAmanu(capture)
    #expect(refreshed.id == first.id)
    #expect(refreshed.participants == ["Jamie Chen <jamie@example.test>"])
    #expect(refreshed.speakerNames["them"] == "Manual correction")
    #expect(refreshed.segments == first.segments)
}
@Test func directoryEmailsAreTrimmedAndMailtoIsCaseInsensitive() {
    let people = [DirectoryPerson(id: "1", name: "Jamie Chen", workEmail: " jamie@example.test ", jobTitle: "Designer")]
    let matches = PeopleDirectory.match(["Jamie Chen < JAMIE@example.test >", "MAILTO:jamie@example.test"], people: people, company: "test", syncedAt: Date())
    #expect(matches.count == 2)
}

@Test func manuallyAttachedCalendarWinsOverCaptureRefreshAndDoesNotRenameSpeakers() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let capture = root.appendingPathComponent("source")
    try FileManager.default.createDirectory(at: capture, withIntermediateDirectories: true)
    try Data(#"{"segments":[{"speaker":"them","start_ms":0,"end_ms":1000,"text":"Hello."}]}"#.utf8).write(to: capture.appendingPathComponent("transcript.json"))
    try Data(#"{"started":"2026-10-27T09:00:00Z","calendar":{"attendees":["Other person"]}}"#.utf8).write(to: capture.appendingPathComponent("meta.json"))
    let store = try LibraryStore(root: root.appendingPathComponent("library"))
    let first = try await store.importAmanu(capture)
    let event = CalendarEventContext(id: "chosen", calendarID: "work", calendarTitle: "Work Calendar", title: "The correct invitation", start: first.startedAt, end: first.startedAt.addingTimeInterval(3600), invitees: ["Jamie Chen <jamie@example.test>"])
    try await store.setCalendarContext(event, meetingID: first.id)
    let refreshed = try await store.importAmanu(capture)
    #expect(refreshed.calendarContext == event && refreshed.calendarContextManuallySet == true)
    #expect(refreshed.participants == event.invitees)
    #expect(refreshed.speakerNames.isEmpty && refreshed.segments == first.segments)
    let directory = try PeopleDirectory(root: store.root)
    try await directory.replace([DirectoryPerson(id: "1", name: "Jamie Chen", workEmail: "jamie@example.test", jobTitle: "Designer")], company: "work")
    let matches = try await directory.matching(refreshed.participants, company: "work")
    #expect(matches.first?.jobTitle == "Designer")
    #expect(try await store.setParticipantContext(matches, meetingID: first.id).speakerNames.isEmpty)
}
