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
