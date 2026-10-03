// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "romsen",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .target(name: "AXTree"),
        .target(name: "AXSnapshot", dependencies: ["AXTree"]),
        .target(name: "SlackAdapter", dependencies: ["AXTree"]),
        .executableTarget(
            name: "romsen",
            dependencies: [
                "AXTree",
                "AXSnapshot",
                "SlackAdapter",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(name: "SlackAdapterTests", dependencies: ["SlackAdapter", "AXTree"]),
        .testTarget(name: "RomsenTests", dependencies: ["romsen", "AXTree", "SlackAdapter"]),
    ]
)
