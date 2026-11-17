# Claude Code Account Switch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One click in the popup or the menu bar right-click menu moves Claude Code to another of Haz's accounts, with no `/logout`.

**Architecture:** A testable `ClaudeCodeSwitcher` actor in `app/Auth/` reads and writes Claude Code's login (the Keychain item `Claude Code-credentials` and `oauthAccount` in `~/.claude.json`) through a `ClaudeCodeLive` protocol, and keeps each account's copy in its existing encrypted `StoredCredential`. `AccountsController` drives capture and switch; the popup card, menu bar pill and right-click menu show state.

**Tech Stack:** Swift 5.9, SwiftUI/AppKit, Security framework, swift-testing (`./test.sh`), app built with `app/build.sh`.

**Spec:** `docs/superpowers/specs/2026-11-17-claude-code-account-switch-design.md`

## Global Constraints

- macOS 12+, not sandboxed. New Auth code compiles into both the app (`app/build.sh` globs `Auth/*.swift`) and the `ClaudeUsageAuth` test target, so it may not reference anything in `ClaudeUsageBar.swift`.
- Keychain item: service `Claude Code-credentials`, account `NSUserName()`. Only `claudeAiOauth` is ever replaced; `mcpOAuth` and every other top-level key are written back byte-for-byte as decoded JSON values.
- `~/.claude.json`: only `oauthAccount` is replaced; all other keys preserved; atomic write.
- The app never creates the Keychain item. Missing item means Switch is disabled.
- Ownership check: `GET https://api.anthropic.com/api/oauth/profile` with `Authorization: Bearer <accessToken>`; response `account.uuid` must equal the target account's `accountUUID` (or, if the account has no `accountUUID`, the live `oauthAccount.accountUuid`).
- Copy (exact): badge `Claude Code`; button `Switch`; disabled hover `Log in to Claude Code as this account once`; unknown line `Claude Code is on <email>, which isn't in your accounts`; errors `A running session switched back`, `Couldn't confirm the current login. Try again.`, `Claude Code isn't logged in`.
- No em dashes or en dashes in code, comments, copy or commits.
- Do not reuse the name `switchTarget`: it already means the daily-budget suggestion. Use the `claudeCode` prefix.

## Review Focus

1. Claude Code renews its token between capture and switch: switch must re-read live state at click time, not use a cached read. (Task 3 test `switchRereadsLiveState`.)
2. `~/.claude.json` is large and has keys the app does not know: a merge must not drop or reorder-break them. (Task 1 test `configMergeKeepsOtherKeys`.)
3. Profile call fails (offline): capture saves nothing, switch aborts with `Couldn't confirm the current login. Try again.` (Task 3 tests `captureSkipsWhenProfileFails`, `switchAbortsWhenCurrentUnconfirmed`.)
4. Live tokens unchanged since the last capture: no network call. (Task 3 test `captureSkipsProfileWhenUnchanged`.)
5. Switching to the account already active: no-op, no writes. (Task 3 test `switchToActiveIsNoop`.)

---

### Task 1: Login model and JSON merges

**Files:**
- Create: `app/Auth/ClaudeCodeLogin.swift`
- Modify: `app/Auth/OAuthModels.swift` (`StoredCredential`)
- Test: `Tests/ClaudeUsageAuthTests/ClaudeCodeLoginTests.swift`

**Interfaces:**
- Produces:
  - `public struct ClaudeCodeLogin: Codable, Equatable { public var oauth: Data; public var account: Data }`: both are serialized JSON objects (`claudeAiOauth`, `oauthAccount`), stored raw so unknown fields survive.
  - `ClaudeCodeLogin.accessToken: String?`, `.refreshToken: String?`, `.accountUUID: String?`, `.email: String?` (parsed on demand).
  - `public enum ClaudeCodeJSON { static func login(keychain: Data, config: Data) -> ClaudeCodeLogin?; static func mergeKeychain(_ existing: Data, oauth: Data) throws -> Data; static func mergeConfig(_ existing: Data, account: Data) throws -> Data }`
  - `StoredCredential.claudeCode: ClaudeCodeLogin?` (optional, decodes absent). `isEmpty` is false when `claudeCode != nil`.

- [ ] **Step 1: Write failing tests**

```swift
@Test func loginReadsBothHalves()        // keychain {"claudeAiOauth":{"accessToken":"a","refreshToken":"r"},"mcpOAuth":{}} + config {"oauthAccount":{"emailAddress":"x@y.com","accountUuid":"u1"},"projects":{}} -> accessToken "a", refreshToken "r", email "x@y.com", accountUUID "u1"
@Test func loginNilWhenNoClaudeAiOauth() // keychain {"mcpOAuth":{}} -> nil
@Test func keychainMergeKeepsMcp()       // merge replaces claudeAiOauth, mcpOAuth and an extra key "other":1 decode equal to before
@Test func configMergeKeepsOtherKeys()   // 30 assorted keys incl nested objects/arrays/numbers/bools survive; only oauthAccount changes
@Test func credentialWithOnlyClaudeCodeIsNotEmpty()
@Test func oldCredentialJSONDecodes()    // {"cookie":"c"} decodes with claudeCode == nil
```

- [ ] **Step 2: Run** `./test.sh --filter ClaudeCodeLoginTests`. Expected: FAIL, types not defined.
- [ ] **Step 3: Implement** using `JSONSerialization` on `[String: Any]` (top level only; nested values pass through untouched). Compare in tests by decoding both sides with `JSONSerialization` and `NSDictionary.isEqual`.
- [ ] **Step 4: Run** `./test.sh`. Expected: all pass, including existing suites.
- [ ] **Step 5: Commit** `feat(claude-code): login model and JSON merges`

### Task 2: Live access and profile check

**Files:**
- Create: `app/Auth/ClaudeCodeLive.swift`
- Modify: `app/Auth/OAuthClient.swift` (add profile call)
- Test: `Tests/ClaudeUsageAuthTests/ClaudeCodeLiveTests.swift`

**Interfaces:**
- Produces:
  - `public protocol ClaudeCodeLive { func readKeychain() throws -> Data?; func writeKeychain(_ data: Data) throws; func readConfig() throws -> Data?; func writeConfig(_ data: Data) throws }`. `readKeychain` returns nil when the item does not exist. `writeKeychain` uses `SecItemUpdate` only and throws `ClaudeCodeError.notLoggedIn` on `errSecItemNotFound`.
  - `public final class SystemClaudeCodeLive: ClaudeCodeLive { init(configURL: URL = home/.claude.json, keychainAccount: String = NSUserName()) }`
  - `public enum ClaudeCodeError: Error, Equatable { case notLoggedIn, unknownLogin(email: String?), noSavedLogin, unconfirmed, keychain(OSStatus), config }`
  - `public protocol ProfileChecking { func accountUUID(accessToken: String) async -> String? }`; `OAuthClient` conforms. Request: GET `https://api.anthropic.com/api/oauth/profile`, headers `Authorization: Bearer`, `Accept: application/json`, `User-Agent: OAuthEndpoints.userAgent`, timeout 15s. Returns `account.uuid` on 200, nil otherwise.

- [ ] **Step 1: Write failing tests** for the config half of `SystemClaudeCodeLive` against a temp file: `readConfigMissingFileIsNil`, `writeConfigIsAtomicAndKeepsPermissions` (file mode 0600 before and after). Keychain half is verified by hand in Task 5.
- [ ] **Step 2: Run** `./test.sh --filter ClaudeCodeLiveTests`. Expected: FAIL.
- [ ] **Step 3: Implement.** Config write: `Data.write(to:options: .atomic)` then restore the original POSIX permissions.
- [ ] **Step 4: Run** `./test.sh`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(claude-code): read and write Claude Code's live login`

### Task 3: Switcher

**Files:**
- Create: `app/Auth/ClaudeCodeSwitcher.swift`
- Test: `Tests/ClaudeUsageAuthTests/ClaudeCodeSwitcherTests.swift` (with `FakeLive` holding keychain/config `Data?` and counting writes, and `FakeProfile` returning a set uuid or nil)

**Interfaces:**
- Consumes: Task 1 types, Task 2 protocols, `CredentialProvider.mutate/stored`.
- Produces:
  - `public struct ClaudeCodeIdentity: Equatable { let id: UUID; let accountUUID: String?; let email: String? }`
  - `public struct ClaudeCodeState: Equatable { var activeID: UUID?; var unknownEmail: String?; var loggedIn: Bool; var savedIDs: Set<UUID> }`
  - `public actor ClaudeCodeSwitcher { init(live: ClaudeCodeLive, profile: ProfileChecking, credentials: CredentialProvider) }`
    - `func capture(_ accounts: [ClaudeCodeIdentity]) async -> ClaudeCodeState`
    - `func switchTo(_ id: UUID, _ accounts: [ClaudeCodeIdentity]) async throws -> ClaudeCodeState`
    - `func verify(expected id: UUID, previous: UUID, _ accounts: [ClaudeCodeIdentity]) async -> Bool`: true when live is still `id`; when live moved back to `previous`, captures it and rewrites `id` once, returning true; returns false if that rewrite does not hold or it moves again. The controller calls it 60s after a switch, and a second time 60s after a `true` that involved a rewrite.

Matching: `accountUUID` first, then email, case-insensitive and trimmed.
Capture saves only when the live login differs from the saved copy and the profile uuid confirms the owner.
Switch order: re-read live, capture current (abort with `.unconfirmed` if changed and unconfirmed), merge target `oauth` into keychain, merge target `account` into config, return new state.

- [ ] **Step 1: Write failing tests**

```swift
@Test func captureMatchesByUUID()
@Test func captureMatchesByEmailWhenNoUUID()
@Test func captureUnknownEmailSavesNothing()      // state.unknownEmail == "z@z.com", no mutate
@Test func captureSkipsWhenProfileFails()
@Test func captureSkipsWhenProfileDisagrees()
@Test func captureSkipsProfileWhenUnchanged()     // FakeProfile.calls == 0 on second capture
@Test func captureNoKeychainItem()                // loggedIn == false
@Test func switchSavesCurrentThenWritesTarget()   // A's saved copy == live before; keychain claudeAiOauth == B's; mcpOAuth intact; config oauthAccount == B's
@Test func switchRereadsLiveState()               // live changes after capture, before switch: A's newest copy is the one saved
@Test func switchAbortsWhenCurrentUnconfirmed()   // throws .unconfirmed, zero writes
@Test func switchBlockedWhenUnknown()             // throws .unknownLogin, zero writes
@Test func switchBlockedWhenNotLoggedIn()         // throws .notLoggedIn
@Test func switchBlockedWithoutSavedTarget()      // throws .noSavedLogin
@Test func switchToActiveIsNoop()                 // zero writes
@Test func verifyReappliesOnce()
@Test func verifyFailsWhenItMovesBackAgain()
```

- [ ] **Step 2: Run** `./test.sh --filter ClaudeCodeSwitcherTests`. Expected: FAIL.
- [ ] **Step 3: Implement.** `CredentialProvider` calls use `queue.sync`; call them from the actor, never from inside a provider queue block.
- [ ] **Step 4: Run** `./test.sh`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(claude-code): capture and switch Claude Code logins`

### Task 4: Controller wiring

**Files:**
- Modify: `app/ClaudeUsageBar.swift` (`Account`, `AccountsController`, `AppDelegate` timers and popup open)

**Interfaces:**
- Consumes: Task 3.
- Produces on `AccountsController`:
  - `@Published private(set) var claudeCode = ClaudeCodeState(activeID: nil, unknownEmail: nil, loggedIn: false, savedIDs: [])`
  - `@Published private(set) var claudeCodeErrors: [UUID: String] = [:]`
  - `@Published private(set) var claudeCodeSwitching: UUID?`
  - `func syncClaudeCode()`: runs `capture` in a `Task`, publishes state on the main actor, sets `Account.hasClaudeCodeLogin` from `savedIDs` and persists if changed.
  - `func switchClaudeCode(to id: UUID)`: ignores clicks while `claudeCodeSwitching != nil`; maps `ClaudeCodeError` to the exact copy in Global Constraints; schedules `verify` at +60s and shows `A running session switched back` on failure.
  - `var claudeCodeSwitchable: Bool { claudeCode.loggedIn && claudeCode.unknownEmail == nil }`
- `Account.hasClaudeCodeLogin: Bool = false`, added to `CodingKeys` and decoded with `decodeIfPresent ?? false`.
- Triggers for `syncClaudeCode()`: end of `applicationDidFinishLaunching`, the 300s timer, and `openPopover()`.

- [ ] **Step 1: Implement** the above. Identities come from `managers.map { ClaudeCodeIdentity(id: $0.account.id, accountUUID: $0.account.accountUUID, email: $0.account.accountEmail) }`.
- [ ] **Step 2: Build** `cd app && ./build.sh`. Expected: build succeeds with no errors.
- [ ] **Step 3: Run** `./test.sh`. Expected: PASS.
- [ ] **Step 4: Commit** `feat(claude-code): wire capture and switch into the accounts controller`

### Task 5: UI

**Files:**
- Create: `app/Views/ClaudeCodeControl.swift`: `struct ClaudeCodeControl: View { let isActive: Bool; let canSwitch: Bool; let isSwitching: Bool; let action: () -> Void }`. Renders the `Claude Code` badge when active, else a small bordered `Switch` button, disabled with `.help("Log in to Claude Code as this account once")` when `!canSwitch`, a small `ProgressView` while switching.
- Modify: `app/ClaudeUsageBar.swift`:
  - `AccountUsageSection.header`: place `ClaudeCodeControl` before the percentage; the button must not toggle card expansion. Show `claudeCodeErrors[account.id]` as a caption under the header when present.
  - `UsageView`: one secondary caption line `Claude Code is on <email>, which isn't in your accounts` above the cards when `claudeCode.unknownEmail != nil`.
  - `MenuBarPill`: add `active: Bool`; when true, stroke the pill's rounded rect with `NSColor.labelColor.withAlphaComponent(0.7)`, line width 1.5. `renderStatusBar` sets it from `accounts.claudeCode.activeID`.
  - `handleClick` right-click menu: a disabled header item `Claude Code`, then one item per account `"<emoji> <displayName>"`, `.state = .on` for the active one, disabled when the account has no saved login or `!claudeCodeSwitchable`, action calls `switchClaudeCode(to:)` (`representedObject` = the UUID). Separator, then the existing items.
- Also call `refreshStatusBar()` when `claudeCode` changes.

- [ ] **Step 1: Implement** the above.
- [ ] **Step 2: Build** `cd app && ./build.sh`. Expected: succeeds.
- [ ] **Step 3: Manual check** (Haz's Mac, real login):
  1. Launch. macOS asks for the password for `Claude Code-credentials`: choose Always Allow.
  2. The account Claude Code is on shows the `Claude Code` badge and an outlined pill.
  3. In a terminal, `/login` as a second account (no `/logout`). Within 5 minutes or on popup open, that account shows the badge.
  4. Click `Switch` on the first account. Badge and outline move. `claude` in a running session answers as the first account within about 30 seconds. MCP servers still connected (`/mcp`).
  5. Switch back from the right-click menu.
- [ ] **Step 4: Commit** `feat(claude-code): switch accounts from the popup and menu bar`
