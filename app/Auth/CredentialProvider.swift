import Foundation

/// What an account should authenticate with right now.
public enum CredentialOutcome: Equatable {
    case token(String)
    /// OAuth is unusable but the account still has a session cookie.
    case cookie(String)
    /// The grant is gone. Only a new sign-in fixes it.
    case needsReauth(String)
    /// A temporary problem. Try again on the next cycle.
    case unavailable(String)
    /// Nothing configured for this account.
    case notConfigured
}

/// The single door between an account and its credential.
///
/// Refreshes are serialised per account. Two concurrent refreshes would each
/// rotate the refresh token, and the second write would persist a token the
/// server has already invalidated, costing the user a sign-in.
public final class CredentialProvider {
    private let store: CredentialStore
    private let client: TokenRefreshing
    private let now: () -> Date
    private let queue = DispatchQueue(label: "com.hazime.claudeusagemulti.credentials")
    private var waiting: [UUID: [(CredentialOutcome) -> Void]] = [:]

    public init(store: CredentialStore = CredentialStore(),
                client: TokenRefreshing = OAuthClient(),
                now: @escaping () -> Date = Date.init) {
        self.store = store
        self.client = client
        self.now = now
    }

    public func credential(for id: UUID, completion: @escaping (CredentialOutcome) -> Void) {
        queue.async {
            guard let stored = self.store.load(id), !stored.isEmpty else {
                DispatchQueue.main.async { completion(.notConfigured) }
                return
            }

            guard let oauth = stored.oauth else {
                let outcome = self.fallback(stored, reason: "no OAuth grant")
                DispatchQueue.main.async { completion(outcome) }
                return
            }

            if oauth.isFresh(at: self.now()) {
                DispatchQueue.main.async { completion(.token(oauth.accessToken)) }
                return
            }

            guard let refreshToken = oauth.refreshToken else {
                // A setup token that has expired cannot be renewed.
                let outcome = self.fallback(stored, reason: "token expired and has no refresh token")
                DispatchQueue.main.async { completion(outcome) }
                return
            }

            if self.waiting[id] != nil {
                self.waiting[id]?.append(completion)
                return
            }
            self.waiting[id] = [completion]

            self.client.refresh(refreshToken: refreshToken) { result in
                self.queue.async {
                    let outcome = self.apply(result,
                                             previousRefreshToken: refreshToken,
                                             id: id)
                    let waiters = self.waiting.removeValue(forKey: id) ?? []
                    DispatchQueue.main.async {
                        waiters.forEach { $0(outcome) }
                    }
                }
            }
        }
    }

    /// Direct reads and writes for the UI and for a cookie paste, which do not
    /// need a refresh and must not trigger one.
    ///
    /// These use `queue.sync`, so they are for callers outside the provider.
    /// Calling one from inside a queue block deadlocks.
    public func stored(for id: UUID) -> StoredCredential? {
        queue.sync { store.load(id) }
    }

    public func storedCookie(for id: UUID) -> String? {
        stored(for: id)?.cookie
    }

    public func save(_ credential: StoredCredential, for id: UUID) throws {
        try queue.sync { try store.save(credential, for: id) }
    }

    /// Drops the OAuth grant but keeps the cookie, so signing out of OAuth
    /// does not silently throw away the fallback the user pasted.
    public func signOut(_ id: UUID) {
        queue.sync {
            guard var stored = store.load(id) else { return }
            stored.oauth = nil
            if stored.isEmpty {
                store.delete(id)
            } else {
                try? store.save(stored, for: id)
            }
        }
    }

    private func apply(_ result: Result<TokenResponse, OAuthError>,
                       previousRefreshToken: String,
                       id: UUID) -> CredentialOutcome {
        // Re-read rather than trust the snapshot the refresh started with: a
        // sign-out or a cookie paste can land while the refresh is in
        // flight, and writing the renewed grant over that would silently
        // undo it.
        let current = store.load(id) ?? StoredCredential()

        switch result {
        case .success(let response):
            guard current.oauth != nil else {
                return fallback(current, reason: "signed out during refresh")
            }
            var renewed = response.tokens(now: now())
            // The refresh response rarely carries an account, so keep the
            // previous email unless this one actually supplied a new value.
            if renewed.email == nil { renewed.email = current.oauth?.email }
            if renewed.refreshToken == nil { renewed.refreshToken = previousRefreshToken }

            var updated = current
            updated.oauth = renewed
            do {
                // The write is the commit point. If it fails, the old token is
                // still what is stored, so nothing is stranded.
                try store.save(updated, for: id)
            } catch {
                return .unavailable("could not save refreshed tokens: \(error)")
            }
            return .token(renewed.accessToken)

        case .failure(let error) where error.isAuthFailure:
            return fallback(current, reason: "sign-in expired")

        case .failure(let error):
            return .unavailable("\(error)")
        }
    }

    private func fallback(_ stored: StoredCredential, reason: String) -> CredentialOutcome {
        if let cookie = stored.cookie, !cookie.isEmpty { return .cookie(cookie) }
        if stored.isEmpty { return .notConfigured }
        return .needsReauth(reason)
    }
}
