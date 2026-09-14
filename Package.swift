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
        ),
        // 「厂商原生配置」四模块的不变量测试（对齐 Windows 的 cargo test）。
        // 🚨 只依赖 BrewPingCore，**不要**依赖 BrewPingDesktop —— 后者链 SwiftUI App，
        //    swift test 会去启动 GUI。
        .testTarget(
            name: "BrewPingCoreTests",
            dependencies: ["BrewPingCore"],
            path: "Tests/BrewPingCoreTests"
        )
    ]
)
