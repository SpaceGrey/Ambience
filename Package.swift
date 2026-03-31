// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Ambience",
    platforms: [
        .iOS(.v15),
        .visionOS(.v1),
        .tvOS(.v16),
        .watchOS(.v9),
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "Ambience",
            targets: ["Ambience"]),
        .library(
            name: "AmbienceCore",
            targets: ["AmbienceCore"]),
        .executable(
            name: "ambience-cli",
            targets: ["AmbienceCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/tid-kijyun/Kanna.git", from: "5.3.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "AmbienceCore",
            dependencies: ["Kanna"]
        ),
        .target(
            name: "Ambience",
            dependencies: ["AmbienceCore", "Kanna"]
        ),
        .executableTarget(
            name: "AmbienceCLI",
            dependencies: [
                "AmbienceCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "AmbienceTests",
            dependencies: ["Ambience"]
        ),
    ]
)
