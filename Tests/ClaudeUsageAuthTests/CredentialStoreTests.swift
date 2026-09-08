import Testing
import Foundation
@testable import ClaudeUsageAuth

@Suite("Credential store")
struct CredentialStoreTests {
    /// A service name unique to this run, so a test never reads, writes or
    /// deletes the real app's items.
    func makeStore() -> CredentialStore {
        CredentialStore(service: "com.hazime.claudeusagemulti.tests.\(UUID().uuidString)")
    }

    @Test func readingAnUnknownAccountReturnsNil() {
        #expect(makeStore().load(UUID()) == nil)
    }

    @Test func savesAndReadsBackTheSameCredential() throws {
        let store = makeStore()
        let id = UUID()
        defer { store.delete(id) }

        let expiry = Date(timeIntervalSince1970: 1_800_000_000)
        let credential = StoredCredential(
            oauth: OAuthTokens(accessToken: "at", refreshToken: "rt",
                               expiresAt: expiry, scope: "user:profile",
                               email: "haz@example.com"),
            cookie: "sk-ant-sid-example")

        try store.save(credential, for: id)
        #expect(store.load(id) == credential)
    }

    @Test func savingTwiceReplacesRatherThanDuplicates() throws {
        let store = makeStore()
        let id = UUID()
        defer { store.delete(id) }

        try store.save(StoredCredential(oauth: OAuthTokens(accessToken: "first")), for: id)
        try store.save(StoredCredential(oauth: OAuthTokens(accessToken: "second")), for: id)
        #expect(store.load(id)?.oauth?.accessToken == "second")
    }

    @Test func deleteRemovesTheItem() throws {
        let store = makeStore()
        let id = UUID()
        try store.save(StoredCredential(cookie: "c"), for: id)
        store.delete(id)
        #expect(store.load(id) == nil)
    }

    @Test func accountsDoNotSeeEachOthersCredentials() throws {
        let store = makeStore()
        let a = UUID(), b = UUID()
        defer { store.delete(a); store.delete(b) }

        try store.save(StoredCredential(cookie: "cookie-a"), for: a)
        try store.save(StoredCredential(cookie: "cookie-b"), for: b)
        #expect(store.load(a)?.cookie == "cookie-a")
        #expect(store.load(b)?.cookie == "cookie-b")
    }
}
