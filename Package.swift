// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TokenMonitor",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "TokenMonitor", targets: ["TokenApp"]),
        .library(name: "TokenCore", targets: ["TokenCore"])
    ],
    targets: [
        .target(
            name: "TokenCore",
            dependencies: [],
            path: "Sources/TokenCore"
        ),
        .executableTarget(
            name: "TokenApp",
            dependencies: ["TokenCore"],
            path: "Sources/TokenApp",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "TokenTests",
            dependencies: ["TokenCore"],
            path: "Tests"
        )
    ]
)
