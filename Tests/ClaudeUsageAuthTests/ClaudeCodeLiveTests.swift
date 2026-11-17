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
}
