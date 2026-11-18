// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "CodeUsage",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "CodeUsage",
            path: "Sources/CodeUsage",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
