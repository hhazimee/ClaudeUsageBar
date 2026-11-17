import Testing
import Foundation
@testable import ClaudeUsageAuth

func json(_ object: Any) -> Data {
    try! JSONSerialization.data(withJSONObject: object)
}

func dict(_ data: Data) -> NSDictionary {
    (try! JSONSerialization.jsonObject(with: data)) as! NSDictionary
}

@Suite("Claude Code login")
struct ClaudeCodeLoginTests {
    let keychain = json([
        "claudeAiOauth": ["accessToken": "a", "refreshToken": "r", "expiresAt": 1],
        "mcpOAuth": ["clickup|1": ["accessToken": "m"]],
    ])
    let config = json([
        "oauthAccount": ["emailAddress": "x@y.com", "accountUuid": "u1"],
        "projects": [:],
    ])

    @Test func loginReadsBothHalves() throws {
        let login = try #require(ClaudeCodeJSON.login(keychain: keychain, config: config))
        #expect(login.accessToken == "a")
        #expect(login.refreshToken == "r")
        #expect(login.email == "x@y.com")
        #expect(login.accountUUID == "u1")
    }

    @Test func loginNilWhenNoClaudeAiOauth() {
        #expect(ClaudeCodeJSON.login(keychain: json(["mcpOAuth": [:]]), config: config) == nil)
    }

    @Test func keychainMergeKeepsMcp() throws {
        let existing = json([
            "claudeAiOauth": ["accessToken": "old"],
            "mcpOAuth": ["clickup|1": ["accessToken": "m"]],
            "other": 1,
        ])
        let merged = dict(try ClaudeCodeJSON.mergeKeychain(existing, oauth: json(["accessToken": "new"])))
        #expect((merged["claudeAiOauth"] as? NSDictionary) == ["accessToken": "new"])
        #expect((merged["mcpOAuth"] as? NSDictionary) == dict(existing)["mcpOAuth"] as? NSDictionary)
        #expect(merged["other"] as? Int == 1)
    }

    @Test func configMergeKeepsOtherKeys() throws {
        var fields: [String: Any] = ["oauthAccount": ["emailAddress": "a@a.com"]]
        for i in 0..<30 {
            switch i % 5 {
            case 0: fields["k\(i)"] = ["nested": ["deep": [1, 2, 3]], "flag": true]
            case 1: fields["k\(i)"] = [1, "two", 3.5, NSNull()]
            case 2: fields["k\(i)"] = i
            case 3: fields["k\(i)"] = false
            default: fields["k\(i)"] = "text \(i)"
            }
        }
        let existing = json(fields)
        let merged = dict(try ClaudeCodeJSON.mergeConfig(existing, account: json(["emailAddress": "b@b.com"])))
        #expect((merged["oauthAccount"] as? NSDictionary) == ["emailAddress": "b@b.com"])
        let before = dict(existing).mutableCopy() as! NSMutableDictionary
        let after = merged.mutableCopy() as! NSMutableDictionary
        before.removeObject(forKey: "oauthAccount")
        after.removeObject(forKey: "oauthAccount")
        #expect(before == after)
    }

    @Test func credentialWithOnlyClaudeCodeIsNotEmpty() {
        let credential = StoredCredential(claudeCode: ClaudeCodeLogin(oauth: json([:]), account: json([:])))
        #expect(!credential.isEmpty)
    }

    @Test func oldCredentialJSONDecodes() throws {
        let decoded = try JSONDecoder().decode(StoredCredential.self, from: json(["cookie": "c"]))
        #expect(decoded.cookie == "c")
        #expect(decoded.claudeCode == nil)
    }
}
