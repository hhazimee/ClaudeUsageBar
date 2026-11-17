import Foundation

/// Claude Code's live login: its Keychain item and `~/.claude.json`.
public protocol ClaudeCodeLive {
    /// Nil when Claude Code has no Keychain item.
    func readKeychain() throws -> Data?
    /// Updates the existing item only. Throws `.notLoggedIn` if there is none.
    func writeKeychain(_ data: Data) throws
    func readConfig() throws -> Data?
    func writeConfig(_ data: Data) throws
}

public final class SystemClaudeCodeLive: ClaudeCodeLive {
    static let service = "Claude Code-credentials"
    private let configURL: URL
    private let keychainAccount: String

    public init(configURL: URL = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".claude.json"),
                keychainAccount: String = NSUserName()) {
        self.configURL = configURL
        self.keychainAccount = keychainAccount
    }

    /// Goes through `/usr/bin/security`, as Claude Code does. Reading the item
    /// directly would add this app to its access list, and macOS then locks
    /// the `security` tool out, so every Claude Code session asks for a password.
    public func readKeychain() throws -> Data? {
        let result = Self.run(["find-generic-password", "-a", keychainAccount, "-s", Self.service, "-w"])
        if result.status == 44 { return nil }
        guard result.status == 0 else { throw ClaudeCodeError.keychain(result.status) }
        let text = String(decoding: result.output, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // `security -w` prints a value containing newlines as hex.
        if !text.hasPrefix("{"), let decoded = Self.hexDecoded(text) { return decoded }
        return Data(text.utf8)
    }

    /// Updates the existing item only, never creates one.
    public func writeKeychain(_ data: Data) throws {
        guard try readKeychain() != nil else { throw ClaudeCodeError.notLoggedIn }
        let hex = data.map { String(format: "%02x", $0) }.joined()
        // Sent on stdin through `security -i`, so the secret never shows in the process list.
        let command = "add-generic-password -U -a \"\(keychainAccount)\" -s \"\(Self.service)\" -X \(hex)\n"
        let result = Self.run(["-i"], input: Data(command.utf8))
        guard result.status == 0 else { throw ClaudeCodeError.keychain(result.status) }
    }

    private static func run(_ arguments: [String], input: Data? = nil) -> (status: Int32, output: Data) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        let out = Pipe(), inPipe = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = inPipe
        do { try process.run() } catch { return (-1, Data()) }
        if let input { inPipe.fileHandleForWriting.write(input) }
        try? inPipe.fileHandleForWriting.close()
        let output = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, output)
    }

    private static func hexDecoded(_ text: String) -> Data? {
        guard text.count % 2 == 0, !text.isEmpty else { return nil }
        var data = Data(capacity: text.count / 2)
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }

    public func readConfig() throws -> Data? {
        guard FileManager.default.fileExists(atPath: configURL.path) else { return nil }
        do { return try Data(contentsOf: configURL) } catch { throw ClaudeCodeError.config }
    }

    public func writeConfig(_ data: Data) throws {
        let fm = FileManager.default
        let mode = (try? fm.attributesOfItem(atPath: configURL.path))?[.posixPermissions] as? Int
        do {
            try data.write(to: configURL, options: [.atomic])
            if let mode { try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: configURL.path) }
        } catch {
            throw ClaudeCodeError.config
        }
    }
}

/// Asks Anthropic which account an access token belongs to.
public protocol ProfileChecking {
    func accountUUID(accessToken: String) async -> String?
}
