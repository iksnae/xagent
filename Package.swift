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
        .library(name: "XAgentHTTP", targets: ["XAgentHTTP"]),
        .executable(name: "xagentcli", targets: ["XAgentCLI"]),
        .executable(name: "xagentd", targets: ["XAgentDaemon"]),
        .executable(name: "XAgentApp", targets: ["XAgentApp"]),
    ],
    targets: [
        .systemLibrary(
            name: "CSQLite3",
            path: "Sources/CSQLite3"
        ),
        .target(
            name: "XAgentCore",
            dependencies: ["CSQLite3"],
            path: "Sources/XAgentCore"
        ),
        .target(
            name: "XAgentHTTP",
            dependencies: [],
            path: "Sources/XAgentHTTP"
        ),
        .executableTarget(
            name: "XAgentCLI",
            dependencies: ["XAgentCore"],
            path: "Sources/XAgentCLI"
        ),
        .executableTarget(
            name: "XAgentDaemon",
            dependencies: ["XAgentCore", "XAgentHTTP"],
            path: "Sources/XAgentDaemon"
        ),
        .executableTarget(
            name: "XAgentApp",
            dependencies: [],
            path: "Sources/XAgentApp"
        ),
        .testTarget(
            name: "XAgentCoreTests",
            dependencies: ["XAgentCore"],
            path: "Tests/XAgentCoreTests"
        ),
        .testTarget(
            name: "XAgentDaemonTests",
            dependencies: ["XAgentDaemon"],
            path: "Tests/XAgentDaemonTests"
        ),
    ]
)
