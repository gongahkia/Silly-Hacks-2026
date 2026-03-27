// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "Angy",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .target(
            name: "AngyCore"
        ),
        .executableTarget(
            name: "Angy",
            dependencies: ["AngyCore"],
            path: "Sources/AngyApp",
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "AngyCoreTests",
            dependencies: ["AngyCore"]
        ),
        .testTarget(
            name: "AngyAppTests",
            dependencies: ["Angy"],
            path: "Tests/AngyAppTests"
        )
    ]
)
