# FoundationModelsMCP

A Swift package that lets an Apple **FoundationModels** `LanguageModelSession`
call tools served by any **Model Context Protocol (MCP)** server. It bridges
the official [`modelcontextprotocol/swift-sdk`](https://github.com/modelcontextprotocol/swift-sdk)
(the MCP client) to the FoundationModels `Tool` protocol — no per-tool codegen,
one generic adapter backs every MCP tool.

Target: **OS 27+ only** (macOS 27 / iOS 27 and later).

## Quick start

The listing below is `Examples/EchoTool/EchoTool.swift`, byte for byte —
`Tests/FoundationModelsMCPTests/ReadmeQuickStartTests.swift` fails the build
the moment this snippet and that file diverge, so it can't rot silently.

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

Run it (spawns a local stdio subprocess, no network access):

```
swift run EchoTool
```

`connected.server` there is an `MCPServer` wrapping an already-connected
`MCP.Client`; `LanguageModelSession(mcp:)` is this package's convenience
initializer that awaits the server's tool discovery and adds every tool it
finds. Real servers are added the same way — swap the spawned
`MCPTestServerCLI` subprocess in `ExampleSupport` for any `StdioTransport` or
`HTTPClientTransport` connection you build yourself.

## Adding it to your package

```swift
dependencies: [
    .package(url: "https://github.com/swissarmyhammer/FoundationModelsMCP.git", branch: "main"),
],
targets: [
    .target(
        name: "YourTarget",
        dependencies: ["FoundationModelsMCP"]
    )
]
```

**Dependencies: swift-sdk + FoundationModels only.** The only external
runtime dependency is the official MCP `swift-sdk` (plus `swift-log` for
structured logging), and the system `FoundationModels` framework. There is
**no MLX and no model router dependency** — this package never drives
generation itself (see "Declare vs. enforce" below), so it has nothing to
gain from depending on either.

## What this package is — and isn't

This package **directly exposes MCP tools to a session**: add an `MCPServer`
(all of a connected server's tools) or a single `MCPTool` to
`LanguageModelSession(mcp:)`. That's the right shape for a curated handful of
tools, where every schema can afford to sit in the session's instructions.

It deliberately does **not** do tool *search* — deferring a large catalog and
surfacing tools to the model on demand. That's the job of two separate,
planned/future sibling projects that build on this one:

- **`FoundationModelsMultitool`** — composes many `MCPServer`s and loose
  `Tool`s into one searchable namespace, consuming this package's live
  catalog surface (`MCPServer.catalog` / `catalogUpdates` — see the DocC
  catalog's "The catalog consumer contract" article).
- **`FoundationModelsRouter`** — model selection, used by Multitool to back
  its search, not by this package.

### Declare vs. enforce

This bridge never drives generation — it **declares** each tool's argument
shape (converting the MCP `inputSchema` into a `GenerationSchema`), and the
session's own model **enforces** that shape via constrained decoding while
arguments are generated. The bridge is a pass-through after that: encode the
generated arguments, call the tool, render the result — the MCP server itself
is the real validator of anything the schema conversion couldn't capture. See
the DocC catalog's "The enforcement model" article for the full story,
including what `ToolContentRenderer`'s `outputSchema` check does and doesn't
guarantee.

## Documentation

Full API reference — every public symbol, plus the consumer-contract and
enforcement-model articles referenced above — is a DocC catalog:

```
swift package generate-documentation --target FoundationModelsMCP
```

Or in Xcode: **Product → Build Documentation**.

## Examples

Each is a small, runnable executable target (`swift run <Name>`), kept
compiling in CI — together they're the living documentation of every
capability this package provides:

- **`EchoTool`** — the quick start above.
- **`FileAssistant`** — a real multi-tool stdio filesystem server; the model
  picks among several tools, including recovering from an `isError` result.
- **`ToolPicking`** — a loose `MCPTool` plus a native Swift `Tool` in the same
  session, showing `MCPToolProvider` composition.
- **`RemoteHTTP`** — connects to a remote server over `HTTPClientTransport`
  with a host-supplied bearer token.
- **`ElicitingAgent`** — both elicitation directions (a server tool that asks
  the user a question, and the model asking one itself) through one console
  `ElicitationCoordinator`.
- **`CatalogBrowser`** — connects one or more servers and prints the full
  live catalog surface for every discovered tool.
- **`DynamicToolset`** — a server that adds, removes, and re-schemas a tool on
  a timer; prints every catalog snapshot and demonstrates resolving a call
  against a tool that just vanished.

## Testing

```
swift build && swift test
```

See `plan.md` at the repository root for the full design rationale, including
the schema-translation table, the connection-lifecycle/resilience policy, and
every milestone's acceptance criteria.
