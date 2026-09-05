// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BrewPing",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "BrewPing",
            path: "Sources"
        )
    ]
)
