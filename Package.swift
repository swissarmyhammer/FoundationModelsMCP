// swift-tools-version:6.1
import PackageDescription

/// Linker settings for every target that directly imports the system
/// `FoundationModels` framework — the library target itself, `ExampleSupport`,
/// and every `Examples/` executable target.
///
/// Shared so the framework name isn't repeated as a literal at each of
/// those six call sites.
let foundationModelsLinkerSettings: [LinkerSetting] = [
    .linkedFramework("FoundationModels")
]

/// The swift-sdk's `MCP` product — every target in this manifest depends on
/// it directly (protocol types, `Value`, transports, `Client`).
///
/// Shared so the package name isn't repeated as a literal at each of those
/// call sites.
let mcpProduct: Target.Dependency = .product(name: "MCP", package: "swift-sdk")

/// The shared dependency list for every `Examples/` executable target
/// (`EchoTool`, `FileAssistant`, `ToolPicking`, `RemoteHTTP`): the shipped
/// library, the shared ``mcpProduct``, and the `ExampleSupport` support
/// library those four targets all depend on.
let exampleTargetDependencies: [Target.Dependency] = [
    "FoundationModelsMCP",
    "ExampleSupport",
    mcpProduct,
]

/// The four `Examples/` executable targets (plan.md → Examples §1–4), all
/// sharing the same dependencies, linker settings, and target shape —
/// differing only in name and source path:
///
/// - `EchoTool` (§1): spawn `MCPTestServerCLI` in echo mode, wrap it in
///   `MCPServer`, and drive one tool call on the system model.
/// - `FileAssistant` (§2): a multi-tool stdio filesystem server; the model
///   picks among several tools, including `isError` bubbling on a
///   missing-file prompt.
/// - `ToolPicking` (§3): one loose `MCPTool` plus a native Swift `Tool` in
///   the same session, showing `MCPToolProvider` flattening.
/// - `RemoteHTTP` (§4): `HTTPClientTransport` with a host-supplied bearer
///   token, demonstrating the delegated-auth decision.
///
/// Expressed as a data table mapped into targets (rather than four
/// hand-duplicated `.executableTarget()` blocks) so the shared shape can't
/// drift out of lockstep as examples are added or renamed.
let exampleTargetSpecs: [(name: String, path: String)] = [
    ("EchoTool", "Examples/EchoTool"),
    ("FileAssistant", "Examples/FileAssistant"),
    ("ToolPicking", "Examples/ToolPicking"),
    ("RemoteHTTP", "Examples/RemoteHTTP"),
]

let exampleTargets: [Target] = exampleTargetSpecs.map { spec in
    .executableTarget(
        name: spec.name,
        dependencies: exampleTargetDependencies,
        path: spec.path,
        linkerSettings: foundationModelsLinkerSettings
    )
}

/// The `FoundationModelsMCP` package manifest: one shipped library target
/// (`FoundationModelsMCP`), the test-fixture-only `MCPTestServer` utility
/// (never a library dependency — see
/// `Tests/FoundationModelsMCPTests/PackageDependencyTests.swift`) and its
/// `MCPTestServerCLI` stdio wrapper, the `ExampleSupport` helper library, and
/// the four `Examples/` executable targets (`EchoTool`, `FileAssistant`,
/// `ToolPicking`, `RemoteHTTP`) documented in `plan.md`'s "Examples" section.
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
                mcpProduct,
                .product(name: "Logging", package: "swift-log"),
            ],
            linkerSettings: foundationModelsLinkerSettings
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
                mcpProduct,
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
                mcpProduct,
            ]
        ),
        // Shared, non-test support code for the Examples/ targets below —
        // e.g. the MCPTestServerCLI subprocess-spawning plumbing EchoTool,
        // FileAssistant, and ToolPicking all need. Deliberately its own
        // small library target (never the FoundationModelsMCP library
        // product's dependency, and never MCPTestServer/the test target)
        // so "Examples never import the test target" holds while still
        // avoiding duplicating that plumbing three times over.
        .target(
            name: "ExampleSupport",
            dependencies: [
                "FoundationModelsMCP",
                mcpProduct,
            ],
            path: "Examples/Support",
            linkerSettings: foundationModelsLinkerSettings
        ),
    ] + exampleTargets + [
        .testTarget(
            name: "FoundationModelsMCPTests",
            dependencies: [
                "FoundationModelsMCP",
                "MCPTestServer",
                "ExampleSupport",
                "RemoteHTTP",
                mcpProduct,
            ],
            resources: [
                .copy("Fixtures")
            ]
        ),
    ]
)
