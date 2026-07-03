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
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.1")
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
        .testTarget(
            name: "FoundationModelsMCPTests",
            dependencies: [
                "FoundationModelsMCP",
                .product(name: "MCP", package: "swift-sdk"),
            ]
        ),
    ]
)
