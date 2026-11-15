import CryptoKit
import Foundation
import IOKit
import Security

public enum CredentialStoreError: Error, Equatable {
    case keychain(OSStatus)
    case encodingFailed
    case writeFailed
}

/// One encrypted file per account, holding everything secret about it.
///
/// Files live in Application Support, readable only by this user, sealed with
/// AES-GCM under a key derived from this Mac's hardware id. A copied file is
/// useless on another Mac. The Keychain is no longer used because every
/// rebuild of the app made macOS ask for the password once per item.
public struct CredentialStore {
    public let directory: URL
    /// Where credentials lived before files. Read once per account, then removed.
    private let legacyService: String?

    public init(directory: URL? = nil,
                legacyKeychainService: String? = "com.hazime.claudeusagemulti.oauth") {
        self.directory = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Claude Usage Multi/credentials", isDirectory: true)
        self.legacyService = legacyKeychainService
    }

    private func file(_ id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).sealed")
    }

    public func load(_ id: UUID) -> StoredCredential? {
        if let sealed = try? Data(contentsOf: file(id)) {
            guard let box = try? AES.GCM.SealedBox(combined: sealed),
                  let data = try? AES.GCM.open(box, using: key()),
                  let credential = try? JSONDecoder().decode(StoredCredential.self, from: data) else {
                NSLog("\u{274C} Credential file for \(id) could not be read")
                return nil
            }
            return credential
        }
        return migrateFromKeychain(id)
    }

    public func save(_ credential: StoredCredential, for id: UUID) throws {
        guard let data = try? JSONEncoder().encode(credential),
              let sealed = try? AES.GCM.seal(data, using: key()).combined else {
            throw CredentialStoreError.encodingFailed
        }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            try sealed.write(to: file(id), options: [.atomic])
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file(id).path)
        } catch {
            throw CredentialStoreError.writeFailed
        }
    }

    public func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: file(id))
    }

    // MARK: - Key

    /// Derived from the hardware UUID, so nothing secret is stored on disk.
    private func key() -> SymmetricKey {
        let material = SymmetricKey(data: Data((Self.hardwareUUID() ?? fallbackSeed()).utf8))
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: material,
                                      salt: Data("com.hazime.claudeusagemulti.credentials".utf8),
                                      outputByteCount: 32)
    }

    private static func hardwareUUID() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(service, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String
    }

    /// Only used if the hardware id cannot be read: a random seed kept beside the files.
    private func fallbackSeed() -> String {
        let url = directory.appendingPathComponent(".seed")
        if let seed = try? String(contentsOf: url, encoding: .utf8), !seed.isEmpty { return seed }
        let seed = UUID().uuidString + UUID().uuidString
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? seed.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return seed
    }

    // MARK: - Keychain migration

    private func migrateFromKeychain(_ id: UUID) -> StoredCredential? {
        guard let service = legacyService else { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
        ]
        var read = query
        read[kSecReturnData as String] = true
        read[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(read as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let credential = try? JSONDecoder().decode(StoredCredential.self, from: data) else { return nil }
        do {
            try save(credential, for: id)
            SecItemDelete(query as CFDictionary)
            NSLog("\u{1F512} Moved credentials for \(id) from the Keychain to an encrypted file")
        } catch {
            NSLog("\u{274C} Could not move credentials for \(id) out of the Keychain: \(error)")
        }
        return credential
    }
}
