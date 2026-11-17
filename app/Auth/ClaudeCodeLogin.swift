import Foundation

/// A saved copy of Claude Code's own login for one account.
///
/// Both halves are kept as raw JSON so fields Claude Code adds later survive
/// a round trip through the app.
public struct ClaudeCodeLogin: Codable, Equatable {
    /// The `claudeAiOauth` object from Claude Code's Keychain item.
    public var oauth: Data
    /// The `oauthAccount` object from `~/.claude.json`.
    public var account: Data

    public init(oauth: Data, account: Data) {
        self.oauth = oauth
        self.account = account
    }

    public var accessToken: String? { ClaudeCodeJSON.string(oauth, "accessToken") }
    public var refreshToken: String? { ClaudeCodeJSON.string(oauth, "refreshToken") }
    public var accountUUID: String? { ClaudeCodeJSON.string(account, "accountUuid") }
    public var email: String? { ClaudeCodeJSON.string(account, "emailAddress") }
}

/// Reads and rewrites Claude Code's login JSON, touching one key and nothing else.
public enum ClaudeCodeJSON {
    static let oauthKey = "claudeAiOauth"
    static let accountKey = "oauthAccount"

    /// Nil unless the Keychain item holds a Claude login. The account half may
    /// be empty if `~/.claude.json` has none.
    public static func login(keychain: Data, config: Data?) -> ClaudeCodeLogin? {
        guard let oauth = object(keychain)?[oauthKey],
              let oauthData = try? JSONSerialization.data(withJSONObject: oauth) else { return nil }
        let account = config.flatMap { object($0)?[accountKey] } ?? [String: Any]()
        guard let accountData = try? JSONSerialization.data(withJSONObject: account) else { return nil }
        return ClaudeCodeLogin(oauth: oauthData, account: accountData)
    }

    /// Replaces `claudeAiOauth`, keeping `mcpOAuth` and every other key.
    public static func mergeKeychain(_ existing: Data, oauth: Data) throws -> Data {
        try replace(oauthKey, in: existing, with: oauth)
    }

    /// Replaces `oauthAccount`, keeping every other key.
    public static func mergeConfig(_ existing: Data, account: Data) throws -> Data {
        try replace(accountKey, in: existing, with: account)
    }

    static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func string(_ data: Data, _ key: String) -> String? {
        object(data)?[key] as? String
    }

    private static func replace(_ key: String, in existing: Data, with value: Data) throws -> Data {
        guard var top = object(existing),
              let inner = try? JSONSerialization.jsonObject(with: value) else {
            throw ClaudeCodeError.config
        }
        top[key] = inner
        return try JSONSerialization.data(withJSONObject: top, options: [.prettyPrinted])
    }
}

public enum ClaudeCodeError: Error, Equatable {
    case notLoggedIn
    case unknownLogin(email: String?)
    case noSavedLogin
    case unconfirmed
    case keychain(OSStatus)
    case config
}
