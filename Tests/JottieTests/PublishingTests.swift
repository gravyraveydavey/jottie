import Foundation
import Testing
import JottieModels
import JottieLibrary
import JottieKnowledge

private struct TestTokens: MicrosoftTokenProvider {
    func token(accountID: String, tenantID: String) throws -> String {
        guard accountID == "account", tenantID == "tenant" else { throw JottieError.invalid("Account mismatch") }
        return "synthetic-token"
    }
}

private actor MemoryGraph: GraphTransport {
    struct Item {
        var id: String
        var name: String
        var parent: String
        var folder: Bool
        var bytes: Data
        var version = 1
    }
    var items: [String: Item] = ["root": Item(id: "root", name: "Root", parent: "", folder: true, bytes: Data())]
    var sessions: [String: (parent: String, name: String)] = [:]
    var writes = 0
    var leakedBearer = false
    var mismatchRoot = false
    func countFiles() -> Int { items.values.filter { !$0.folder }.count }
    func changeDestination() { mismatchRoot = true }
    func edit(_ name: String) {
        if let item = items.values.first(where: { $0.name == name }) {
            var changed = item; changed.bytes = Data("external edit".utf8); changed.version += 1; items[item.id] = changed
        }
    }
    private func json(_ item: Item) -> [String: Any] {
        var result: [String: Any] = ["id": item.id, "name": item.name, "eTag": "\"\(item.version)\"",
                                    "parentReference": ["driveId": "drive", "id": item.parent],
                                    "webUrl": item.id == "root" ? (mismatchRoot ? "https://tenant.sharepoint.com/changed" : "https://tenant.sharepoint.com/root") : "https://tenant.sharepoint.com/\(item.id)"]
        if item.folder { result["folder"] = [:] as [String: Int] }
        return result
    }
    func send(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let url = request.url!, path = url.path.removingPercentEncoding ?? url.path
        func reply(_ status: Int, _ object: [String: Any] = [:], bytes: Data? = nil) throws -> (Data, HTTPURLResponse) {
            (try bytes ?? JSONSerialization.data(withJSONObject: object), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
        if path.hasPrefix("/upload/") {
            leakedBearer = leakedBearer || request.value(forHTTPHeaderField: "Authorization") != nil
            guard let session = sessions[path], !items.values.contains(where: { $0.parent == session.parent && $0.name == session.name }) else { return try reply(409) }
            let item = Item(id: UUID().uuidString, name: session.name, parent: session.parent, folder: false, bytes: request.httpBody ?? Data())
            items[item.id] = item; writes += 1
            return try reply(201, json(item))
        }
        guard let marker = path.range(of: "/items/") else { return try reply(404) }
        let suffix = String(path[marker.upperBound...])
        let parts = suffix.components(separatedBy: ":/")
        if parts.count > 1 {
            let parent = parts[0], name = parts[1]
            if parts.last == "createUploadSession" {
                let sessionPath = "/upload/\(UUID())"; sessions[sessionPath] = (parent, name)
                return try reply(200, ["uploadUrl": "https://tenant.sharepoint.com" + sessionPath])
            }
            if let item = items.values.first(where: { $0.parent == parent && $0.name == name }) { return try reply(200, json(item)) }
            return try reply(404)
        }
        if suffix.hasSuffix("/children"), request.httpMethod == "POST" {
            let parent = String(suffix.dropLast("/children".count))
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            let name = body["name"] as! String
            if items.values.contains(where: { $0.parent == parent && $0.name == name }) { return try reply(409) }
            let item = Item(id: UUID().uuidString, name: name, parent: parent, folder: true, bytes: Data())
            items[item.id] = item
            return try reply(201, json(item))
        }
        if suffix.hasSuffix("/content") {
            let id = String(suffix.dropLast("/content".count))
            guard var item = items[id] else { return try reply(404) }
            if request.httpMethod == "PUT" {
                guard request.value(forHTTPHeaderField: "If-Match") == "\"\(item.version)\"" else { return try reply(412) }
                item.bytes = request.httpBody ?? Data(); item.version += 1; items[id] = item; writes += 1
                return try reply(200, json(item))
            }
            return try reply(200, bytes: item.bytes)
        }
        guard let item = items[suffix] else { return try reply(404) }
        return try reply(200, json(item))
    }
}

private func fixture() -> Meeting {
    var value = Meeting(sourceID: "test", title: "Synthetic", segments: [Segment(id: "s1", speaker: "me", text: "We approved the plan.")])
    value.folderID = UUID()
    value.analysis = AnalysisRevision(transcriptRevision: value.transcriptRevision, promptRevision: "test",
        analysis: Analysis(title: "Plan approved", summary: "The plan was approved.",
                           summaryEvidence: [Evidence(segmentID: "s1", quote: "We approved the plan.")]))
    return value
}
private let destination = PublishDestination(tenantID: "tenant", accountID: "account", driveID: "drive", itemID: "root", webURL: "https://tenant.sharepoint.com/root")

@Test func publishingRecoversReceiptsAndRejectsRemoteEdits() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("jottie-graph-test-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let graph = MemoryGraph(), meeting = fixture()
    let publisher = try GraphPublisher(tokens: TestTokens(), root: root, transport: graph)
    try await publisher.publish(meeting: meeting, to: destination)
    let count = await graph.countFiles()
    #expect(count == 6)
    try await publisher.publish(meeting: meeting, to: destination)
    #expect(await graph.countFiles() == count)
    // Simulate a crash after remote commit but before local receipt persistence.
    for file in try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("PublicationReceipts"), includingPropertiesForKeys: nil) {
        try FileManager.default.removeItem(at: file)
    }
    try await publisher.publish(meeting: meeting, to: destination)
    #expect(await graph.countFiles() == count)
    #expect(await graph.leakedBearer == false)
    await graph.edit("meeting.md")
    await #expect(throws: (any Error).self) { try await publisher.publish(meeting: meeting, to: destination) }
}

@Test func sensitiveContentAndChangedDestinationsDoNotPublish() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("jottie-graph-test-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let graph = MemoryGraph()
    let publisher = try GraphPublisher(tokens: TestTokens(), root: root, transport: graph)
    var meeting = fixture()
    meeting.analysis?.analysis.sensitivity = "sensitive"
    await #expect(throws: (any Error).self) { try await publisher.publish(meeting: meeting, to: destination) }
    #expect(await graph.countFiles() == 0)
    await graph.changeDestination()
    meeting.analysis?.analysis.sensitivity = "normal"
    await #expect(throws: (any Error).self) { try await publisher.publish(meeting: meeting, to: destination) }
    #expect(await graph.countFiles() == 0)
}
