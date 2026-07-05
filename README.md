# FoundationModelsMCP

[![CI](https://github.com/swissarmyhammer/FoundationModelsMCP/actions/workflows/ci.yml/badge.svg)](https://github.com/swissarmyhammer/FoundationModelsMCP/actions/workflows/ci.yml)

Bridges Apple's FoundationModels `LanguageModelSession` to tools served by any
**Model Context Protocol (MCP)** server — one generic adapter backs every MCP
tool, no per-tool codegen. The only dependencies are the official MCP
[`swift-sdk`](https://github.com/modelcontextprotocol/swift-sdk) and the
system `FoundationModels` framework (no MLX, no model router). Requires
macOS 27 / iOS 27 or later.

The listing below is `Examples/EchoTool/EchoTool.swift`, byte for byte — a
test fails the build the moment this snippet and that file diverge.

<!-- ECHOTOOL-SNIPPET:START -->
```swift
import ExampleSupport
import FoundationModels
import FoundationModelsMCP

/// `EchoTool` is the ~20-line hello world of this bridge: spawn
/// `MCPTestServerCLI` in echo mode as a stdio subprocess, wrap it in
/// `MCPServer`, build a `LanguageModelSession(mcp:)` on the system model, and
/// run one prompt that triggers one tool call — plan.md → Examples §1.
@main
struct EchoTool {
    /// The `MCPTestServerCLI` `--mode` value selecting its echo-only tool set.
    static let serverMode = "echo"

    /// Runs the example: spawns the echo-mode `MCPTestServerCLI` subprocess,
    /// connects an `MCPServer` to it, and drives one prompt that triggers one
    /// tool call.
    ///
    /// Prints a clean, non-crashing message and returns early if
    /// `SystemLanguageModel` is unavailable on this machine.
    ///
    /// - Throws: Whatever ``runExample(named:mode:clientName:isAvailable:body:)``
    ///   or `session.respond(to:)` throws.
    static func main() async throws {
        try await runExample(named: "EchoTool", mode: serverMode, clientName: "EchoToolExample") { connected in
            let session = try await LanguageModelSession(
                mcp: connected.server,
                instructions:
                    "You have access to an echo tool that returns its \"text\" argument back verbatim. When asked to echo something, call the echo tool with exactly the requested text."
            )

            let response = try await session.respond(
                to: "Call the echo tool with the text \"hello from EchoTool\" and tell me exactly what it returned."
            )
            print(response.content)
        }
    }
}
```
<!-- ECHOTOOL-SNIPPET:END -->

Run it with `swift run EchoTool` (spawns a local stdio subprocess, no network
access). Connect a real server the same way — swap the spawned subprocess for
any `StdioTransport` or `HTTPClientTransport` you build yourself.

## Install

```swift
.package(url: "https://github.com/swissarmyhammer/FoundationModelsMCP.git", branch: "main")
```

## Documentation

Full API reference, plus articles on the enforcement model (how schema
constraints are declared here and enforced by the session's model) and the
live catalog consumer contract, is a DocC catalog:

```
swift package generate-documentation --target FoundationModelsMCP
```

Six more runnable examples live in `Examples/` — a multi-tool filesystem
assistant, mixing MCP with native tools, a remote HTTP server, elicitation,
and the live catalog — each run with `swift run <Name>`. See `plan.md` at the
repository root for the full design rationale.
