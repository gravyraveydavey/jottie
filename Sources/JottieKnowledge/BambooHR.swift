import Foundation
import Security
import JottieModels
import JottieLibrary

public enum BambooHR {
    /// Accept a subdomain or the company's BambooHR address, never arbitrary hosts/paths.
    public static func company(_ input: String) throws -> String {
        var name = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if name.hasPrefix("https://") { name.removeFirst(8) }
        if name.hasSuffix("/") { name.removeLast() }
        if name.hasSuffix(".bamboohr.com") { name.removeLast(".bamboohr.com".count) }
        guard name.range(of: "^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$", options: .regularExpression) != nil else {
            throw JottieError.invalid("Enter your company subdomain or https://company.bamboohr.com address.")
        }
        return name
    }
    public static func request(company: String, key: String) throws -> URLRequest {
        let name = try self.company(company)
        let secret = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !secret.isEmpty, !secret.contains(":"), !secret.contains("\n"), !secret.contains("\r") else { throw JottieError.invalid("Enter a valid BambooHR API key.") }
        var request = URLRequest(url: URL(string: "https://\(name).bamboohr.com/api/v1/employees/directory")!)
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Basic " + Data("\(secret):x".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        return request
    }
    public static func decode(_ data: Data, status: Int) throws -> [DirectoryPerson] {
        guard status == 200 else {
            let message = [401: "API key is missing or invalid.", 403: "The API key cannot read this company's directory, or access is temporarily blocked.",
                           404: "Company directory not found. Check the company address.", 429: "BambooHR rate limit reached. Try again later."][status] ?? "BambooHR is unavailable (HTTP \(status)). Try again later."
            throw JottieError.unavailable(message)
        }
        guard data.count <= 16_000_000 else { throw JottieError.invalid("The BambooHR directory response is too large.") }
        struct Response: Decodable {
            struct Employee: Decodable {
                var id: String; var displayName: String?; var firstName: String?; var lastName: String?; var preferredName: String?; var workEmail: String?; var jobTitle: String?
            }
            var employees: [Employee]
        }
        let response: Response
        do { response = try JSONDecoder().decode(Response.self, from: data) }
        catch { throw JottieError.invalid("BambooHR returned an unreadable directory. The previous directory was retained.") }
        let people = response.employees.compactMap { employee -> DirectoryPerson? in
            let name = (employee.displayName ?? [employee.preferredName ?? employee.firstName, employee.lastName].compactMap { $0 }.joined(separator: " ")).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !employee.id.isEmpty, !name.isEmpty else { return nil }
            return DirectoryPerson(id: employee.id, name: name, workEmail: employee.workEmail, jobTitle: employee.jobTitle)
        }
        guard people.count == response.employees.count, Set(people.map(\.id)).count == people.count else { throw JottieError.invalid("BambooHR returned incomplete or duplicate employees. The previous directory was retained.") }
        return people
    }
    public static func fetch(company: String, key: String) async throws -> [DirectoryPerson] {
        let delegate = NoRedirects()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil; configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request(company: company, key: key))
        guard let http = response as? HTTPURLResponse else { throw JottieError.unavailable("No response from BambooHR.") }
        return try decode(data, status: http.statusCode)
    }
    private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
    }
}

/// One credential per explicitly configured company. No inherited credentials or shared access group.
public enum BambooKeychain {
    private static let service = "com.gravyraveydavey.jottie.bamboohr"
    private static func query(_ company: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: company]
    }
    public static func read(company: String) throws -> String? {
        var query = query(try BambooHR.company(company)); query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let result = SecItemCopyMatching(query as CFDictionary, &item)
        if result == errSecItemNotFound { return nil }
        guard result == errSecSuccess, let data = item as? Data, let value = String(data: data, encoding: .utf8) else { throw JottieError.unavailable("BambooHR key could not be read from Jottie's Keychain.") }
        return value
    }
    public static func save(_ key: String, company: String) throws {
        let name = try BambooHR.company(company)
        let query = query(name)
        let value = Data(key.utf8)
        let result = SecItemUpdate(query as CFDictionary, [kSecValueData as String: value] as CFDictionary)
        if result == errSecItemNotFound {
            var item = query; item[kSecValueData as String] = value; item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw JottieError.unavailable("BambooHR key could not be saved in Jottie's Keychain.") }; return
        }
        guard result == errSecSuccess else { throw JottieError.unavailable("BambooHR key could not be updated in Jottie's Keychain.") }
    }
    public static func remove(company: String) throws {
        let result = SecItemDelete(query(try BambooHR.company(company)) as CFDictionary)
        guard result == errSecSuccess || result == errSecItemNotFound else { throw JottieError.unavailable("BambooHR key could not be removed from Jottie's Keychain.") }
    }
}
