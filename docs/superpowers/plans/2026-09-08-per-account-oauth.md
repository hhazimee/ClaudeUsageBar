# Per-account OAuth Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every account signs in through the browser and holds its own OAuth access and refresh tokens in the app's own keychain items, so nothing prompts for a password and every account works independently.

**Architecture:** A new `app/Auth/` directory holds four AppKit-free files compiled into both the app and a SwiftPM test target. `CredentialProvider` sits between accounts and the network, returning a valid access token and refreshing under a 5 minute window with one refresh in flight per account. Claude Code keychain reading is deleted; the session cookie path stays as an unadvertised fallback.

**Tech Stack:** Swift 5.9, SwiftUI, AppKit, Network framework (`NWListener`), Security framework (keychain), CryptoKit (SHA256 for PKCE), swift-testing.

**Spec:** `docs/superpowers/specs/2026-09-08-per-account-oauth-design.md`

## Global Constraints

- Deployment target is macOS 12.0, both arm64 and x86_64. Nothing in `app/Auth/` may require a later OS.
- No file in `app/Auth/` imports AppKit, SwiftUI, or Cocoa. The test target compiles those files unchanged.
- OAuth client id: `9d1c250a-e61b-44d9-88ed-5944d1962f5e`
- Authorize: `https://claude.com/cai/oauth/authorize`
- Token exchange and refresh: `https://platform.claude.com/v1/oauth/token`
- Paste-back redirect: `https://platform.claude.com/oauth/code/callback`
- Scopes: `user:profile user:inference` (Task 1 may widen these; if it does, update every later task)
- Keychain service: `com.hazime.claudeusagemulti.oauth`
- Refresh window: 5 minutes (300 seconds) before expiry
- **No em dashes anywhere**, including code comments, UI copy and commit messages. Use a comma, a colon or a full stop. Write ranges as "2 to 3".
- Commit messages follow Conventional Commits.

**Deviation from the spec:** the spec names four files in `app/Auth/`. This
plan writes six. `PKCE.swift` and `OAuthModels.swift` are split out of
`OAuthClient.swift` so the pure logic can be tested without a network stub,
and `TokenStore.swift` is named `CredentialStore.swift` because it holds the
session cookie as well as the tokens. Responsibilities are unchanged.
- UI copy carries no explanatory captions under controls and no sentences that restate a label.

---

### Task 1: Probe the two live unknowns

A throwaway spike. Its output is an answer, not code that ships. It runs before anything else because both answers change later tasks.

**Question 1:** does the authorize page accept an arbitrary loopback port, or only Claude Code's own?
**Question 2:** does `/api/oauth/usage` accept a token scoped `user:profile user:inference`?

**Files:**
- Create: `scripts/oauth-probe.sh` (throwaway, deleted in Step 6)

- [ ] **Step 1: Write the probe script**

```bash
#!/bin/bash
# Throwaway. Answers two questions before the real work starts:
#   1. does the authorize page accept an arbitrary loopback port
#   2. does /api/oauth/usage accept user:profile user:inference
set -euo pipefail

CLIENT_ID=9d1c250a-e61b-44d9-88ed-5944d1962f5e
PORT="${PORT:-51703}"
REDIRECT="http://localhost:$PORT/callback"
SCOPES="user:profile user:inference"

VERIFIER=$(openssl rand -base64 60 | tr -d '\n=+/' | cut -c1-64)
CHALLENGE=$(printf '%s' "$VERIFIER" \
  | openssl dgst -sha256 -binary | base64 | tr '+/' '-_' | tr -d '=')
STATE=$(openssl rand -hex 12)

urlenc() { python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=''))" "$1"; }

URL="https://claude.com/cai/oauth/authorize?client_id=$CLIENT_ID&response_type=code"
URL="$URL&redirect_uri=$(urlenc "$REDIRECT")&scope=$(urlenc "$SCOPES")"
URL="$URL&code_challenge=$CHALLENGE&code_challenge_method=S256&state=$STATE"

echo "Listening on $PORT. Opening browser."
echo
echo "$URL"
echo

REQ=$( { echo "$URL" | xargs open; \
  printf 'HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nConnection: close\r\n\r\n<h2>Done. Close this tab.</h2>' \
  | nc -l "$PORT"; } | head -1 )

echo "Request line: $REQ"
CODE=$(printf '%s' "$REQ" | sed -n 's/.*[?&]code=\([^&ist ]*\).*/\1/p')
GOT_STATE=$(printf '%s' "$REQ" | sed -n 's/.*[?&]state=\([^& ]*\).*/\1/p')

[ -n "$CODE" ] || { echo "FAIL: no code came back. Loopback port rejected?"; exit 1; }
[ "$GOT_STATE" = "$STATE" ] || { echo "FAIL: state mismatch"; exit 1; }
echo "PASS: arbitrary loopback port $PORT accepted."

TOKENS=$(curl -s -X POST https://platform.claude.com/v1/oauth/token \
  -H 'content-type: application/json' \
  -d "{\"grant_type\":\"authorization_code\",\"code\":\"$CODE\",\"client_id\":\"$CLIENT_ID\",\"redirect_uri\":\"$REDIRECT\",\"code_verifier\":\"$VERIFIER\",\"state\":\"$STATE\"}")

echo "Token response:"; printf '%s\n' "$TOKENS" | python3 -m json.tool | sed 's/\("[a-z_]*token"\): "[^"]*"/\1: "REDACTED"/'

ACCESS=$(printf '%s' "$TOKENS" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("access_token",""))')
[ -n "$ACCESS" ] || { echo "FAIL: no access_token"; exit 1; }

echo; echo "Usage endpoint:"
curl -s -o /tmp/usage.json -w 'status=%{http_code}\n' \
  https://api.anthropic.com/api/oauth/usage \
  -H "authorization: Bearer $ACCESS" -H 'anthropic-beta: oauth-2025-04-20'
head -c 600 /tmp/usage.json; echo

echo; echo "Profile endpoint:"
curl -s -o /dev/null -w 'status=%{http_code}\n' \
  https://api.anthropic.com/api/oauth/profile \
  -H "authorization: Bearer $ACCESS" -H 'anthropic-beta: oauth-2025-04-20'
```

- [ ] **Step 2: Run it**

Run: `chmod +x scripts/oauth-probe.sh && ./scripts/oauth-probe.sh`

The browser opens. Sign in to any Claude account. Expected: `PASS: arbitrary loopback port` then a token response then `status=200` from both endpoints.

- [ ] **Step 3: Record what happened**

Write the answers into the spec's final section, replacing "Verified live before the bulk of the work" with what was observed. Both answers are needed by later tasks:

- If the loopback port was rejected, Task 6 binds a fixed port (`51703`) instead of an ephemeral one, and Task 6's test uses that port.
- If `/api/oauth/usage` returned 401 or 403, widen `OAuthEndpoints.scopes` in Task 4 to `user:profile user:inference user:sessions:claude_code` and rerun this probe before continuing.
- Note whether the endpoints needed the `anthropic-beta: oauth-2025-04-20` header. If they did, Task 4's request builder sets it; if a 200 came back without it, leave it off.

- [ ] **Step 4: Revoke the probe's authorization**

This spike created a real authorization on a real account. Sign in to claude.ai, open settings, and revoke it, so a throwaway token is not left live.

- [ ] **Step 5: Delete the script and commit the spec update**

```bash
rm scripts/oauth-probe.sh
git add docs/superpowers/specs/2026-09-08-per-account-oauth-design.md
git commit -m "docs: record live OAuth probe results in the spec"
```

---

### Task 2: Test target and PKCE

**Files:**
- Create: `Package.swift`
- Create: `app/Auth/PKCE.swift`
- Create: `Tests/ClaudeUsageAuthTests/PKCETests.swift`
- Create: `test.sh`
- Modify: `app/build.sh` (both `swiftc` invocations)

**Interfaces:**
- Consumes: nothing
- Produces:
  - `enum PKCE`
  - `static func PKCE.base64URL(_ data: Data) -> String`
  - `static func PKCE.challenge(for verifier: String) -> String`
  - `static func PKCE.randomVerifier() -> String`

- [ ] **Step 1: Create the package manifest**

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClaudeUsageAuth",
    platforms: [.macOS(.v12)],
    targets: [
        // The app compiles these same files through build.sh. The library
        // target exists so they can be tested without launching a menu bar app.
        .target(name: "ClaudeUsageAuth", path: "app/Auth"),
        .testTarget(name: "ClaudeUsageAuthTests", dependencies: ["ClaudeUsageAuth"])
    ]
)
```

- [ ] **Step 2: Write the failing test**

`Tests/ClaudeUsageAuthTests/PKCETests.swift`:

```swift
import Testing
import Foundation
@testable import ClaudeUsageAuth

@Suite("PKCE")
struct PKCETests {
    // RFC 7636 appendix B.
    @Test func challengeMatchesTheRFCVector() {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        #expect(PKCE.challenge(for: verifier) == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test func base64URLHasNoPaddingOrURLUnsafeCharacters() {
        let encoded = PKCE.base64URL(Data([251, 255, 190, 0]))
        #expect(!encoded.contains("="))
        #expect(!encoded.contains("+"))
        #expect(!encoded.contains("/"))
    }

    @Test func verifiersAreLongAndDistinct() {
        let a = PKCE.randomVerifier()
        let b = PKCE.randomVerifier()
        #expect(a != b)
        #expect(a.count >= 43)   // RFC 7636 minimum
        #expect(a.count <= 128)  // RFC 7636 maximum
    }
}
```

- [ ] **Step 3: Run it to verify it fails**

Run: `swift test --filter PKCE`
Expected: FAIL, cannot find `PKCE` in scope.

- [ ] **Step 4: Write the implementation**

`app/Auth/PKCE.swift`:

```swift
import Foundation
import CryptoKit
import Security

/// PKCE, RFC 7636. The OAuth client is public, so the verifier is what proves
/// the app that redeems the code is the one that asked for it.
public enum PKCE {
    public static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    /// 32 random bytes, which base64url-encodes to 43 characters.
    public static func randomVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
        return base64URL(Data(bytes))
    }

    /// 16 random bytes for the `state` parameter, which guards the callback
    /// against a code from a different sign-in being accepted.
    public static func randomState() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
        return base64URL(Data(bytes))
    }
}
```

- [ ] **Step 5: Run it to verify it passes**

Run: `swift test --filter PKCE`
Expected: PASS, 3 tests.

- [ ] **Step 6: Create test.sh**

```bash
#!/bin/bash
# Runs the auth library's tests. The app itself still builds with app/build.sh.
set -euo pipefail
cd "$(dirname "$0")"
swift test "$@"
```

Run: `chmod +x test.sh && ./test.sh`
Expected: PASS.

- [ ] **Step 7: Add the Auth files to the app build**

In `app/build.sh`, both `swiftc` invocations currently read:

```bash
    ClaudeUsageBar.swift \
```

Change both to:

```bash
    ClaudeUsageBar.swift \
    Auth/*.swift \
```

- [ ] **Step 8: Verify the app still builds**

Run: `cd app && INSTALL=0 ./build.sh`
Expected: `Build successful!`

- [ ] **Step 9: Commit**

```bash
git add Package.swift test.sh app/Auth/PKCE.swift Tests app/build.sh
git commit -m "test: add swift-testing target and PKCE helpers"
```

---

### Task 3: Token models and callback parsing

**Files:**
- Create: `app/Auth/OAuthModels.swift`
- Create: `Tests/ClaudeUsageAuthTests/OAuthModelsTests.swift`

**Interfaces:**
- Consumes: nothing
- Produces:
  - `struct OAuthTokens: Codable, Equatable` with `accessToken: String`, `refreshToken: String?`, `expiresAt: Date?`, `scope: String?`, `email: String?`
  - `func OAuthTokens.isFresh(at: Date, window: TimeInterval) -> Bool`
  - `struct StoredCredential: Codable, Equatable` with `oauth: OAuthTokens?`, `cookie: String?`
  - `struct TokenResponse: Decodable` with `func tokens(now: Date) -> OAuthTokens`
  - `struct CallbackResult: Equatable` with `code: String`, `state: String?`
  - `static func CallbackParser.parse(_ raw: String) -> CallbackResult?`

- [ ] **Step 1: Write the failing tests**

`Tests/ClaudeUsageAuthTests/OAuthModelsTests.swift`:

```swift
import Testing
import Foundation
@testable import ClaudeUsageAuth

@Suite("Token freshness")
struct FreshnessTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func tokens(expiringIn seconds: TimeInterval?) -> OAuthTokens {
        OAuthTokens(accessToken: "a",
                    refreshToken: "r",
                    expiresAt: seconds.map { now.addingTimeInterval($0) },
                    scope: nil,
                    email: nil)
    }

    @Test func aTokenWithNoExpiryIsAlwaysFresh() {
        // Setup tokens pasted from `claude setup-token` carry no expiry.
        #expect(tokens(expiringIn: nil).isFresh(at: now, window: 300))
    }

    @Test func justOutsideTheWindowIsFresh() {
        #expect(tokens(expiringIn: 301).isFresh(at: now, window: 300))
    }

    @Test func exactlyOnTheWindowIsNotFresh() {
        #expect(!tokens(expiringIn: 300).isFresh(at: now, window: 300))
    }

    @Test func alreadyExpiredIsNotFresh() {
        #expect(!tokens(expiringIn: -1).isFresh(at: now, window: 300))
    }
}

@Suite("Token response decoding")
struct TokenResponseTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func decode(_ json: String) throws -> TokenResponse {
        try JSONDecoder().decode(TokenResponse.self, from: Data(json.utf8))
    }

    @Test func decodesAFullResponse() throws {
        let response = try decode("""
        {"access_token":"at","refresh_token":"rt","expires_in":28800,
         "token_type":"Bearer","scope":"user:profile user:inference"}
        """)
        let tokens = response.tokens(now: now)
        #expect(tokens.accessToken == "at")
        #expect(tokens.refreshToken == "rt")
        #expect(tokens.expiresAt == now.addingTimeInterval(28800))
        #expect(tokens.scope == "user:profile user:inference")
    }

    @Test func decodesAResponseWithNoRefreshToken() throws {
        let response = try decode(#"{"access_token":"at","token_type":"Bearer"}"#)
        let tokens = response.tokens(now: now)
        #expect(tokens.refreshToken == nil)
        #expect(tokens.expiresAt == nil)
    }
}

@Suite("Callback parsing")
struct CallbackParserTests {
    @Test func parsesABareCode() {
        #expect(CallbackParser.parse("abc123") == CallbackResult(code: "abc123", state: nil))
    }

    @Test func parsesCodeHashState() {
        #expect(CallbackParser.parse("abc123#st8") == CallbackResult(code: "abc123", state: "st8"))
    }

    @Test func parsesAFullRedirectURL() {
        let raw = "http://localhost:51703/callback?code=abc123&state=st8"
        #expect(CallbackParser.parse(raw) == CallbackResult(code: "abc123", state: "st8"))
    }

    @Test func trimsSurroundingWhitespace() {
        #expect(CallbackParser.parse("  abc123#st8 \n") == CallbackResult(code: "abc123", state: "st8"))
    }

    @Test func rejectsEmptyInput() {
        #expect(CallbackParser.parse("   ") == nil)
    }

    @Test func rejectsAURLCarryingAnError() {
        let raw = "http://localhost:51703/callback?error=access_denied"
        #expect(CallbackParser.parse(raw) == nil)
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `./test.sh --filter "Token freshness|Token response decoding|Callback parsing"`
Expected: FAIL, cannot find `OAuthTokens` in scope.

- [ ] **Step 3: Write the implementation**

`app/Auth/OAuthModels.swift`:

```swift
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
/// paste-back page prints it, and a full redirect URL.
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
```

- [ ] **Step 4: Run to verify they pass**

Run: `./test.sh --filter "Token freshness|Token response decoding|Callback parsing"`
Expected: PASS, 12 tests.

- [ ] **Step 5: Commit**

```bash
git add app/Auth/OAuthModels.swift Tests/ClaudeUsageAuthTests/OAuthModelsTests.swift
git commit -m "feat: add OAuth token models and callback parsing"
```

---

### Task 4: OAuthClient

**Files:**
- Create: `app/Auth/OAuthClient.swift`
- Create: `Tests/ClaudeUsageAuthTests/OAuthClientTests.swift`

**Interfaces:**
- Consumes: `PKCE`, `TokenResponse`, `OAuthTokens`
- Produces:
  - `enum OAuthEndpoints` with `clientID`, `authorize`, `token`, `pasteRedirect`, `scopes`
  - `struct AuthorizationRequest` with `verifier: String`, `state: String`, `redirectURI: String`, `url: URL`
  - `static func OAuthClient.authorizationRequest(redirectURI: String) -> AuthorizationRequest`
  - `enum OAuthError: Error, Equatable` with `case transport(String)`, `case server(status: Int, body: String)`, `case malformedResponse`
  - `var OAuthError.isAuthFailure: Bool`
  - `protocol TokenRefreshing` with `func refresh(refreshToken: String, completion: @escaping (Result<TokenResponse, OAuthError>) -> Void)`
  - `final class OAuthClient: TokenRefreshing` with `func exchange(code:verifier:redirectURI:state:completion:)`

- [ ] **Step 1: Write the failing tests**

`Tests/ClaudeUsageAuthTests/OAuthClientTests.swift`:

```swift
import Testing
import Foundation
@testable import ClaudeUsageAuth

@Suite("Authorization request")
struct AuthorizationRequestTests {
    @Test func carriesEveryParameterTheEndpointNeeds() throws {
        let request = OAuthClient.authorizationRequest(redirectURI: "http://localhost:51703/callback")
        let components = try #require(URLComponents(url: request.url, resolvingAgainstBaseURL: false))
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value) })

        #expect(components.host == "claude.com")
        #expect(components.path == "/cai/oauth/authorize")
        #expect(items["client_id"] == OAuthEndpoints.clientID)
        #expect(items["response_type"] == "code")
        #expect(items["redirect_uri"] == "http://localhost:51703/callback")
        #expect(items["scope"] == OAuthEndpoints.scopes)
        #expect(items["code_challenge_method"] == "S256")
        #expect(items["state"] == request.state)
    }

    @Test func challengeInTheURLMatchesTheVerifierItKeeps() throws {
        let request = OAuthClient.authorizationRequest(redirectURI: "http://localhost:1/callback")
        let components = try #require(URLComponents(url: request.url, resolvingAgainstBaseURL: false))
        let challenge = components.queryItems?.first { $0.name == "code_challenge" }?.value
        #expect(challenge == PKCE.challenge(for: request.verifier))
    }

    @Test func twoRequestsNeverShareAVerifierOrState() {
        let a = OAuthClient.authorizationRequest(redirectURI: "http://localhost:1/callback")
        let b = OAuthClient.authorizationRequest(redirectURI: "http://localhost:1/callback")
        #expect(a.verifier != b.verifier)
        #expect(a.state != b.state)
    }

    @Test func acceptsACallbackCarryingItsOwnState() {
        let request = OAuthClient.authorizationRequest(redirectURI: "http://localhost:1/callback")
        #expect(request.accepts(CallbackResult(code: "c", state: request.state)))
    }

    @Test func rejectsACallbackFromADifferentSignIn() {
        let request = OAuthClient.authorizationRequest(redirectURI: "http://localhost:1/callback")
        #expect(!request.accepts(CallbackResult(code: "c", state: "someone-elses-state")))
    }

    @Test func acceptsACallbackWithNoStateAtAll() {
        // The paste-back page prints a bare code when the user copies only
        // the part before the hash. There is nothing to compare, so the code
        // is taken and the exchange decides.
        let request = OAuthClient.authorizationRequest(redirectURI: "http://localhost:1/callback")
        #expect(request.accepts(CallbackResult(code: "c", state: nil)))
    }

    @Test func thePasteFlowAsksForACodeOnScreen() throws {
        let request = OAuthClient.authorizationRequest(redirectURI: OAuthEndpoints.pasteRedirect)
        let components = try #require(URLComponents(url: request.url, resolvingAgainstBaseURL: false))
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value) })
        // Without this the callback page redirects instead of printing a code.
        #expect(items["code"] == "true")
    }
}

@Suite("OAuth errors")
struct OAuthErrorTests {
    @Test func fourHundredOneCountsAsAnAuthFailure() {
        #expect(OAuthError.server(status: 401, body: "").isAuthFailure)
    }

    @Test func fourHundredCountsAsAnAuthFailure() {
        // The token endpoint answers invalid_grant with a 400.
        #expect(OAuthError.server(status: 400, body: "invalid_grant").isAuthFailure)
    }

    @Test func serverAndTransportTroubleDoNot() {
        #expect(!OAuthError.server(status: 500, body: "").isAuthFailure)
        #expect(!OAuthError.transport("offline").isAuthFailure)
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `./test.sh --filter "Authorization request|OAuth errors"`
Expected: FAIL, cannot find `OAuthClient` in scope.

- [ ] **Step 3: Write the implementation**

`app/Auth/OAuthClient.swift`:

```swift
import Foundation

public enum OAuthEndpoints {
    /// Claude Code's public client. Anthropic publishes no client registration
    /// for third-party apps, so there is no id of our own to use. If this stops
    /// working, accounts fall back to their session cookie.
    public static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    public static let authorize = "https://claude.com/cai/oauth/authorize"
    public static let token = URL(string: "https://platform.claude.com/v1/oauth/token")!
    /// Used when the user signs in somewhere the app cannot listen, such as a
    /// private window. The page prints `code#state` to paste back.
    public static let pasteRedirect = "https://platform.claude.com/oauth/code/callback"
    public static let scopes = "user:profile user:inference"
}

public struct AuthorizationRequest {
    public let verifier: String
    public let state: String
    public let redirectURI: String
    public let url: URL

    /// Guards against a code from a different sign-in being redeemed here.
    /// A callback with no state at all is allowed through: the paste-back
    /// page prints `code#state` and users copy just the code often enough
    /// that rejecting it would be a worse bug than the one this prevents.
    /// The exchange then fails on its own if the code is wrong.
    public func accepts(_ callback: CallbackResult) -> Bool {
        guard let state = callback.state else { return true }
        return state == self.state
    }
}

public enum OAuthError: Error, Equatable {
    case transport(String)
    case server(status: Int, body: String)
    case malformedResponse

    /// True when retrying is pointless and the user has to sign in again.
    /// The token endpoint answers a spent or revoked grant with a 400
    /// `invalid_grant`, not a 401, so both count.
    public var isAuthFailure: Bool {
        if case let .server(status, _) = self { return status == 400 || status == 401 || status == 403 }
        return false
    }
}

public protocol TokenRefreshing {
    func refresh(refreshToken: String,
                 completion: @escaping (Result<TokenResponse, OAuthError>) -> Void)
}

public final class OAuthClient: TokenRefreshing {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public static func authorizationRequest(redirectURI: String) -> AuthorizationRequest {
        let verifier = PKCE.randomVerifier()
        let state = PKCE.randomState()

        var components = URLComponents(string: OAuthEndpoints.authorize)!
        var items = [
            URLQueryItem(name: "client_id", value: OAuthEndpoints.clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: OAuthEndpoints.scopes),
            URLQueryItem(name: "code_challenge", value: PKCE.challenge(for: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state)
        ]
        // The paste-back page shows the code only when asked to.
        if redirectURI == OAuthEndpoints.pasteRedirect {
            items.insert(URLQueryItem(name: "code", value: "true"), at: 0)
        }
        components.queryItems = items

        return AuthorizationRequest(verifier: verifier,
                                    state: state,
                                    redirectURI: redirectURI,
                                    url: components.url!)
    }

    public func exchange(code: String,
                         verifier: String,
                         redirectURI: String,
                         state: String?,
                         completion: @escaping (Result<TokenResponse, OAuthError>) -> Void) {
        var body: [String: Any] = [
            "grant_type": "authorization_code",
            "code": code,
            "client_id": OAuthEndpoints.clientID,
            "redirect_uri": redirectURI,
            "code_verifier": verifier
        ]
        if let state = state { body["state"] = state }
        post(body, completion: completion)
    }

    public func refresh(refreshToken: String,
                        completion: @escaping (Result<TokenResponse, OAuthError>) -> Void) {
        post([
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": OAuthEndpoints.clientID
        ], completion: completion)
    }

    private func post(_ body: [String: Any],
                      completion: @escaping (Result<TokenResponse, OAuthError>) -> Void) {
        var request = URLRequest(url: OAuthEndpoints.token)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        session.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(.transport(error.localizedDescription)))
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let data = data ?? Data()
            guard (200..<300).contains(status) else {
                let body = String(data: data.prefix(500), encoding: .utf8) ?? ""
                completion(.failure(.server(status: status, body: body)))
                return
            }
            guard let decoded = try? JSONDecoder().decode(TokenResponse.self, from: data) else {
                completion(.failure(.malformedResponse))
                return
            }
            completion(.success(decoded))
        }.resume()
    }
}
```

- [ ] **Step 4: Run to verify they pass**

Run: `./test.sh --filter "Authorization request|OAuth errors"`
Expected: PASS, 10 tests.

- [ ] **Step 5: Commit**

```bash
git add app/Auth/OAuthClient.swift Tests/ClaudeUsageAuthTests/OAuthClientTests.swift
git commit -m "feat: add OAuth authorize URL builder and token endpoint client"
```

---

### Task 5: CredentialStore

The spec calls this file `TokenStore.swift`. It is named `CredentialStore.swift` because it holds the session cookie as well as the tokens, and a name that says "token" would mislead the next reader.

**Files:**
- Create: `app/Auth/CredentialStore.swift`
- Create: `Tests/ClaudeUsageAuthTests/CredentialStoreTests.swift`
- Modify: `app/build.sh` (install step, drop the ad-hoc re-sign)

**Interfaces:**
- Consumes: `StoredCredential`
- Produces:
  - `struct CredentialStore` with `init(service: String = "com.hazime.claudeusagemulti.oauth")`
  - `func load(_ id: UUID) -> StoredCredential?`
  - `func save(_ credential: StoredCredential, for id: UUID) throws`
  - `func delete(_ id: UUID)`
  - `enum CredentialStoreError: Error` with `case keychain(OSStatus)`

- [ ] **Step 1: Write the failing tests**

`Tests/ClaudeUsageAuthTests/CredentialStoreTests.swift`:

```swift
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
```

- [ ] **Step 2: Run to verify they fail**

Run: `./test.sh --filter "Credential store"`
Expected: FAIL, cannot find `CredentialStore` in scope.

- [ ] **Step 3: Write the implementation**

`app/Auth/CredentialStore.swift`:

```swift
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
```

- [ ] **Step 4: Run to verify they pass**

Run: `./test.sh --filter "Credential store"`
Expected: PASS, 5 tests.

If macOS prompts for the login password during this run, that is the unsigned test binary being asked about an item it created in a previous run under a different path. Each test uses a fresh service name so this should not happen; if it does, note it and continue, it does not affect the signed app.

- [ ] **Step 5: Stop build.sh from downgrading the signature**

Keychain access is granted per code signature. `build.sh` signs the bundle with the Developer ID, then re-signs it ad-hoc after copying it to `/Applications`, which throws that identity away and leaves the installed app with no stable one. macOS would then treat each rebuild as a different app and prompt.

In `app/build.sh`, in the install block, delete this line:

```bash
    codesign --force --deep --sign - "$INSTALL_PATH" 2>/dev/null
```

and change the line above it from:

```bash
    xattr -cr "$INSTALL_PATH"
```

to:

```bash
    # Do not re-sign here. The bundle is already signed above, and replacing
    # that with an ad-hoc signature gives the app no stable identity, which
    # makes macOS prompt for keychain access on every rebuild.
    xattr -cr "$INSTALL_PATH"
    codesign --verify "$INSTALL_PATH" || echo "⚠️  Installed copy is unsigned; keychain access will prompt."
```

- [ ] **Step 6: Verify the installed app keeps its signature**

Run: `cd app && ./build.sh && codesign -dv "/Applications/Claude Usage Multi.app" 2>&1 | grep -i "signature\|Authority" | head -3`
Expected: an Authority line naming the Developer ID, not "Signature=adhoc".

- [ ] **Step 7: Commit**

```bash
git add app/Auth/CredentialStore.swift Tests/ClaudeUsageAuthTests/CredentialStoreTests.swift app/build.sh
git commit -m "feat: store per-account credentials in the app's own keychain items"
```

---

### Task 6: Loopback callback server

If Task 1 found that an arbitrary loopback port is rejected, replace `port: .any` with `port: 51703` throughout this task and change the test to use that port.

**Files:**
- Create: `app/Auth/LoopbackCallbackServer.swift`
- Create: `Tests/ClaudeUsageAuthTests/LoopbackCallbackServerTests.swift`

**Interfaces:**
- Consumes: `CallbackParser`, `CallbackResult`
- Produces:
  - `final class LoopbackCallbackServer`
  - `enum LoopbackError: Error, Equatable` with `case listenFailed(String)`, `case timedOut`, `case cancelled`
  - `func start(timeout: TimeInterval, onReady: @escaping (Result<UInt16, LoopbackError>) -> Void, onResult: @escaping (Result<CallbackResult, LoopbackError>) -> Void)`
  - `func cancel()`

- [ ] **Step 1: Write the failing test**

`Tests/ClaudeUsageAuthTests/LoopbackCallbackServerTests.swift`:

```swift
import Testing
import Foundation
@testable import ClaudeUsageAuth

@Suite("Loopback callback server")
struct LoopbackCallbackServerTests {
    @Test func capturesTheCodeAndStateFromARealRequest() async throws {
        let server = LoopbackCallbackServer()

        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            server.start(timeout: 10,
                         onReady: { continuation.resume(with: $0.mapError { $0 as Error }) },
                         onResult: { _ in })
        }
        #expect(port > 0)
        server.cancel()
    }

    @Test func deliversTheCallbackTheBrowserWouldSend() async throws {
        let server = LoopbackCallbackServer()
        defer { server.cancel() }

        var deliver: ((Result<CallbackResult, LoopbackError>) -> Void)?

        let result: CallbackResult = try await withCheckedThrowingContinuation { resultContinuation in
            deliver = { outcome in resultContinuation.resume(with: outcome.mapError { $0 as Error }) }

            server.start(timeout: 10, onReady: { ready in
                guard case let .success(port) = ready else {
                    deliver?(.failure(.listenFailed("not ready")))
                    return
                }
                let url = URL(string: "http://127.0.0.1:\(port)/callback?code=abc123&state=st8")!
                URLSession.shared.dataTask(with: url) { _, _, _ in }.resume()
            }, onResult: { outcome in
                deliver?(outcome)
            })
        }

        #expect(result == CallbackResult(code: "abc123", state: "st8"))
    }

    @Test func timesOutWhenNobodyCalls() async throws {
        let server = LoopbackCallbackServer()
        defer { server.cancel() }

        let error: LoopbackError = await withCheckedContinuation { continuation in
            server.start(timeout: 1, onReady: { _ in }, onResult: { outcome in
                if case let .failure(error) = outcome { continuation.resume(returning: error) }
            })
        }
        #expect(error == .timedOut)
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `./test.sh --filter "Loopback callback server"`
Expected: FAIL, cannot find `LoopbackCallbackServer` in scope.

- [ ] **Step 3: Write the implementation**

`app/Auth/LoopbackCallbackServer.swift`:

```swift
import Foundation
import Network

public enum LoopbackError: Error, Equatable {
    case listenFailed(String)
    case timedOut
    case cancelled
    case malformedRequest
}

/// Catches the one redirect the browser makes at the end of a sign-in.
///
/// Binds 127.0.0.1 only, answers exactly one request, then shuts down. The
/// port is ephemeral, so two sign-ins can never collide and no fixed port has
/// to be reserved.
public final class LoopbackCallbackServer {
    private let queue = DispatchQueue(label: "com.hazime.claudeusagemulti.oauth.callback")
    private var listener: NWListener?
    private var timeoutWork: DispatchWorkItem?
    private var onResult: ((Result<CallbackResult, LoopbackError>) -> Void)?
    private var finished = false

    public init() {}

    public func start(timeout: TimeInterval = 300,
                      onReady: @escaping (Result<UInt16, LoopbackError>) -> Void,
                      onResult: @escaping (Result<CallbackResult, LoopbackError>) -> Void) {
        queue.async {
            self.onResult = onResult

            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
            parameters.allowLocalEndpointReuse = true

            let listener: NWListener
            do {
                listener = try NWListener(using: parameters)
            } catch {
                onReady(.failure(.listenFailed(error.localizedDescription)))
                return
            }
            self.listener = listener

            // Fires exactly once. A caller awaiting a continuation here would
            // crash if .ready were followed by .failed.
            var readyReported = false
            let reportReady: (Result<UInt16, LoopbackError>) -> Void = { outcome in
                guard !readyReported else { return }
                readyReported = true
                onReady(outcome)
            }

            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    reportReady(.success(listener.port?.rawValue ?? 0))
                case .failed(let error):
                    reportReady(.failure(.listenFailed(error.localizedDescription)))
                    self.finish(.failure(.listenFailed(error.localizedDescription)))
                default:
                    break
                }
            }

            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            listener.start(queue: self.queue)

            let work = DispatchWorkItem { [weak self] in self?.finish(.failure(.timedOut)) }
            self.timeoutWork = work
            self.queue.asyncAfter(deadline: .now() + timeout, execute: work)
        }
    }

    public func cancel() {
        queue.async { self.finish(.failure(.cancelled)) }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self = self else { return }
            let request = String(data: data ?? Data(), encoding: .utf8) ?? ""
            let outcome = Self.parseRequestLine(request)

            let body = outcome == nil
                ? "<h2>Sign-in failed</h2><p>Go back to Claude Usage and try again.</p>"
                : "<h2>Signed in</h2><p>You can close this tab.</p>"
            let response = """
            HTTP/1.1 200 OK\r
            Content-Type: text/html; charset=utf-8\r
            Content-Length: \(body.utf8.count)\r
            Connection: close\r
            \r
            \(body)
            """
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                connection.cancel()
                self.queue.async {
                    if let outcome = outcome {
                        self.finish(.success(outcome))
                    } else {
                        self.finish(.failure(.malformedRequest))
                    }
                }
            })
        }
    }

    /// Pulls the target out of "GET /callback?code=..&state=.. HTTP/1.1".
    static func parseRequestLine(_ request: String) -> CallbackResult? {
        guard let line = request.split(separator: "\r\n", maxSplits: 1).first else { return nil }
        let fields = line.split(separator: " ")
        guard fields.count >= 2 else { return nil }
        return CallbackParser.parse(String(fields[1]))
    }

    /// Every exit runs through here, so the caller is answered exactly once and
    /// the listener is always torn down.
    private func finish(_ outcome: Result<CallbackResult, LoopbackError>) {
        guard !finished else { return }
        finished = true
        timeoutWork?.cancel()
        timeoutWork = nil
        listener?.cancel()
        listener = nil
        let handler = onResult
        onResult = nil
        if case .failure(.cancelled) = outcome { return }
        handler?(outcome)
    }
}
```

- [ ] **Step 4: Run to verify they pass**

Run: `./test.sh --filter "Loopback callback server"`
Expected: PASS, 3 tests.

macOS may show a firewall prompt the first time the test binary listens. Allow it.

- [ ] **Step 5: Commit**

```bash
git add app/Auth/LoopbackCallbackServer.swift Tests/ClaudeUsageAuthTests/LoopbackCallbackServerTests.swift
git commit -m "feat: catch the OAuth redirect on an ephemeral loopback port"
```

---

### Task 7: CredentialProvider

**Files:**
- Create: `app/Auth/CredentialProvider.swift`
- Create: `Tests/ClaudeUsageAuthTests/CredentialProviderTests.swift`

**Interfaces:**
- Consumes: `CredentialStore`, `TokenRefreshing`, `OAuthTokens`, `StoredCredential`, `OAuthError`
- Produces:
  - `final class CredentialProvider`
  - `enum CredentialOutcome: Equatable` with `case token(String)`, `case cookie(String)`, `case needsReauth(String)`, `case unavailable(String)`, `case none`
  - `init(store: CredentialStore, client: TokenRefreshing, now: @escaping () -> Date)`
  - `func credential(for id: UUID, completion: @escaping (CredentialOutcome) -> Void)`
  - `func signOut(_ id: UUID)`

- [ ] **Step 1: Write the failing tests**

`Tests/ClaudeUsageAuthTests/CredentialProviderTests.swift`:

```swift
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

    @Test func anAccountWithNothingConfiguredReturnsNone() async {
        let provider = CredentialProvider(store: makeStore(), client: FakeRefresher(), now: { self.now })
        #expect(await await_(provider, UUID()) == .none)
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
```

- [ ] **Step 2: Run to verify they fail**

Run: `./test.sh --filter "Credential provider"`
Expected: FAIL, cannot find `CredentialProvider` in scope.

- [ ] **Step 3: Write the implementation**

`app/Auth/CredentialProvider.swift`:

```swift
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
    case none
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
                completion(.none)
                return
            }

            guard let oauth = stored.oauth else {
                completion(self.fallback(stored, reason: "no OAuth grant"))
                return
            }

            if oauth.isFresh(at: self.now()) {
                completion(.token(oauth.accessToken))
                return
            }

            guard let refreshToken = oauth.refreshToken else {
                // A setup token that has expired cannot be renewed.
                completion(self.fallback(stored, reason: "token expired and has no refresh token"))
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
                                             to: stored,
                                             previousRefreshToken: refreshToken,
                                             id: id)
                    let waiters = self.waiting.removeValue(forKey: id) ?? []
                    waiters.forEach { $0(outcome) }
                }
            }
        }
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
                       to stored: StoredCredential,
                       previousRefreshToken: String,
                       id: UUID) -> CredentialOutcome {
        switch result {
        case .success(let response):
            var renewed = response.tokens(now: now())
            // Neither of these comes back in a refresh response.
            renewed.email = stored.oauth?.email
            if renewed.refreshToken == nil { renewed.refreshToken = previousRefreshToken }

            var updated = stored
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
            return fallback(stored, reason: "sign-in expired")

        case .failure(let error):
            return .unavailable("\(error)")
        }
    }

    private func fallback(_ stored: StoredCredential, reason: String) -> CredentialOutcome {
        if let cookie = stored.cookie, !cookie.isEmpty { return .cookie(cookie) }
        return .needsReauth(reason)
    }
}
```

- [ ] **Step 4: Run to verify they pass**

Run: `./test.sh --filter "Credential provider"`
Expected: PASS, 10 tests.

- [ ] **Step 5: Run the whole suite**

Run: `./test.sh`
Expected: PASS, 43 tests.

- [ ] **Step 6: Commit**

```bash
git add app/Auth/CredentialProvider.swift Tests/ClaudeUsageAuthTests/CredentialProviderTests.swift
git commit -m "feat: resolve account credentials with single-flight token refresh"
```

---

### Task 8: Account model and migration

**Files:**
- Modify: `app/ClaudeUsageBar.swift:705-775` (`Account`)
- Modify: `app/ClaudeUsageBar.swift:776-855` (`AccountStore`)

**Interfaces:**
- Consumes: `CredentialStore`, `StoredCredential`, `OAuthTokens`
- Produces:
  - `Account.hasOAuth: Bool`
  - `Account.accountEmail: String?` (kept)
  - `static func AccountStore.load(store: CredentialStore) -> [Account]`
  - `static func AccountStore.migrateSecretsToKeychain(_ accounts: inout [Account], store: CredentialStore)`

- [ ] **Step 1: Change the Account model**

Replace the `// MARK: OAuth` block in `Account` (the `oauthToken`, `keychainService`, `keychainAccount`, `verifiedTokenHash` properties) with:

```swift
    // MARK: Credentials
    //
    // Nothing secret lives here. Tokens and the session cookie are in the
    // account's keychain item, addressed by `id`. The fields below are only
    // what the UI needs to draw the account without opening the keychain.

    /// True once the account has signed in. Kept here so a row can be drawn
    /// without a keychain read on every SwiftUI update.
    var hasOAuth: Bool = false

    /// Email the account's grant resolved to, shown on its row.
    var accountEmail: String? = nil

    // Legacy fields. Decoded so accounts saved before the keychain move can be
    // migrated, then blanked. Nothing reads them after `migrateSecretsToKeychain`.
    var cookie: String = ""
    var oauthToken: String? = nil
    var keychainService: String? = nil
    var keychainAccount: String? = nil
```

- [ ] **Step 2: Write the migration**

In `AccountStore`, change `load()` to take the store and run the migration, and add the migration itself:

```swift
    static func load(store: CredentialStore = CredentialStore()) -> [Account] {
        var accounts = loadFromDefaults()
        migrateSecretsToKeychain(&accounts, store: store)
        return accounts
    }

    /// Moves cookies and pasted setup tokens out of the preferences plist and
    /// into each account's keychain item, once.
    ///
    /// Accounts bound to a Claude Code login lose the binding: that token
    /// belongs to the CLI, and refreshing it would rotate the CLI's own
    /// refresh token and sign it out. Those accounts have to sign in again.
    static func migrateSecretsToKeychain(_ accounts: inout [Account], store: CredentialStore) {
        var changed = false

        for index in accounts.indices {
            var account = accounts[index]
            let hadPlaintext = !account.cookie.isEmpty || !(account.oauthToken ?? "").isEmpty
            let hadBinding = account.keychainService != nil
            guard hadPlaintext || hadBinding else { continue }

            var credential = store.load(account.id) ?? StoredCredential()

            if !account.cookie.isEmpty, (credential.cookie ?? "").isEmpty {
                credential.cookie = account.cookie
            }
            // A setup token is long-lived and needs no refresh, so it becomes
            // an OAuth grant with no refresh token and no expiry.
            if let token = account.oauthToken, !token.isEmpty, credential.oauth == nil {
                credential.oauth = OAuthTokens(accessToken: token, email: account.accountEmail)
            }

            do {
                try store.save(credential, for: account.id)
            } catch {
                NSLog("\u{274C} Could not move '\(account.displayName)' credentials to the keychain: \(error)")
                continue
            }

            account.hasOAuth = credential.oauth != nil
            account.cookie = ""
            account.oauthToken = nil
            account.keychainService = nil
            account.keychainAccount = nil
            accounts[index] = account
            changed = true

            if hadBinding {
                NSLog("\u{1F511} '\(account.displayName)' was bound to a Claude Code login and needs to sign in again")
            }
        }

        if changed { save(accounts) }
    }
```

Rename the existing body of `load()` to `loadFromDefaults()`, unchanged, minus the migration call.

- [ ] **Step 3: Build**

Run: `cd app && INSTALL=0 ./build.sh`
Expected: errors only where `UsageManager` and the views still reference the removed properties. Those are Tasks 9 and 10. Note them and continue.

- [ ] **Step 4: Commit**

```bash
git add app/ClaudeUsageBar.swift
git commit -m "refactor: move account secrets from preferences into the keychain"
```

---

### Task 9: Wire UsageManager to CredentialProvider

**Files:**
- Modify: `app/ClaudeUsageBar.swift:1073-1205` (`AuthSource` and its helpers)
- Modify: `app/ClaudeUsageBar.swift:1540-1560` (fetch entry point)
- Delete: `app/ClaudeUsageBar.swift:545-696` (`ClaudeCodeKeychain`)

**Interfaces:**
- Consumes: `CredentialProvider`, `CredentialOutcome`
- Produces:
  - `UsageManager.needsReauth: Bool` (`@Published`)
  - `UsageManager.usingCookieFallback: Bool` (`@Published`)
  - `UsageManager.authSourceLabel: String`
  - `func UsageManager.signIn(completion: @escaping (String?) -> Void)`
  - `func UsageManager.completeSignIn(paste: String, completion: @escaping (String?) -> Void)`
  - `func UsageManager.signOut()`

- [ ] **Step 1: Delete ClaudeCodeKeychain**

Remove the whole `// MARK: - Claude Code credentials` section, from `enum ClaudeCodeKeychain {` to its closing brace. Remove `import CryptoKit` if nothing else in the file uses it.

- [ ] **Step 2: Replace the auth resolution**

Replace the `AuthSource` enum and `authSource`, `authSourceLabel`, `hasCredential`, `bindKeychainLogin`, `unbindKeychainLogin`, `saveOAuthToken` and `clearOAuthToken` with:

```swift
    // MARK: - Authentication

    /// Set when the account's grant is gone and only a new sign-in fixes it.
    @Published var needsReauth: Bool = false

    /// Set when OAuth failed but a stored cookie is keeping numbers flowing.
    @Published var usingCookieFallback: Bool = false

    var authSourceLabel: String {
        if needsReauth { return "Sign in again" }
        if usingCookieFallback { return "Session cookie (sign-in expired)" }
        if account.hasOAuth { return account.accountEmail ?? "Signed in" }
        return hasCookie ? "Session cookie" : "Not configured"
    }

    var hasCredential: Bool { account.hasOAuth || hasCookie }

    var hasCookie: Bool { !(credentials.storedCookie(for: account.id) ?? "").isEmpty }
```

- [ ] **Step 3: Route the fetch through the provider**

Replace the body of the fetch entry point so it asks the provider what to use:

```swift
    func fetchUsage() {
        credentials.credential(for: account.id) { [weak self] outcome in
            guard let self = self else { return }
            switch outcome {
            case .token(let token):
                self.needsReauth = false
                self.usingCookieFallback = false
                self.fetchUsageViaOAuth(token)

            case .cookie(let cookie):
                // OAuth is gone but the cookie still works, so numbers keep
                // updating while the user gets around to signing in again.
                self.needsReauth = self.account.hasOAuth
                self.usingCookieFallback = self.account.hasOAuth
                if self.needsReauth { self.reportReauthNeeded() }
                self.fetchUsageViaCookie(cookie)

            case .needsReauth(let reason):
                NSLog("\u{1F511} '\(self.account.displayName)' needs a new sign-in: \(reason)")
                self.needsReauth = true
                self.usingCookieFallback = false
                self.errorMessage = "Sign in again"
                self.reportReauthNeeded()

            case .unavailable(let reason):
                // Temporary. Leave the badge alone and try again next cycle.
                NSLog("\u{26A0}\u{FE0F} '\(self.account.displayName)': \(reason)")
                self.errorMessage = "Could not reach Anthropic"

            case .none:
                self.needsReauth = false
                self.usingCookieFallback = false
                self.errorMessage = "Sign in to see usage"
            }
        }
    }
```

`fetchUsageViaOAuth` loses its `source:` parameter, since the provider now decides.

`fetchUsageViaCookie()` becomes `fetchUsageViaCookie(_ cookie: String)` and uses
the argument instead of the `sessionCookie` property. Delete the `sessionCookie`
computed property and every other read of `account.cookie`: after Task 8 that
field is blank on every account, so any surviving read silently authenticates
with an empty string. Grep for it before moving on:

```bash
grep -n "sessionCookie\|account\.cookie" app/ClaudeUsageBar.swift
```

Expected after this step: hits only inside the cookie paste handler, which
writes through `credentials.save`, and inside `AccountStore.migrateSecretsToKeychain`.

- [ ] **Step 4: Notify once per failure**

Add to `UsageManager`:

```swift
    /// One notification per failure, not one per refresh cycle.
    private var reauthNotified = false

    private func reportReauthNeeded() {
        guard !reauthNotified else { return }
        reauthNotified = true
        Notifier.send(title: "\(account.displayName) needs a new sign-in",
                      body: usingCookieFallback
                          ? "Using its session cookie for now."
                          : "Usage will not update until you sign in.")
    }
```

Clear `reauthNotified` wherever `needsReauth` is set back to false.

- [ ] **Step 5: Add sign-in, paste and sign-out**

```swift
    /// Opens the browser and waits for the redirect on a loopback port.
    /// The completion carries nil on success, or a message to show.
    func signIn(completion: @escaping (String?) -> Void) {
        let server = LoopbackCallbackServer()
        signInServer = server

        server.start(timeout: 300, onReady: { [weak self] ready in
            guard let self = self else { return }
            switch ready {
            case .success(let port):
                let redirect = "http://localhost:\(port)/callback"
                let request = OAuthClient.authorizationRequest(redirectURI: redirect)
                self.pendingRequest = request
                NSWorkspace.shared.open(request.url)
            case .failure(let error):
                DispatchQueue.main.async { completion("Could not start the sign-in listener: \(error)") }
            }
        }, onResult: { [weak self] result in
            guard let self = self, let request = self.pendingRequest else { return }
            switch result {
            case .success(let callback):
                guard request.accepts(callback) else {
                    DispatchQueue.main.async { completion("Sign-in did not match the request. Try again.") }
                    return
                }
                self.exchange(callback.code, request: request, completion: completion)
            case .failure(let error):
                DispatchQueue.main.async {
                    completion(error == .timedOut ? "Sign-in timed out. Try again." : "Sign-in failed: \(error)")
                }
            }
        })
    }

    /// The route for a second account, signed in from a private window where
    /// the app cannot listen on loopback.
    func beginPasteSignIn() {
        let request = OAuthClient.authorizationRequest(redirectURI: OAuthEndpoints.pasteRedirect)
        pendingRequest = request
        NSWorkspace.shared.open(request.url)
    }

    func completeSignIn(paste: String, completion: @escaping (String?) -> Void) {
        guard let request = pendingRequest else {
            completion("Start a sign-in first.")
            return
        }
        guard let callback = CallbackParser.parse(paste) else {
            completion("That does not look like a sign-in code.")
            return
        }
        guard request.accepts(callback) else {
            completion("That code is from a different sign-in. Try again.")
            return
        }
        exchange(callback.code, request: request, completion: completion)
    }

    private func exchange(_ code: String,
                          request: AuthorizationRequest,
                          completion: @escaping (String?) -> Void) {
        oauthClient.exchange(code: code,
                             verifier: request.verifier,
                             redirectURI: request.redirectURI,
                             state: request.state) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let error):
                DispatchQueue.main.async { completion("Sign-in failed: \(error)") }
            case .success(let response):
                var stored = self.credentials.stored(for: self.account.id) ?? StoredCredential()
                stored.oauth = response.tokens()
                do {
                    try self.credentials.save(stored, for: self.account.id)
                } catch {
                    DispatchQueue.main.async { completion("Could not save the sign-in: \(error)") }
                    return
                }
                DispatchQueue.main.async {
                    self.account.hasOAuth = true
                    self.needsReauth = false
                    self.reauthNotified = false
                    self.usingCookieFallback = false
                    self.pendingRequest = nil
                    self.onAccountEdited?(self.account)
                    self.resolveEmail(response.tokens().accessToken)
                    self.fetchUsage()
                    completion(nil)
                }
            }
        }
    }

    /// Stamps the account with the email its grant belongs to, so two accounts
    /// are told apart on sight.
    private func resolveEmail(_ token: String) {
        fetchOAuthProfile(token) { [weak self] email, _ in
            guard let self = self, let email = email else { return }
            DispatchQueue.main.async {
                self.account.accountEmail = email
                self.onAccountEdited?(self.account)
            }
        }
    }

    func signOut() {
        credentials.signOut(account.id)
        account.hasOAuth = false
        account.accountEmail = nil
        needsReauth = false
        reauthNotified = false
        usingCookieFallback = false
        onAccountEdited?(account)
        fetchUsage()
    }
```

Add the stored properties this needs to `UsageManager`:

```swift
    private let credentials: CredentialProvider
    private let oauthClient = OAuthClient()
    private var signInServer: LoopbackCallbackServer?
    private var pendingRequest: AuthorizationRequest?
```

`AccountsController` owns one `CredentialProvider` and passes it to every `UsageManager` it creates, so all accounts share one refresh queue.

- [ ] **Step 6: Add the two store helpers the manager uses**

In `CredentialProvider`:

```swift
    /// Direct reads for the UI and for a cookie paste, which do not need a
    /// refresh and must not trigger one.
    public func stored(for id: UUID) -> StoredCredential? {
        queue.sync { store.load(id) }
    }

    public func storedCookie(for id: UUID) -> String? {
        stored(for: id)?.cookie
    }

    public func save(_ credential: StoredCredential, for id: UUID) throws {
        try queue.sync { try store.save(credential, for: id) }
    }
```

- [ ] **Step 7: Build**

Run: `cd app && INSTALL=0 ./build.sh`
Expected: errors only in the views, which Task 10 fixes.

- [ ] **Step 8: Commit**

```bash
git add app/ClaudeUsageBar.swift app/Auth/CredentialProvider.swift
git commit -m "feat: authenticate accounts through CredentialProvider

Removes ClaudeCodeKeychain. Reading the CLI's keychain items prompted for
the login password on every read and only ever covered the one account
Claude Code was signed into."
```

---

### Task 10: Sign-in UI

**Files:**
- Modify: `app/ClaudeUsageBar.swift:3300-3420` (`claudeCodeLoginSection`, `setupTokenSection`)
- Modify: `app/ClaudeUsageBar.swift:3275-3300` (`AccountUsageSection` state)

**Interfaces:**
- Consumes: `UsageManager.signIn`, `beginPasteSignIn`, `completeSignIn`, `signOut`, `needsReauth`, `usingCookieFallback`
- Produces: nothing later tasks depend on

- [ ] **Step 1: Replace both sections with one**

Delete `claudeCodeLoginSection` and `setupTokenSection` entirely, along with the `discoveredLogins`, `isDiscovering` and `tokenInput` state they used. Add:

```swift
    @State private var signingIn = false
    @State private var pasteInput = ""
    @State private var showPaste = false

    @ViewBuilder
    private var signInSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Sign in")
                    .font(.caption)
                    .fontWeight(.semibold)
                Spacer()
                if account.hasOAuth {
                    Button("Sign out") { manager.signOut() }
                        .buttonStyle(.borderless)
                        .font(.caption2)
                }
            }

            if account.hasOAuth, !manager.needsReauth {
                Text(account.accountEmail ?? "Signed in")
                    .font(.caption2)
                    .foregroundColor(Color.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Button(manager.needsReauth || !account.hasOAuth ? "Sign in with Claude" : "Sign in again") {
                signingIn = true
                manager.errorMessage = "Waiting for the browser..."
                manager.signIn { problem in
                    signingIn = false
                    manager.errorMessage = problem ?? "Signed in, fetching..."
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(signingIn)

            Button(showPaste ? "Hide code entry" : "Already signed in as another account?") {
                showPaste.toggle()
                if showPaste { manager.beginPasteSignIn() }
            }
            .buttonStyle(.borderless)
            .font(.caption2)

            if showPaste {
                Text("Sign in from a private window, then paste the code it shows.")
                    .font(.caption2)
                    .foregroundColor(Color.secondaryText)

                PasteableTextField(text: $pasteInput, placeholder: "Paste code")
                    .frame(height: 40)
                    .cornerRadius(4)

                Button("Finish sign-in") {
                    manager.completeSignIn(paste: pasteInput) { problem in
                        if problem == nil {
                            pasteInput = ""
                            showPaste = false
                        }
                        manager.errorMessage = problem ?? "Signed in, fetching..."
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
    }
```

The one explanatory line stays because the private window step is not visible from the control. Nothing else gets a caption.

- [ ] **Step 2: Demote the cookie section**

The cookie route is now the fallback, not a headline. Wrap `cookieSection` in a disclosure so it is present but not competing:

```swift
    @State private var showCookie = false

    @ViewBuilder
    private var cookieFallbackSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(showCookie ? "Hide session cookie" : "Use a session cookie instead") {
                showCookie.toggle()
            }
            .buttonStyle(.borderless)
            .font(.caption2)

            if showCookie { cookieSection }
        }
    }
```

Update the parent view to render `signInSection` then `cookieFallbackSection`, and force `showCookie` open when `manager.usingCookieFallback` is true.

- [ ] **Step 3: Dim an account that needs signing in again**

In the menu bar rendering in `AccountsController.refreshStatusBar()`, apply a lower alpha to the emoji of any manager whose `needsReauth` is true.

- [ ] **Step 4: Build and launch**

Run: `cd app && ./build.sh`
Expected: `Build successful!`, app launches.

- [ ] **Step 5: Commit**

```bash
git add app/ClaudeUsageBar.swift
git commit -m "feat: sign in from the account row, demote cookies to a fallback"
```

---

### Task 11: End-to-end verification

No new code. This is the task that proves the feature works, so it gets its own gate.

- [ ] **Step 1: Fresh account signs in**

Add a new account. Click **Sign in with Claude**. Expected: browser opens, sign-in completes, tab says it can be closed, the row shows the account email, usage numbers appear within one refresh cycle, and macOS never asks for the login password.

- [ ] **Step 2: Second account signs in from a private window**

Add another account. Click **Already signed in as another account?**, sign in as a different Claude account in a private window, paste the code. Expected: the second row shows the second email, and both rows show their own numbers.

- [ ] **Step 3: The two accounts are actually distinct**

Run: `security find-generic-password -s com.hazime.claudeusagemulti.oauth -g 2>&1 | head -5`
Expected: an item exists. Confirm in the app that the two rows show different emails and different usage percentages.

- [ ] **Step 4: Refresh works**

Force a refresh by editing the stored expiry, or wait for the token to age into the window, then trigger a fetch. Expected in Console (`log stream --predicate 'process == "ClaudeUsageBar"'`): one refresh, numbers update, no prompt.

- [ ] **Step 5: Revoked grant falls back and badges**

Revoke one account's authorization at claude.ai, then trigger a fetch. Expected: that row shows "Sign in again", one notification fires and only one, and if that account has a cookie saved its numbers keep updating with "Session cookie (sign-in expired)" on the row. The other account is unaffected.

- [ ] **Step 6: Migration held**

Confirm accounts that existed before this branch still appear with their names, emoji and colours, that any that had a cookie still work, and that any that were bound to a Claude Code login show "Sign in again".

Run: `defaults read com.hazime.claudeusagemulti claude_accounts | grep -ci "sk-ant" || echo "no secrets in the plist"`
Expected: `no secrets in the plist`.

- [ ] **Step 7: Rebuild does not prompt**

Run: `cd app && ./build.sh`
Expected: the app relaunches and fetches usage without asking for the login password. This is what Task 5 Step 5 was for.

- [ ] **Step 8: Full suite**

Run: `./test.sh`
Expected: PASS, 43 tests.

- [ ] **Step 9: Commit any fixes and merge**

Commit each fix on its own, describing the actual defect. If the run turned up
nothing, there is nothing to commit.

Then use the `superpowers:finishing-a-development-branch` skill to decide how this lands on `main`.
