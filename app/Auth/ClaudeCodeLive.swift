import Foundation
import Security

/// Claude Code's live login: its Keychain item and `~/.claude.json`.
public protocol ClaudeCodeLive {
    /// Nil when Claude Code has no Keychain item.
    func readKeychain() throws -> Data?
    /// Updates the existing item only. Throws `.notLoggedIn` if there is none.
    func writeKeychain(_ data: Data) throws
    func readConfig() throws -> Data?
    func writeConfig(_ data: Data) throws
}

public final class SystemClaudeCodeLive: ClaudeCodeLive {
    static let service = "Claude Code-credentials"
    private let configURL: URL
    private let keychainAccount: String

    public init(configURL: URL = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".claude.json"),
                keychainAccount: String = NSUserName()) {
        self.configURL = configURL
        self.keychainAccount = keychainAccount
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.service,
         kSecAttrAccount as String: keychainAccount]
    }

    public func readKeychain() throws -> Data? {
        var read = query
        read[kSecReturnData as String] = true
        read[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(read as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw ClaudeCodeError.keychain(status)
        }
        return data
    }

    /// Never creates the item: one made by this app would carry access rights
    /// Claude Code cannot use.
    public func writeKeychain(_ data: Data) throws {
        let status = SecItemUpdate(query as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound { throw ClaudeCodeError.notLoggedIn }
        guard status == errSecSuccess else { throw ClaudeCodeError.keychain(status) }
    }

    public func readConfig() throws -> Data? {
        guard FileManager.default.fileExists(atPath: configURL.path) else { return nil }
        do { return try Data(contentsOf: configURL) } catch { throw ClaudeCodeError.config }
    }

    public func writeConfig(_ data: Data) throws {
        let fm = FileManager.default
        let mode = (try? fm.attributesOfItem(atPath: configURL.path))?[.posixPermissions] as? Int
        do {
            try data.write(to: configURL, options: [.atomic])
            if let mode { try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: configURL.path) }
        } catch {
            throw ClaudeCodeError.config
        }
    }
}

/// Asks Anthropic which account an access token belongs to.
public protocol ProfileChecking {
    func accountUUID(accessToken: String) async -> String?
}
