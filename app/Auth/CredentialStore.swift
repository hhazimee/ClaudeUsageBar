import Foundation
import Security

public enum CredentialStoreError: Error, Equatable {
    case keychain(OSStatus)
    case encodingFailed
}

/// One keychain item per account, holding everything secret about it.
///
/// The app creates these items itself, so macOS grants it access without
/// prompting. That is the whole point of the design: the previous approach
/// read items belonging to the `claude` binary, which prompts on every read.
public struct CredentialStore {
    public let service: String

    public init(service: String = "com.hazime.claudeusagemulti.oauth") {
        self.service = service
    }

    private func query(_ id: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString
        ]
    }

    public func load(_ id: UUID) -> StoredCredential? {
        var query = query(id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(StoredCredential.self, from: data)
    }

    public func save(_ credential: StoredCredential, for id: UUID) throws {
        guard let data = try? JSONEncoder().encode(credential) else {
            throw CredentialStoreError.encodingFailed
        }

        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let updateStatus = SecItemUpdate(query(id) as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw CredentialStoreError.keychain(updateStatus)
        }

        var insert = query(id)
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        insert[kSecAttrLabel as String] = "Claude Usage Multi"
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw CredentialStoreError.keychain(addStatus)
        }
    }

    public func delete(_ id: UUID) {
        SecItemDelete(query(id) as CFDictionary)
    }
}
