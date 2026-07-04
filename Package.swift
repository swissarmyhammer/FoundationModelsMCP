// swift-tools-version:6.1
import PackageDescription

let package = Package(
    name: "FoundationModelsMCP",
    platforms: [
        .macOS("27"),
        .iOS("27"),
    ],
    products: [
        .library(
            name: "FoundationModelsMCP",
            targets: ["FoundationModelsMCP"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.1"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.14.0"),
    ],
    targets: [
        .target(
            name: "FoundationModelsMCP",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk")
            ],
            linkerSettings: [
                .linkedFramework("FoundationModels")
            ]
        ),
        // Test-fixture-only utility target: a scriptable MCP server test
        // double for FoundationModelsMCPTests and future Examples/
        // executables. Deliberately never listed as a dependency of the
        // FoundationModelsMCP library target above — see
        // Tests/FoundationModelsMCPTests/PackageDependencyTests.swift, which
        // asserts that in source.
        .target(
            name: "MCPTestServer",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        // Minimal stdio executable wrapper around MCPTestServer, so the
        // scripted server can also run as a spawned subprocess (for future
        // Examples/E2E use) rather than only in-process in tests.
        .executableTarget(
            name: "MCPTestServerCLI",
            dependencies: [
                "MCPTestServer",
                .product(name: "MCP", package: "swift-sdk"),
            ]
        ),
        .testTarget(
            name: "FoundationModelsMCPTests",
            dependencies: [
                "FoundationModelsMCP",
                "MCPTestServer",
                .product(name: "MCP", package: "swift-sdk"),
            ],
            resources: [
                .copy("Fixtures")
            ]
        ),
    ]
)
