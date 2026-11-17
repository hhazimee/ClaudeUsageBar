import Foundation

/// What the switcher needs to know about an app account.
public struct ClaudeCodeIdentity: Equatable {
    public let id: UUID
    public let accountUUID: String?
    public let email: String?

    public init(id: UUID, accountUUID: String?, email: String?) {
        self.id = id
        self.accountUUID = accountUUID
        self.email = email
    }
}

/// Which account Claude Code is on, as last read.
public struct ClaudeCodeState: Equatable {
    public var activeID: UUID?
    /// Set when Claude Code is on a login that matches no app account.
    public var unknownEmail: String?
    public var loggedIn: Bool
    /// Accounts with a saved Claude Code login to switch to.
    public var savedIDs: Set<UUID>

    public init(activeID: UUID? = nil, unknownEmail: String? = nil,
                loggedIn: Bool = false, savedIDs: Set<UUID> = []) {
        self.activeID = activeID
        self.unknownEmail = unknownEmail
        self.loggedIn = loggedIn
        self.savedIDs = savedIDs
    }
}

public enum ClaudeCodeVerifyResult: Equatable {
    case held
    case reapplied
    case lost
}

/// Saves each account's Claude Code login and swaps them in on request.
///
/// Every save is confirmed against Anthropic first, because the Keychain token
/// carries no email and `~/.claude.json` can disagree with it. Saving one
/// account's tokens under another would destroy that account's login.
public actor ClaudeCodeSwitcher {
    private let live: ClaudeCodeLive
    private let profile: ProfileChecking
    private let credentials: CredentialProvider

    public init(live: ClaudeCodeLive, profile: ProfileChecking, credentials: CredentialProvider) {
        self.live = live
        self.profile = profile
        self.credentials = credentials
    }

    private struct Live {
        let keychain: Data?
        let config: Data?
        let login: ClaudeCodeLogin?
    }

    private func read() throws -> Live {
        let keychain = try live.readKeychain()
        let config = try live.readConfig()
        let login = keychain.flatMap { ClaudeCodeJSON.login(keychain: $0, config: config) }
        return Live(keychain: keychain, config: config, login: login)
    }

    /// Reads the live login and saves it to the matching account.
    public func capture(_ accounts: [ClaudeCodeIdentity]) async -> ClaudeCodeState {
        guard let current = try? read() else { return state(nil, accounts) }
        if let login = current.login, let id = match(login, accounts) {
            _ = await save(login, to: id, accounts)
        }
        return state(current, accounts)
    }

    public func switchTo(_ id: UUID, _ accounts: [ClaudeCodeIdentity]) async throws -> ClaudeCodeState {
        let current = try read()
        guard let keychain = current.keychain, let login = current.login else {
            throw ClaudeCodeError.notLoggedIn
        }
        guard let activeID = match(login, accounts) else {
            throw ClaudeCodeError.unknownLogin(email: login.email)
        }
        if activeID == id { return state(current, accounts) }
        guard let target = credentials.stored(for: id)?.claudeCode else {
            throw ClaudeCodeError.noSavedLogin
        }
        // Keep the current account's newest refresh token before replacing it.
        guard await save(login, to: activeID, accounts) else { throw ClaudeCodeError.unconfirmed }

        try write(target, keychain: keychain, config: current.config)
        return state(try read(), accounts)
    }

    /// Called after a switch. A running session can renew the old account and
    /// write it back; this puts the target back once.
    public func verify(expected id: UUID, previous: UUID, reapply: Bool,
                       _ accounts: [ClaudeCodeIdentity]) async -> ClaudeCodeVerifyResult {
        guard let current = try? read(), let keychain = current.keychain, let login = current.login,
              match(login, accounts) == previous else {
            // On the target, or moved elsewhere by hand: not ours to undo.
            return .held
        }
        guard reapply,
              let target = credentials.stored(for: id)?.claudeCode,
              await save(login, to: previous, accounts),
              (try? write(target, keychain: keychain, config: current.config)) != nil else {
            return .lost
        }
        return .reapplied
    }

    // MARK: - Helpers

    private func write(_ target: ClaudeCodeLogin, keychain: Data, config: Data?) throws {
        try live.writeKeychain(try ClaudeCodeJSON.mergeKeychain(keychain, oauth: target.oauth))
        guard let config else { return }
        do {
            try live.writeConfig(try ClaudeCodeJSON.mergeConfig(config, account: target.account))
        } catch {
            // Put the old tokens back so the Keychain and the config agree.
            try? live.writeKeychain(keychain)
            throw error
        }
    }

    /// True when the account now holds this login, confirmed or already saved.
    private func save(_ login: ClaudeCodeLogin, to id: UUID, _ accounts: [ClaudeCodeIdentity]) async -> Bool {
        if let saved = credentials.stored(for: id)?.claudeCode,
           Self.same(saved.oauth, login.oauth), Self.same(saved.account, login.account) {
            return true
        }
        guard let token = login.accessToken,
              let expected = accounts.first(where: { $0.id == id })?.accountUUID ?? login.accountUUID,
              await profile.accountUUID(accessToken: token) == expected else { return false }
        return (try? credentials.mutate(id) { $0.claudeCode = login }) != nil
    }

    private func match(_ login: ClaudeCodeLogin, _ accounts: [ClaudeCodeIdentity]) -> UUID? {
        if let uuid = login.accountUUID, let hit = accounts.first(where: { $0.accountUUID == uuid }) {
            return hit.id
        }
        guard let email = Self.normalized(login.email) else { return nil }
        return accounts.first { Self.normalized($0.email) == email }?.id
    }

    private func state(_ current: Live?, _ accounts: [ClaudeCodeIdentity]) -> ClaudeCodeState {
        let saved = Set(accounts.map(\.id).filter { credentials.stored(for: $0)?.claudeCode != nil })
        guard let login = current?.login else { return ClaudeCodeState(savedIDs: saved) }
        let active = match(login, accounts)
        return ClaudeCodeState(activeID: active,
                               unknownEmail: active == nil ? (Self.normalized(login.email) ?? "unknown") : nil,
                               loggedIn: true,
                               savedIDs: saved)
    }

    private static func normalized(_ email: String?) -> String? {
        let value = email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return (value?.isEmpty ?? true) ? nil : value
    }

    private static func same(_ a: Data, _ b: Data) -> Bool {
        guard let x = try? JSONSerialization.jsonObject(with: a) as? NSDictionary,
              let y = try? JSONSerialization.jsonObject(with: b) as? NSDictionary else { return a == b }
        return x == y
    }
}
