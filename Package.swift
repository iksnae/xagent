// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "xagent",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
    ],
    products: [
        .library(name: "XAgentCore", targets: ["XAgentCore"]),
        .executable(name: "xagentcli", targets: ["XAgentCLI"]),
    ],
    targets: [
        .target(
            name: "XAgentCore",
            path: "Sources/XAgentCore"
        ),
        .executableTarget(
            name: "XAgentCLI",
            dependencies: ["XAgentCore"],
            path: "Sources/XAgentCLI"
        ),
        .testTarget(
            name: "XAgentCoreTests",
            dependencies: ["XAgentCore"],
            path: "Tests/XAgentCoreTests"
        ),
    ]
)
