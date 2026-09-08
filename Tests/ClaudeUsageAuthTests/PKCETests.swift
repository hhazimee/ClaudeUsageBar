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

    @Test func statesAreThirtyTwoBytesEncoded() {
        // A shorter state is rejected by the authorize page as a malformed request.
        #expect(PKCE.randomState().count == 43)
        #expect(PKCE.randomState() != PKCE.randomState())
    }
}
