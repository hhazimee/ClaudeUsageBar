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

    @Test func everyAuthorizeRequestAsksForACodeOnScreen() throws {
        let request = OAuthClient.authorizationRequest(redirectURI: "http://localhost:51703/callback")
        let components = try #require(URLComponents(url: request.url, resolvingAgainstBaseURL: false))
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value) })
        // The authorize page rejects the request without this, whatever the redirect.
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
