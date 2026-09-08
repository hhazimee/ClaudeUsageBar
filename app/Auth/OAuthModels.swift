import Foundation

/// One account's OAuth grant.
public struct OAuthTokens: Codable, Equatable {
    public var accessToken: String
    /// Absent for a long-lived token pasted from `claude setup-token`, which
    /// cannot be renewed and does not need to be.
    public var refreshToken: String?
    public var expiresAt: Date?
    public var scope: String?
    public var email: String?

    public init(accessToken: String,
                refreshToken: String? = nil,
                expiresAt: Date? = nil,
                scope: String? = nil,
                email: String? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scope = scope
        self.email = email
    }

    /// Usable without renewing first. A token expiring inside the window is
    /// treated as stale so a fetch never starts with seconds left on it.
    public func isFresh(at now: Date = Date(), window: TimeInterval = 300) -> Bool {
        guard let expiresAt = expiresAt else { return true }
        return expiresAt.timeIntervalSince(now) > window
    }
}

/// Everything secret about one account, kept in a single keychain item so a
/// sign-in, a refresh and a cookie paste are all one write.
public struct StoredCredential: Codable, Equatable {
    public var oauth: OAuthTokens?
    public var cookie: String?

    public init(oauth: OAuthTokens? = nil, cookie: String? = nil) {
        self.oauth = oauth
        self.cookie = cookie
    }

    public var isEmpty: Bool {
        oauth == nil && (cookie ?? "").isEmpty
    }
}

/// The token endpoint's response shape.
public struct TokenResponse: Decodable {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresIn: Double?
    public let scope: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case scope
    }

    public func tokens(now: Date = Date()) -> OAuthTokens {
        OAuthTokens(accessToken: accessToken,
                    refreshToken: refreshToken,
                    expiresAt: expiresIn.map { now.addingTimeInterval($0) },
                    scope: scope)
    }
}

public struct CallbackResult: Equatable {
    public let code: String
    public let state: String?

    public init(code: String, state: String?) {
        self.code = code
        self.state = state
    }
}

/// Reads a code out of whatever the user pastes, or out of the loopback
/// request line. Three shapes reach here: a bare code, `code#state` as the
/// paste-back page prints it, and a full redirect URL or path.
public enum CallbackParser {
    public static func parse(_ raw: String) -> CallbackResult? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let components = URLComponents(string: trimmed),
           components.scheme != nil || trimmed.hasPrefix("/"),
           let items = components.queryItems {
            guard let code = items.first(where: { $0.name == "code" })?.value,
                  !code.isEmpty else { return nil }
            return CallbackResult(code: code,
                                  state: items.first(where: { $0.name == "state" })?.value)
        }

        let parts = trimmed.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let code = String(parts[0])
        guard !code.isEmpty else { return nil }
        let state = parts.count > 1 ? String(parts[1]) : nil
        return CallbackResult(code: code, state: (state?.isEmpty ?? true) ? nil : state)
    }
}
