// swift-tools-version: 6.2
// Single-writer file (orchestrator). Every target of PLAN 2.3 is declared here up front.

import PackageDescription

let package = Package(
    name: "Kit",
    defaultLocalization: "en",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "ScanKit", targets: ["ScanKit"]),
        .library(name: "RulesKit", targets: ["RulesKit"]),
        .library(name: "CleanupKit", targets: ["CleanupKit"]),
        .library(name: "IPCProtocol", targets: ["IPCProtocol"]),
        .library(name: "MCPServerKit", targets: ["MCPServerKit"]),
        .library(name: "AIBridge", targets: ["AIBridge"]),
        .library(name: "VizKit", targets: ["VizKit"]),
        .library(name: "AppCore", targets: ["AppCore"]),
        .library(name: "TestSupport", targets: ["TestSupport"]),
        .executable(name: "scanbench", targets: ["scanbench"]),
        .executable(name: "mcp-helper", targets: ["mcp-helper"]),
        .executable(name: "fake-claude", targets: ["fake-claude"]),
    ],
    targets: [
        // Libraries
        .target(
            name: "ScanKit",
            linkerSettings: [
                .linkedFramework("DiskArbitration"),
                .linkedFramework("CoreServices"),
            ]
        ),
        .target(
            name: "RulesKit",
            dependencies: ["ScanKit"],
            resources: [.process("Resources")]
        ),
        .target(
            name: "CleanupKit",
            dependencies: ["ScanKit", "RulesKit"]
        ),
        .target(name: "IPCProtocol"),
        .target(
            name: "MCPServerKit",
            dependencies: ["IPCProtocol"]
        ),
        .target(
            name: "AIBridge",
            dependencies: ["IPCProtocol"]
        ),
        .target(name: "VizKit"),
        .target(
            name: "AppCore",
            dependencies: ["ScanKit", "RulesKit", "CleanupKit", "IPCProtocol", "AIBridge", "VizKit"]
        ),
        .target(
            name: "TestSupport",
            dependencies: ["ScanKit"]
        ),

        // Executables
        .executableTarget(name: "scanbench", dependencies: ["ScanKit"]),
        .executableTarget(name: "mcp-helper", dependencies: ["MCPServerKit"]),
        .executableTarget(name: "fake-claude", dependencies: ["IPCProtocol"]),

        // Tests (Swift Testing)
        .testTarget(name: "ScanKitTests", dependencies: ["ScanKit", "TestSupport"]),
        .testTarget(name: "RulesKitTests", dependencies: ["RulesKit", "TestSupport"]),
        .testTarget(name: "CleanupKitTests", dependencies: ["CleanupKit", "TestSupport"]),
        .testTarget(name: "IPCProtocolTests", dependencies: ["IPCProtocol"]),
        .testTarget(name: "MCPServerKitTests", dependencies: ["MCPServerKit", "TestSupport"]),
        .testTarget(name: "AIBridgeTests", dependencies: ["AIBridge", "TestSupport"]),
        .testTarget(name: "VizKitTests", dependencies: ["VizKit"]),
        .testTarget(name: "AppCoreTests", dependencies: ["AppCore", "TestSupport"]),
        .testTarget(name: "TestSupportTests", dependencies: ["TestSupport", "ScanKit"]),
    ],
    swiftLanguageModes: [.v6]
)
