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
