import Foundation
import AppKit
@preconcurrency import MSAL
import JottieModels
import JottieLibrary

public protocol MicrosoftTokenProvider: Sendable {
    func token(accountID: String, tenantID: String) async throws -> String
}

@MainActor public final class MicrosoftAccount: MicrosoftTokenProvider {
    private var application: MSALPublicClientApplication?
    private var tenant = ""
    public init() {}
    public func configure(clientID: String, tenantID: String) throws {
        guard UUID(uuidString: clientID) != nil, UUID(uuidString: tenantID) != nil else {
            throw JottieError.invalid("Enter the Microsoft application and tenant UUIDs in Library Settings.")
        }
        let authority = try MSALAADAuthority(url: URL(string: "https://login.microsoftonline.com/\(tenantID)")!)
        let config = MSALPublicClientApplicationConfig(clientId: clientID,
            redirectUri: "msauth.com.gravyraveydavey.jottie://auth", authority: authority)
        config.cacheConfig.keychainSharingGroup = "com.gravyraveydavey.jottie"
        application = try MSALPublicClientApplication(configuration: config)
        tenant = tenantID
    }
    public func signIn(presenting controller: NSViewController) async throws -> String {
        guard let application else { throw JottieError.invalid("Configure Microsoft sign-in first.") }
        let web = MSALWebviewParameters(authPresentationViewController: controller)
        let parameters = MSALInteractiveTokenParameters(scopes: ["User.Read", "Files.ReadWrite"], webviewParameters: web)
        return try await withCheckedThrowingContinuation { continuation in
            application.acquireToken(with: parameters) { result, _ in
                if let id = result?.account.identifier { continuation.resume(returning: id) }
                else { continuation.resume(throwing: JottieError.unavailable("Microsoft sign-in did not complete. Review the app registration and tenant consent.")) }
            }
        }
    }
    public func token(accountID: String, tenantID: String) async throws -> String {
        guard tenant == tenantID, let application,
              let account = try application.allAccounts().first(where: { $0.identifier == accountID }) else {
            throw JottieError.unavailable("Reconnect the Microsoft account for this destination.")
        }
        let parameters = MSALSilentTokenParameters(scopes: ["User.Read", "Files.ReadWrite"], account: account)
        return try await withCheckedThrowingContinuation { continuation in
            application.acquireTokenSilent(with: parameters) { result, _ in
                if let token = result?.accessToken { continuation.resume(returning: token) }
                else { continuation.resume(throwing: JottieError.unavailable("Microsoft access needs interactive sign-in. Reconnect in Library Settings.")) }
            }
        }
    }
}

public protocol GraphTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}
public struct URLGraphTransport: GraphTransport {
    public init() {}
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        let session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, data.count <= 16_000_000 else {
            throw JottieError.invalid("Unexpected Microsoft response.")
        }
        return (data, http)
    }
}
private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public actor GraphPublisher: ContextPublisher {
    private let tokens: any MicrosoftTokenProvider
    private let transport: any GraphTransport
    private let receiptStore: URL
    public init(tokens: any MicrosoftTokenProvider, root: URL, transport: any GraphTransport = URLGraphTransport()) throws {
        self.tokens = tokens; self.transport = transport
        receiptStore = root.appendingPathComponent("PublicationReceipts")
        try LibraryStore.directory(receiptStore)
    }
    private struct Item: Decodable {
        struct Parent: Decodable { var driveId: String?; var id: String? }
        var id: String
        var name: String?
        var webUrl: String?
        var eTag: String?
        var folder: [String: Int]?
        var parentReference: Parent?
    }
    private struct Receipt: Codable { var itemID: String; var eTag: String; var hash: String }
    private func remoteBytes(itemID: String, destination: PublishDestination) async throws -> Data {
        let (data, response) = try await request(itemPath(destination, item: itemID) + "/content", destination: destination)
        if response.statusCode == 200 { return data }
        guard [301, 302, 303, 307, 308].contains(response.statusCode),
              let location = response.value(forHTTPHeaderField: "Location"), let url = URL(string: location),
              url.scheme == "https", url.host == URL(string: destination.webURL)?.host,
              url.user == nil, url.password == nil, url.port == nil
        else { throw JottieError.conflict("Could not verify previously published content.") }
        // A download URL carries its own credentials. Never forward a Graph token.
        let (bytes, result) = try await transport.send(URLRequest(url: url))
        guard result.statusCode == 200 else { throw JottieError.unavailable("Could not verify a previous upload.") }
        return bytes
    }
    private func encode(_ string: String) -> String {
        string.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
    }
    private func itemPath(_ destination: PublishDestination, item: String? = nil) -> String {
        "/drives/\(encode(destination.driveID))/items/\(encode(item ?? destination.itemID))"
    }
    private func request(_ path: String, destination: PublishDestination, method: String = "GET",
                         body: Data? = nil, headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        guard path.hasPrefix("/"), !path.hasPrefix("//") else { throw JottieError.invalid("Invalid Graph path.") }
        let token = try await tokens.token(accountID: destination.accountID, tenantID: destination.tenantID)
        var request = URLRequest(url: URL(string: "https://graph.microsoft.com/v1.0" + path)!)
        request.httpMethod = method; request.httpBody = body; request.timeoutInterval = 60
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let result = try await transport.send(request)
        if [401, 403].contains(result.1.statusCode) { throw JottieError.unavailable("Microsoft denied access. Reconnect or choose an authorised destination; permissions were not broadened.") }
        if result.1.statusCode == 429 || result.1.statusCode >= 500 {
            throw JottieError.unavailable("Microsoft is busy or unavailable. Publication will retry.")
        }
        guard !(300..<400).contains(result.1.statusCode) || path.hasSuffix("/content") else { throw JottieError.invalid("Graph redirect was rejected.") }
        return result
    }
    public func resolve(folderURL: String, accountID: String, tenantID: String) async throws -> PublishDestination {
        guard let url = URL(string: folderURL), url.scheme == "https", url.user == nil, url.password == nil,
              url.host?.hasSuffix(".sharepoint.com") == true || url.host == "1drv.ms" || url.host == "onedrive.live.com"
        else { throw JottieError.invalid("Use an HTTPS SharePoint or OneDrive folder link.") }
        let share = "u!" + Data(folderURL.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let provisional = PublishDestination(tenantID: tenantID, accountID: accountID, driveID: "", itemID: "", webURL: folderURL)
        let (data, response) = try await request("/shares/\(encode(share))/driveItem", destination: provisional)
        guard response.statusCode == 200 else { throw JottieError.unavailable("Could not resolve this folder link with the granted Microsoft permissions.") }
        let item = try JSONDecoder().decode(Item.self, from: data)
        guard item.folder != nil, let drive = item.parentReference?.driveId, let webURL = item.webUrl else {
            throw JottieError.invalid("Choose a folder, not a file.")
        }
        return PublishDestination(tenantID: tenantID, accountID: accountID, driveID: drive, itemID: item.id, webURL: webURL)
    }
    private func verify(_ destination: PublishDestination) async throws {
        let (data, response) = try await request(itemPath(destination), destination: destination)
        guard response.statusCode == 200 else { throw JottieError.unavailable("The publication destination is unavailable.") }
        let item = try JSONDecoder().decode(Item.self, from: data)
        guard item.id == destination.itemID, item.folder != nil, item.parentReference?.driveId == destination.driveID,
              item.webUrl == destination.webURL else { throw JottieError.conflict("The publication destination changed. Reconnect it explicitly.") }
    }
    private func folder(_ name: String, parent: String, destination: PublishDestination, attempt: Int = 0) async throws -> String {
        guard attempt < 3 else { throw JottieError.conflict("The remote folder kept changing. Publication will wait for review.") }
        let path = itemPath(destination, item: parent)
        let (data, response) = try await request(path + ":/\(encode(name))", destination: destination)
        if response.statusCode == 200 {
            let value = try JSONDecoder().decode(Item.self, from: data)
            guard value.folder != nil else { throw JottieError.conflict("A remote file occupies a publication folder name.") }
            return value.id
        }
        guard response.statusCode == 404 else { throw JottieError.unavailable("Could not inspect the remote folder.") }
        let body = try JSONSerialization.data(withJSONObject: ["name": name, "folder": [:], "@microsoft.graph.conflictBehavior": "fail"])
        let (created, result) = try await request(path + "/children", destination: destination, method: "POST", body: body, headers: ["Content-Type": "application/json"])
        if result.statusCode == 409 { return try await folder(name, parent: parent, destination: destination, attempt: attempt + 1) }
        guard result.statusCode == 201 else { throw JottieError.unavailable("Could not create the publication folder.") }
        return try JSONDecoder().decode(Item.self, from: created).id
    }
    /// Content-hash filenames make retries stable. Existing content is never replaced.
    private func immutable(_ data: Data, name: String, parent: String, destination: PublishDestination) async throws {
        let path = itemPath(destination, item: parent) + ":/\(encode(name))"
        let receipt = receiptStore.appendingPathComponent(Codec.hash(destination.driveID + parent + name) + ".json")
        let (existing, status) = try await request(path, destination: destination)
        if status.statusCode == 200 {
            let item = try JSONDecoder().decode(Item.self, from: existing)
            if let saved = try? Codec.decode(Receipt.self, from: Data(contentsOf: receipt)),
               saved.itemID == item.id, saved.eTag == item.eTag, saved.hash == Codec.hash(data) { return }
            guard try await remoteBytes(itemID: item.id, destination: destination) == data, let etag = item.eTag else {
                throw JottieError.conflict("Previously published content was edited. Publication held for review.")
            }
            try Codec.encode(Receipt(itemID: item.id, eTag: etag, hash: Codec.hash(data))).write(to: receipt, options: .atomic)
            return
        }
        guard status.statusCode == 404 else { throw JottieError.unavailable("Could not inspect remote content.") }
        let sessionBody = try JSONSerialization.data(withJSONObject: ["item": ["name": name, "@microsoft.graph.conflictBehavior": "fail"]])
        let (sessionData, sessionStatus) = try await request(path + ":/createUploadSession", destination: destination,
            method: "POST", body: sessionBody, headers: ["Content-Type": "application/json"])
        guard sessionStatus.statusCode == 200,
              let session = try JSONSerialization.jsonObject(with: sessionData) as? [String: Any],
              let rawURL = session["uploadUrl"] as? String, let url = URL(string: rawURL),
              url.scheme == "https", url.user == nil, url.password == nil, url.port == nil,
              url.host == URL(string: destination.webURL)?.host || url.host?.hasSuffix(".up.1drv.com") == true
        else { throw JottieError.unavailable("Could not establish an upload session.") }
        var upload = URLRequest(url: url)
        upload.httpMethod = "PUT"; upload.httpBody = data; upload.timeoutInterval = 60
        upload.setValue(String(data.count), forHTTPHeaderField: "Content-Length")
        upload.setValue("bytes 0-\(max(0, data.count - 1))/\(data.count)", forHTTPHeaderField: "Content-Range")
        let (created, result) = try await transport.send(upload)
        guard [200, 201].contains(result.statusCode) else {
            if [409, 412].contains(result.statusCode) { throw JottieError.conflict("A remote publication changed concurrently.") }
            throw JottieError.unavailable("Upload did not complete; publication will retry.")
        }
        let item = try JSONDecoder().decode(Item.self, from: created)
        guard let etag = item.eTag else { throw JottieError.invalid("Microsoft did not return a publication version.") }
        try Codec.encode(Receipt(itemID: item.id, eTag: etag, hash: Codec.hash(data))).write(to: receipt, options: .atomic)
    }
    /// Only mutable projections use If-Match. A remote edit is never overwritten.
    private func current(_ data: Data, name: String, parent: String, destination: PublishDestination) async throws {
        let path = itemPath(destination, item: parent) + ":/\(encode(name))"
        let receipt = receiptStore.appendingPathComponent(Codec.hash(destination.driveID + parent + name) + ".json")
        let (existing, status) = try await request(path, destination: destination)
        if status.statusCode == 404 {
            try await immutable(data, name: name, parent: parent, destination: destination)
            return
        }
        guard status.statusCode == 200 else { throw JottieError.unavailable("Could not inspect the current publication.") }
        let item = try JSONDecoder().decode(Item.self, from: existing)
        guard let etag = item.eTag else { throw JottieError.invalid("Missing remote version.") }
        let saved = try? Codec.decode(Receipt.self, from: Data(contentsOf: receipt))
        if try await remoteBytes(itemID: item.id, destination: destination) == data {
            try Codec.encode(Receipt(itemID: item.id, eTag: etag, hash: Codec.hash(data))).write(to: receipt, options: .atomic)
            return
        }
        guard saved?.itemID == item.id, saved?.eTag == etag else {
            throw JottieError.conflict("The current remote context was edited. Publication held for review.")
        }
        let (updated, result) = try await request(itemPath(destination, item: item.id) + "/content",
            destination: destination, method: "PUT", body: data,
            headers: ["Content-Type": "text/plain; charset=utf-8", "If-Match": etag])
        guard result.statusCode == 200 else { throw JottieError.conflict("Remote publication changed concurrently.") }
        let value = try JSONDecoder().decode(Item.self, from: updated)
        guard let version = value.eTag else { throw JottieError.invalid("Missing remote version.") }
        try Codec.encode(Receipt(itemID: value.id, eTag: version, hash: Codec.hash(data))).write(to: receipt, options: .atomic)
    }
    public func publish(meeting: Meeting, to destination: PublishDestination) async throws {
        guard let revision = meeting.analysis, revision.analysis.sensitivity == "normal" else {
            throw JottieError.invalid("Publication held: this meeting needs review.")
        }
        try await verify(destination)
        let meetings = try await folder("Meetings", parent: destination.itemID, destination: destination)
        let parent = try await folder(meeting.id.uuidString, parent: meetings, destination: destination)
        // Membership and speaker corrections also affect publication, independently of AI revision.
        let fingerprint = Codec.hash(try Codec.encode(meeting))
        let version = try await folder(fingerprint, parent: parent, destination: destination)
        let metadata = try Codec.encode(meeting)
        for (name, data) in [
            ("transcript.md", Data(meeting.transcript.utf8)),
            ("transcript.txt", Data(meeting.transcript.utf8)),
            ("meeting.md", Data(meeting.markdown.utf8)),
            ("meeting.txt", Data(meeting.markdown.utf8)),
            ("metadata.json", metadata)
        ] { try await immutable(data, name: name, parent: version, destination: destination) }
        let manifest = try JSONSerialization.data(withJSONObject: ["meetingID": meeting.id.uuidString, "revision": fingerprint,
            "folderID": meeting.folderID?.uuidString ?? "", "analysisRevision": revision.id], options: [.sortedKeys])
        try await current(manifest, name: "current.json", parent: parent, destination: destination)
    }
    public func publish(context: FolderContext, folder value: Folder, to destination: PublishDestination) async throws {
        try await verify(destination)
        let contexts = try await folder("Folders", parent: destination.itemID, destination: destination)
        let parent = try await folder(value.id.uuidString, parent: contexts, destination: destination)
        let version = try await folder(context.inputRevision, parent: parent, destination: destination)
        for (name, data) in [("context.md", Data(context.markdown.utf8)), ("context.txt", Data(context.markdown.utf8)),
                             ("context.json", try Codec.encode(context)), ("folder.json", try Codec.encode(value))] {
            try await immutable(data, name: name, parent: version, destination: destination)
        }
        try await current(Data(context.markdown.utf8), name: "Current Context.txt", parent: parent, destination: destination)
        try await current(Codec.encode(context), name: "current.json", parent: parent, destination: destination)
    }
}
