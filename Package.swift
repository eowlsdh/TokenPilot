// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TokenMonitor",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "TokenMonitor", targets: ["TokenApp"]),
        .executable(name: "CapacityForecastBacktest", targets: ["CapacityForecastBacktest"]),
        .library(name: "TokenCore", targets: ["TokenCore"])
    ],
    targets: [
        .target(
            name: "TokenCore",
            dependencies: [],
            path: "Sources/TokenCore",
            exclude: ["AGENTS.md"]
        ),
        .executableTarget(
            name: "TokenApp",
            dependencies: ["TokenCore"],
            path: "Sources/TokenApp",
            exclude: ["AGENTS.md"],
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "CapacityForecastBacktest",
            dependencies: ["TokenCore"],
            path: "Tools/CapacityForecastBacktest"
        ),
        .testTarget(
            name: "TokenTests",
            dependencies: ["TokenCore"],
            path: "Tests",
            exclude: ["AGENTS.md", "Fixtures"]
        )
    ]
)
