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
    public static let scopes = "user:inference"
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
        // The authorize page rejects the request without `code=true`, whatever
        // the redirect: without it it answers "Authorization failed".
        components.queryItems = [
            URLQueryItem(name: "code", value: "true"),
            URLQueryItem(name: "client_id", value: OAuthEndpoints.clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: OAuthEndpoints.scopes),
            URLQueryItem(name: "code_challenge", value: PKCE.challenge(for: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state)
        ]

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
