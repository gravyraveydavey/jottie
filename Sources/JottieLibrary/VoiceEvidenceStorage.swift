import Foundation
import CryptoKit
import Security
import LocalAuthentication
import JottieModels

/// Access is serialized by LibraryStore's process lock. No plaintext biometric sidecars.
struct VoiceEvidenceStorage {
    let root: URL
    let testKey: Data?
    var directory: URL { root.appendingPathComponent("Voiceprints", isDirectory: true) }
    private var account: String { Codec.hash(root.standardizedFileURL.resolvingSymlinksInPath().path) }
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.gravyraveydavey.jottie.voiceprints",
         kSecAttrAccount as String: account]
    }
    private func key(create: Bool) throws -> SymmetricKey {
        if let testKey {
            guard testKey.count == 32 else { throw JottieError.invalid("Voice storage key must contain 32 bytes.") }
            return SymmetricKey(data: testKey)
        }
        var request = query
        let context = LAContext(); context.interactionNotAllowed = true
        request[kSecUseAuthenticationContext as String] = context
        request[kSecReturnData as String] = true; request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecSuccess, let bytes = result as? Data, bytes.count == 32 { return SymmetricKey(data: bytes) }
        guard status == errSecItemNotFound, create else {
            throw JottieError.unavailable("Voice evidence key is unavailable in Jottie's Keychain. Audio is retained if transcription has not completed.")
        }
        let key = SymmetricKey(size: .bits256)
        var item = query
        item[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
            throw JottieError.unavailable("Could not save Jottie's voice evidence key. Audio is retained for retry.")
        }
        return key
    }
    func save(_ evidence: VoiceEvidence) throws {
        guard evidence.sourceID.count == 64, evidence.sourceID.allSatisfy(\.isHexDigit), evidence.schemaVersion == 1,
              evidence.samples.count <= 20_000, evidence.samples.allSatisfy(\.isValid) else { throw JottieError.invalid("Invalid voice evidence.") }
        try LibraryStore.directory(directory)
        let sealed = try AES.GCM.seal(Codec.encode(evidence), using: key(create: true), authenticating: Data(evidence.sourceID.utf8))
        guard let bytes = sealed.combined else { throw JottieError.invalid("Could not encrypt voice evidence.") }
        let path = directory.appendingPathComponent(evidence.sourceID + ".aes")
        try bytes.write(to: path, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }
    func load(_ sourceID: String) throws -> VoiceEvidence? {
        guard sourceID.count == 64, sourceID.allSatisfy(\.isHexDigit) else { return nil }
        let path = directory.appendingPathComponent(sourceID + ".aes")
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        let data = try Data(contentsOf: path)
        guard data.count <= 64_000_000 else { throw JottieError.invalid("Voice evidence is too large.") }
        let clear = try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key(create: false), authenticating: Data(sourceID.utf8))
        let result = try Codec.decode(VoiceEvidence.self, from: clear)
        guard result.schemaVersion == 1, result.sourceID == sourceID, result.samples.count <= 20_000,
              result.samples.allSatisfy(\.isValid) else { throw JottieError.invalid("Invalid saved voice evidence.") }
        return result
    }
    func remove(_ sourceID: String) throws {
        guard sourceID.count == 64, sourceID.allSatisfy(\.isHexDigit) else { return }
        let path = directory.appendingPathComponent(sourceID + ".aes")
        if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
    }
    func erase() throws {
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
        if testKey == nil {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw JottieError.unavailable("Could not remove the voice evidence key.") }
        }
    }
}
