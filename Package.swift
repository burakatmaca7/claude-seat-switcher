// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClaudeSeatSwitcher",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ClaudeSeatSwitcher",
            path: "Sources/ClaudeSeatSwitcher",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "ClaudeSeatSwitcherTests",
            dependencies: ["ClaudeSeatSwitcher"],
            path: "Tests/ClaudeSeatSwitcherTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
