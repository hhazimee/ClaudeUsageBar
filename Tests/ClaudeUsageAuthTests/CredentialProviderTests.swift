import Testing
import Foundation
@testable import ClaudeUsageAuth

/// Counts refreshes and holds them open, so a test can prove two callers
/// waiting at once produce one network call.
final class FakeRefresher: TokenRefreshing, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var calls = 0
    var result: Result<TokenResponse, OAuthError> = .failure(.malformedResponse)
    var holdUntilReleased = false
    private var pending: [(Result<TokenResponse, OAuthError>) -> Void] = []

    func refresh(refreshToken: String,
                 completion: @escaping (Result<TokenResponse, OAuthError>) -> Void) {
        lock.lock()
        calls += 1
        let hold = holdUntilReleased
        if hold { pending.append(completion) }
        let result = self.result
        lock.unlock()
        if !hold { completion(result) }
    }

    func release() {
        lock.lock()
        let waiting = pending
        pending = []
        let result = self.result
        lock.unlock()
        waiting.forEach { $0(result) }
    }
}

func makeTokenResponse(accessToken: String,
                       refreshToken: String? = "rt2",
                       expiresIn: Double? = 28800) throws -> TokenResponse {
    var fields: [String: Any] = ["access_token": accessToken, "token_type": "Bearer"]
    if let refreshToken = refreshToken { fields["refresh_token"] = refreshToken }
    if let expiresIn = expiresIn { fields["expires_in"] = expiresIn }
    let data = try JSONSerialization.data(withJSONObject: fields)
    return try JSONDecoder().decode(TokenResponse.self, from: data)
}

@Suite("Credential provider")
struct CredentialProviderTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func makeStore() -> CredentialStore {
        CredentialStore(service: "com.hazime.claudeusagemulti.tests.\(UUID().uuidString)")
    }

    func await_(_ provider: CredentialProvider, _ id: UUID) async -> CredentialOutcome {
        await withCheckedContinuation { continuation in
            provider.credential(for: id) { continuation.resume(returning: $0) }
        }
    }

    @Test func returnsAFreshTokenWithoutRefreshing() async throws {
        let store = makeStore(), id = UUID(), refresher = FakeRefresher()
        defer { store.delete(id) }
        try store.save(StoredCredential(oauth: OAuthTokens(
            accessToken: "fresh", refreshToken: "rt",
            expiresAt: now.addingTimeInterval(3600))), for: id)

        let provider = CredentialProvider(store: store, client: refresher, now: { self.now })
        #expect(await await_(provider, id) == .token("fresh"))
        #expect(refresher.calls == 0)
    }

    @Test func refreshesATokenInsideTheWindowAndPersistsTheResult() async throws {
        let store = makeStore(), id = UUID(), refresher = FakeRefresher()
        defer { store.delete(id) }
        refresher.result = .success(try makeTokenResponse(accessToken: "renewed"))
        try store.save(StoredCredential(oauth: OAuthTokens(
            accessToken: "stale", refreshToken: "rt",
            expiresAt: now.addingTimeInterval(60), email: "haz@example.com")), for: id)

        let provider = CredentialProvider(store: store, client: refresher, now: { self.now })
        #expect(await await_(provider, id) == .token("renewed"))
        #expect(refresher.calls == 1)

        let saved = store.load(id)?.oauth
        #expect(saved?.accessToken == "renewed")
        #expect(saved?.refreshToken == "rt2")
        // The email is not in the refresh response, so it has to survive the write.
        #expect(saved?.email == "haz@example.com")
    }

    @Test func keepsTheOldRefreshTokenWhenTheResponseOmitsOne() async throws {
        let store = makeStore(), id = UUID(), refresher = FakeRefresher()
        defer { store.delete(id) }
        refresher.result = .success(try makeTokenResponse(accessToken: "renewed", refreshToken: nil))
        try store.save(StoredCredential(oauth: OAuthTokens(
            accessToken: "stale", refreshToken: "rt",
            expiresAt: now.addingTimeInterval(60))), for: id)

        let provider = CredentialProvider(store: store, client: refresher, now: { self.now })
        _ = await await_(provider, id)
        #expect(store.load(id)?.oauth?.refreshToken == "rt")
    }

    @Test func twoCallersAtOnceCauseOneRefresh() async throws {
        let store = makeStore(), id = UUID(), refresher = FakeRefresher()
        defer { store.delete(id) }
        refresher.holdUntilReleased = true
        refresher.result = .success(try makeTokenResponse(accessToken: "renewed"))
        try store.save(StoredCredential(oauth: OAuthTokens(
            accessToken: "stale", refreshToken: "rt",
            expiresAt: now.addingTimeInterval(60))), for: id)

        let provider = CredentialProvider(store: store, client: refresher, now: { self.now })

        async let first = await_(provider, id)
        async let second = await_(provider, id)
        try await Task.sleep(nanoseconds: 200_000_000)
        refresher.release()

        #expect(await first == .token("renewed"))
        #expect(await second == .token("renewed"))
        #expect(refresher.calls == 1)
    }

    @Test func signingOutDuringARefreshIsNotReverted() async throws {
        let store = makeStore(), id = UUID(), refresher = FakeRefresher()
        defer { store.delete(id) }
        refresher.holdUntilReleased = true
        refresher.result = .success(try makeTokenResponse(accessToken: "renewed"))
        try store.save(StoredCredential(oauth: OAuthTokens(
            accessToken: "stale", refreshToken: "rt",
            expiresAt: now.addingTimeInterval(60))), for: id)

        let provider = CredentialProvider(store: store, client: refresher, now: { self.now })
        async let outcome = await_(provider, id)
        try await Task.sleep(nanoseconds: 200_000_000)
        provider.signOut(id)
        refresher.release()

        #expect(await outcome == .notConfigured)
        #expect(store.load(id)?.oauth == nil)
    }

    @Test func aRejectedRefreshFallsBackToTheCookie() async throws {
        let store = makeStore(), id = UUID(), refresher = FakeRefresher()
        defer { store.delete(id) }
        refresher.result = .failure(.server(status: 400, body: "invalid_grant"))
        try store.save(StoredCredential(
            oauth: OAuthTokens(accessToken: "stale", refreshToken: "rt",
                               expiresAt: now.addingTimeInterval(60)),
            cookie: "sk-ant-sid-example"), for: id)

        let provider = CredentialProvider(store: store, client: refresher, now: { self.now })
        #expect(await await_(provider, id) == .cookie("sk-ant-sid-example"))
    }

    @Test func aRejectedRefreshWithNoCookieAsksForANewSignIn() async throws {
        let store = makeStore(), id = UUID(), refresher = FakeRefresher()
        defer { store.delete(id) }
        refresher.result = .failure(.server(status: 400, body: "invalid_grant"))
        try store.save(StoredCredential(oauth: OAuthTokens(
            accessToken: "stale", refreshToken: "rt",
            expiresAt: now.addingTimeInterval(60))), for: id)

        let provider = CredentialProvider(store: store, client: refresher, now: { self.now })
        guard case .needsReauth = await await_(provider, id) else {
            Issue.record("expected needsReauth"); return
        }
    }

    @Test func networkTroubleIsNotTreatedAsARevokedGrant() async throws {
        let store = makeStore(), id = UUID(), refresher = FakeRefresher()
        defer { store.delete(id) }
        refresher.result = .failure(.transport("offline"))
        try store.save(StoredCredential(oauth: OAuthTokens(
            accessToken: "stale", refreshToken: "rt",
            expiresAt: now.addingTimeInterval(60))), for: id)

        let provider = CredentialProvider(store: store, client: refresher, now: { self.now })
        guard case .unavailable = await await_(provider, id) else {
            Issue.record("expected unavailable, not needsReauth"); return
        }
    }

    @Test func anAccountWithOnlyACookieUsesIt() async throws {
        let store = makeStore(), id = UUID()
        defer { store.delete(id) }
        try store.save(StoredCredential(cookie: "sk-ant-sid-example"), for: id)

        let provider = CredentialProvider(store: store, client: FakeRefresher(), now: { self.now })
        #expect(await await_(provider, id) == .cookie("sk-ant-sid-example"))
    }

    @Test func anAccountWithNothingConfiguredReturnsNotConfigured() async {
        let provider = CredentialProvider(store: makeStore(), client: FakeRefresher(), now: { self.now })
        #expect(await await_(provider, UUID()) == .notConfigured)
    }

    @Test func mutateEditsOneFieldAndLeavesTheRest() throws {
        let store = makeStore(), id = UUID()
        defer { store.delete(id) }
        try store.save(StoredCredential(oauth: OAuthTokens(accessToken: "at"),
                                        cookie: "first"), for: id)

        let provider = CredentialProvider(store: store, client: FakeRefresher(), now: { self.now })
        try provider.mutate(id) { $0.cookie = "second" }
        #expect(store.load(id)?.cookie == "second")
        #expect(store.load(id)?.oauth?.accessToken == "at")

        // Emptying the credential removes the item rather than leaving a husk.
        try provider.mutate(id) { $0.cookie = nil; $0.oauth = nil }
        #expect(store.load(id) == nil)
    }

    @Test func aCookieSavedDuringARefreshDoesNotLoseTheRenewedToken() async throws {
        let store = makeStore(), id = UUID(), refresher = FakeRefresher()
        defer { store.delete(id) }
        refresher.holdUntilReleased = true
        refresher.result = .success(try makeTokenResponse(accessToken: "renewed"))
        try store.save(StoredCredential(oauth: OAuthTokens(
            accessToken: "stale", refreshToken: "rt",
            expiresAt: now.addingTimeInterval(60))), for: id)

        let provider = CredentialProvider(store: store, client: refresher, now: { self.now })
        async let outcome = await_(provider, id)
        try await Task.sleep(nanoseconds: 200_000_000)
        try provider.mutate(id) { $0.cookie = "sk-ant-sid-example" }
        refresher.release()

        #expect(await outcome == .token("renewed"))
        // Both writes survive. A read-then-write across two queue hops would
        // have put back a snapshot taken before the refresh committed.
        #expect(store.load(id)?.oauth?.accessToken == "renewed")
        #expect(store.load(id)?.cookie == "sk-ant-sid-example")
    }

    @Test func signOutClearsTheTokensAndKeepsTheCookie() async throws {
        let store = makeStore(), id = UUID()
        defer { store.delete(id) }
        try store.save(StoredCredential(oauth: OAuthTokens(accessToken: "at"),
                                        cookie: "sk-ant-sid-example"), for: id)

        let provider = CredentialProvider(store: store, client: FakeRefresher(), now: { self.now })
        provider.signOut(id)
        #expect(store.load(id)?.oauth == nil)
        #expect(store.load(id)?.cookie == "sk-ant-sid-example")
    }
}
