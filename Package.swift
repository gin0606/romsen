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
        .target(
            name: "RomsenSlack",
            dependencies: [
                "AXTree",
                "AXSnapshot",
                "SlackAdapter",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(
            name: "romsen",
            dependencies: [
                "RomsenSlack",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(name: "AXTreeTests", dependencies: ["AXTree"]),
        .testTarget(name: "SlackAdapterTests", dependencies: ["SlackAdapter", "AXTree"]),
        .testTarget(name: "RomsenSlackTests", dependencies: ["RomsenSlack", "SlackAdapter", "AXTree", "romsen"]),
        .testTarget(name: "RomsenTests", dependencies: ["romsen"]),
    ]
)
