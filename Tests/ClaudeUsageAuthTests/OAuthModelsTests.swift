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
