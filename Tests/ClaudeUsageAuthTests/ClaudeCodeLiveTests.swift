import Testing
import Foundation
@testable import ClaudeUsageAuth

@Suite("Claude Code live access")
struct ClaudeCodeLiveTests {
    func tempConfig() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("claude-\(UUID().uuidString).json")
    }

    @Test func readConfigMissingFileIsNil() throws {
        let live = SystemClaudeCodeLive(configURL: tempConfig())
        #expect(try live.readConfig() == nil)
    }

    @Test func writeConfigIsAtomicAndKeepsPermissions() throws {
        let url = tempConfig()
        try Data("{}".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let live = SystemClaudeCodeLive(configURL: url)

        try live.writeConfig(Data("{\"a\":1}".utf8))

        #expect(try live.readConfig() == Data("{\"a\":1}".utf8))
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    /// Real Keychain, throwaway item. Claude Code's own item is several KB.
    @Test func writesLargeKeychainValueIntact() throws {
        let service = "ClaudeUsage Test \(UUID().uuidString)"
        let account = NSUserName()
        let create = Process()
        create.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        create.arguments = ["add-generic-password", "-a", account, "-s", service, "-w", "{}"]
        try create.run(); create.waitUntilExit()
        defer {
            let delete = Process()
            delete.executableURL = URL(fileURLWithPath: "/usr/bin/security")
            delete.arguments = ["delete-generic-password", "-a", account, "-s", service]
            delete.standardOutput = FileHandle.nullDevice
            try? delete.run(); delete.waitUntilExit()
        }
        let live = SystemClaudeCodeLive(configURL: tempConfig(), keychainAccount: account, service: service)
        let big = json(["claudeAiOauth": ["accessToken": String(repeating: "x", count: 20_000)]])

        try live.writeKeychain(big)

        #expect(try live.readKeychain() == big)
    }

    @Test func writeRefusesMissingItem() {
        let live = SystemClaudeCodeLive(configURL: tempConfig(), service: "ClaudeUsage Missing \(UUID().uuidString)")
        #expect(throws: ClaudeCodeError.notLoggedIn) { try live.writeKeychain(Data("{}".utf8)) }
    }
}
