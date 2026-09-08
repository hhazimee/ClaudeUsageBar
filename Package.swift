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
