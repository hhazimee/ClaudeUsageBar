import Testing
import Foundation
@testable import ClaudeUsageAuth

final class FakeLive: ClaudeCodeLive, @unchecked Sendable {
    var keychain: Data?
    var config: Data?
    var writes = 0
    func readKeychain() throws -> Data? { keychain }
    func writeKeychain(_ data: Data) throws {
        guard keychain != nil else { throw ClaudeCodeError.notLoggedIn }
        writes += 1
        keychain = data
    }
    func readConfig() throws -> Data? { config }
    func writeConfig(_ data: Data) throws { writes += 1; config = data }
}

final class FakeProfile: ProfileChecking, @unchecked Sendable {
    /// Access token to account uuid. A missing token means the call failed.
    var owners: [String: String] = [:]
    var calls = 0
    /// Runs while the call is in flight, to simulate Claude Code acting meanwhile.
    var during: (() -> Void)?
    func accountUUID(accessToken: String) async -> String? {
        calls += 1
        during?()
        during = nil
        return owners[accessToken]
    }
}

@Suite("Claude Code switcher")
struct ClaudeCodeSwitcherTests {
    let a = ClaudeCodeIdentity(id: UUID(), accountUUID: "uA", email: "a@x.com")
    let b = ClaudeCodeIdentity(id: UUID(), accountUUID: "uB", email: "b@x.com")
    var accounts: [ClaudeCodeIdentity] { [a, b] }

    let live = FakeLive()
    let profile = FakeProfile()
    let credentials = CredentialProvider(store: CredentialStore(
        directory: FileManager.default.temporaryDirectory.appendingPathComponent("cc-\(UUID().uuidString)"),
        legacyKeychainService: nil))

    var switcher: ClaudeCodeSwitcher {
        ClaudeCodeSwitcher(live: live, profile: profile, credentials: credentials)
    }

    func oauth(_ token: String) -> [String: Any] { ["accessToken": token, "refreshToken": "r-\(token)"] }
    func account(_ uuid: String?, _ email: String) -> [String: Any] {
        var fields: [String: Any] = ["emailAddress": email]
        if let uuid { fields["accountUuid"] = uuid }
        return fields
    }

    /// Puts Claude Code on a login, keeping MCP tokens and other config keys around.
    func logIn(token: String, uuid: String?, email: String) {
        live.keychain = json(["claudeAiOauth": oauth(token), "mcpOAuth": ["srv": ["accessToken": "m"]]])
        live.config = json(["oauthAccount": account(uuid, email), "projects": ["p": 1]])
    }

    func save(_ id: UUID, token: String, uuid: String, email: String) throws {
        let login = ClaudeCodeLogin(oauth: json(oauth(token)), account: json(account(uuid, email)))
        try credentials.mutate(id) { $0.claudeCode = login }
    }

    func savedToken(_ id: UUID) -> String? { credentials.stored(for: id)?.claudeCode?.accessToken }
    var liveToken: String? { ClaudeCodeJSON.login(keychain: live.keychain!, config: live.config)?.accessToken }

    // MARK: Capture

    @Test func captureMatchesByUUID() async {
        logIn(token: "a1", uuid: "uA", email: "other@x.com")
        profile.owners["a1"] = "uA"
        let state = await switcher.capture(accounts)
        #expect(state.activeID == a.id)
        #expect(savedToken(a.id) == "a1")
        #expect(state.savedIDs == [a.id])
    }

    @Test func captureMatchesByEmailWhenNoUUID() async {
        logIn(token: "a1", uuid: nil, email: " A@X.com ")
        profile.owners["a1"] = "uA"
        let state = await switcher.capture(accounts)
        #expect(state.activeID == a.id)
        #expect(savedToken(a.id) == "a1")
    }

    @Test func captureUnknownEmailSavesNothing() async {
        logIn(token: "z1", uuid: "uZ", email: "z@z.com")
        let state = await switcher.capture(accounts)
        #expect(state.activeID == nil)
        #expect(state.unknownEmail == "z@z.com")
        #expect(state.savedIDs.isEmpty)
        #expect(profile.calls == 0)
    }

    @Test func captureSkipsWhenProfileFails() async {
        logIn(token: "a1", uuid: "uA", email: "a@x.com")
        let state = await switcher.capture(accounts)
        #expect(state.activeID == a.id)
        #expect(savedToken(a.id) == nil)
    }

    @Test func captureSkipsWhenProfileDisagrees() async {
        logIn(token: "a1", uuid: "uA", email: "a@x.com")
        profile.owners["a1"] = "uB"
        _ = await switcher.capture(accounts)
        #expect(savedToken(a.id) == nil)
        #expect(savedToken(b.id) == nil)
    }

    @Test func captureSkipsProfileWhenUnchanged() async {
        logIn(token: "a1", uuid: "uA", email: "a@x.com")
        profile.owners["a1"] = "uA"
        _ = await switcher.capture(accounts)
        _ = await switcher.capture(accounts)
        #expect(profile.calls == 1)
    }

    @Test func captureNoKeychainItem() async {
        let state = await switcher.capture(accounts)
        #expect(!state.loggedIn)
        #expect(state.activeID == nil)
    }

    // MARK: Switch

    @Test func switchSavesCurrentThenWritesTarget() async throws {
        logIn(token: "a2", uuid: "uA", email: "a@x.com")
        try save(a.id, token: "a1", uuid: "uA", email: "a@x.com")
        try save(b.id, token: "b1", uuid: "uB", email: "b@x.com")
        profile.owners["a2"] = "uA"

        let state = try await switcher.switchTo(b.id, accounts)

        #expect(savedToken(a.id) == "a2")
        #expect(liveToken == "b1")
        #expect(state.activeID == b.id)
        let keychain = dict(live.keychain!)
        #expect((keychain["mcpOAuth"] as? NSDictionary) == ["srv": ["accessToken": "m"]])
        let config = dict(live.config!)
        #expect((config["oauthAccount"] as? NSDictionary)?["emailAddress"] as? String == "b@x.com")
        #expect((config["projects"] as? NSDictionary) == ["p": 1])
    }

    @Test func switchRereadsLiveState() async throws {
        logIn(token: "a1", uuid: "uA", email: "a@x.com")
        profile.owners["a1"] = "uA"
        let s = switcher
        _ = await s.capture(accounts)
        try save(b.id, token: "b1", uuid: "uB", email: "b@x.com")
        logIn(token: "a2", uuid: "uA", email: "a@x.com")   // Claude Code renewed in between
        profile.owners["a2"] = "uA"

        _ = try await s.switchTo(b.id, accounts)
        #expect(savedToken(a.id) == "a2")
    }

    @Test func switchAbortsWhenCurrentUnconfirmed() async throws {
        logIn(token: "a2", uuid: "uA", email: "a@x.com")
        try save(b.id, token: "b1", uuid: "uB", email: "b@x.com")
        await #expect(throws: ClaudeCodeError.unconfirmed) {
            try await switcher.switchTo(b.id, accounts)
        }
        #expect(live.writes == 0)
    }

    @Test func switchBlockedWhenUnknown() async throws {
        logIn(token: "z1", uuid: "uZ", email: "z@z.com")
        try save(b.id, token: "b1", uuid: "uB", email: "b@x.com")
        await #expect(throws: ClaudeCodeError.unknownLogin(email: "z@z.com")) {
            try await switcher.switchTo(b.id, accounts)
        }
        #expect(live.writes == 0)
    }

    @Test func switchBlockedWhenNotLoggedIn() async throws {
        try save(b.id, token: "b1", uuid: "uB", email: "b@x.com")
        await #expect(throws: ClaudeCodeError.notLoggedIn) {
            try await switcher.switchTo(b.id, accounts)
        }
    }

    @Test func switchBlockedWithoutSavedTarget() async throws {
        logIn(token: "a1", uuid: "uA", email: "a@x.com")
        profile.owners["a1"] = "uA"
        await #expect(throws: ClaudeCodeError.noSavedLogin) {
            try await switcher.switchTo(b.id, accounts)
        }
        #expect(live.writes == 0)
    }

    @Test func switchToActiveIsNoop() async throws {
        logIn(token: "a1", uuid: "uA", email: "a@x.com")
        try save(a.id, token: "a1", uuid: "uA", email: "a@x.com")
        let state = try await switcher.switchTo(a.id, accounts)
        #expect(state.activeID == a.id)
        #expect(live.writes == 0)
    }

    @Test func switchedKeychainIsSingleLine() async throws {
        logIn(token: "a1", uuid: "uA", email: "a@x.com")
        try save(a.id, token: "a1", uuid: "uA", email: "a@x.com")
        try save(b.id, token: "b1", uuid: "uB", email: "b@x.com")
        _ = try await switcher.switchTo(b.id, accounts)
        #expect(!live.keychain!.contains(0x0A))
    }

    @Test func switchAbortsWhenRenewedDuringCheck() async throws {
        logIn(token: "a1", uuid: "uA", email: "a@x.com")
        try save(b.id, token: "b1", uuid: "uB", email: "b@x.com")
        profile.owners["a1"] = "uA"
        profile.during = { self.logIn(token: "a2", uuid: "uA", email: "a@x.com") }
        await #expect(throws: ClaudeCodeError.unconfirmed) {
            try await switcher.switchTo(b.id, accounts)
        }
        #expect(liveToken == "a2")
        #expect(savedToken(a.id) == nil)
    }

    @Test func switchMergesIntoFreshMcpTokens() async throws {
        logIn(token: "a1", uuid: "uA", email: "a@x.com")
        try save(b.id, token: "b1", uuid: "uB", email: "b@x.com")
        profile.owners["a1"] = "uA"
        profile.during = {
            // Claude Code renews an MCP token but not the Claude login.
            self.live.keychain = json(["claudeAiOauth": self.oauth("a1"), "mcpOAuth": ["srv": ["accessToken": "m2"]]])
        }
        _ = try await switcher.switchTo(b.id, accounts)
        #expect((dict(live.keychain!)["mcpOAuth"] as? NSDictionary) == ["srv": ["accessToken": "m2"]])
    }

    @Test func captureDoesNotSaveLoginReplacedDuringCheck() async throws {
        logIn(token: "a1", uuid: "uA", email: "a@x.com")
        try save(a.id, token: "a2", uuid: "uA", email: "a@x.com")
        profile.owners["a1"] = "uA"
        profile.during = { self.logIn(token: "b1", uuid: "uB", email: "b@x.com") }
        let state = await switcher.capture(accounts)
        #expect(savedToken(a.id) == "a2")
        #expect(state.activeID == b.id)
    }

    // MARK: Verify

    @Test func verifyReappliesOnce() async throws {
        logIn(token: "a3", uuid: "uA", email: "a@x.com")   // a session wrote A back
        try save(b.id, token: "b1", uuid: "uB", email: "b@x.com")
        profile.owners["a3"] = "uA"

        let result = await switcher.verify(expected: b.id, previous: a.id, reapply: true, accounts)

        #expect(result == .reapplied)
        #expect(liveToken == "b1")
        #expect(savedToken(a.id) == "a3")
    }

    @Test func verifyFailsWhenItMovesBackAgain() async throws {
        logIn(token: "a3", uuid: "uA", email: "a@x.com")
        try save(b.id, token: "b1", uuid: "uB", email: "b@x.com")
        profile.owners["a3"] = "uA"

        let result = await switcher.verify(expected: b.id, previous: a.id, reapply: false, accounts)

        #expect(result == .lost)
        #expect(liveToken == "a3")
    }

    @Test func verifyHeldWhenStillOnTarget() async throws {
        logIn(token: "b1", uuid: "uB", email: "b@x.com")
        let result = await switcher.verify(expected: b.id, previous: a.id, reapply: true, accounts)
        #expect(result == .held)
    }
}
