// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "Angy",
    targets: [
        .target(
            name: "AngyCore"
        ),
        .executableTarget(
            name: "Angy",
            dependencies: ["AngyCore"],
            path: "Sources/AngyApp"
        ),
        .testTarget(
            name: "AngyCoreTests",
            dependencies: ["AngyCore"]
        )
    ]
)
