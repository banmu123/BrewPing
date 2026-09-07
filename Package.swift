// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BrewPing",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        // 共享核心库：Protocol / Agents / App / PTY / Session
        // Desktop 和 CLI 两个 executable 都依赖它，不重复实现。
        .target(
            name: "BrewPingCore",
            path: "Sources",
            exclude: ["BrewPing", "BrewPingDesktop"]
        ),
        // 现有 CLI（brewping start/status/send/stop/attach）
        .executableTarget(
            name: "BrewPing",
            dependencies: ["BrewPingCore"],
            path: "Sources/BrewPing"
        ),
        // Phase 4A: macOS Menu Bar Desktop Receiver
        .executableTarget(
            name: "BrewPingDesktop",
            dependencies: ["BrewPingCore"],
            path: "Sources/BrewPingDesktop"
        )
    ]
)
