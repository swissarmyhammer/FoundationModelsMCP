# FoundationModelsMCP — Plan

A Swift package that lets an Apple **FoundationModels** `LanguageModelSession`
call tools served by any **Model Context Protocol (MCP)** server. It bridges the
official [`modelcontextprotocol/swift-sdk`](https://github.com/modelcontextprotocol/swift-sdk)
(the MCP client) to the FoundationModels `Tool` protocol.

> Target: WWDC26 / OS 27+ (and later). FoundationModels first shipped in OS 26;
> this package targets the newest OS where the framework and its dynamic-schema
> APIs are stable.

## Problem

The MCP Swift SDK gives you a `Client` that connects to MCP servers and can
`listTools()` / `callTool(name:arguments:)`. FoundationModels gives you
`LanguageModelSession(tools:)` where each tool conforms to the `Tool` protocol.
There is **no shipping package that wires the two together** — you cannot today
hand an MCP server's tools to a `LanguageModelSession`. This package is that
glue.

## Why it's feasible (the key insight)

The FoundationModels `Tool` protocol requires:

- `associatedtype Arguments: ConvertibleFromGeneratedContent`
- `associatedtype Output: PromptRepresentable`
- `var name: String`, `var description: String`
- `var parameters: GenerationSchema` (the tool's input schema)
- `func call(arguments: Arguments) async throws -> Output`

MCP tools have a *dynamic* JSON Schema (`inputSchema`) known only at runtime, so
we can't generate a static `@Generable` Swift struct per tool. But we don't need
to:

- `GeneratedContent` conforms to `ConvertibleFromGeneratedContent`, so a single
  generic adapter can set `typealias Arguments = GeneratedContent`.
- `GenerationSchema` can be built at runtime from `DynamicGenerationSchema`
  (`GenerationSchema(root:dependencies:)`), so we synthesize each tool's
  `parameters` from its MCP `inputSchema`.

So **one generic adapter type** (`MCPTool`) backs *every* MCP tool — no codegen,
no per-tool Swift types.

## Architecture

```
LanguageModelSession(tools: [MCPTool, MCPTool, ...])
        │  model decides to call a tool, emits GeneratedContent args
        ▼
   MCPTool  (conforms to FoundationModels.Tool)
        │  GeneratedContent ──► [String: MCP.Value]   (arg encoding)
        ▼
   MCP.Client.callTool(name:arguments:)
        │  [MCP.Tool.Content] + isError                (result)
        ▼
   ToolOutput / String  (PromptRepresentable) ──► back to the model
```

### Components

1. **`MCPToolProvider`** — owns one or more `MCP.Client` connections, calls
   `client.connect(transport:)`, caches `listTools()`, and vends
   `[any Tool]` ready to pass to `LanguageModelSession(tools:)`. Handles
   reconnect, tool-list refresh (MCP `tools/list_changed`), and shutdown.

2. **`MCPTool`** — the generic adapter conforming to `FoundationModels.Tool`.
   Holds a reference to its provider/client, its MCP tool name & description, and
   the precomputed `GenerationSchema`. Implements `call(arguments:)` by encoding
   args and delegating to `client.callTool`.

3. **`JSONSchemaToGenerationSchema`** — pure function converting an MCP
   `inputSchema` (JSON Schema) into `DynamicGenerationSchema` → `GenerationSchema`.
   **This is the hardest part** (see Risks).

4. **`GeneratedContentCodec`** — converts `GeneratedContent` ⇄ `MCP.Value`
   (JSON). Args go out (GeneratedContent → Value); used for round-tripping.

5. **`ToolContentRenderer`** — converts MCP `[Tool.Content]` (`.text`, `.image`,
   `.audio`, `.resource`, `.resourceLink`) + `isError` into the adapter's
   `Output` (a `ToolOutput`/`String`) the model can consume.

## The schema translation (core risk, plan it explicitly)

Map JSON Schema → `DynamicGenerationSchema`:

| JSON Schema                     | DynamicGenerationSchema                          |
|---------------------------------|--------------------------------------------------|
| `type: object` + `properties`   | `DynamicGenerationSchema(name:properties:)`      |
| `required: [...]`               | mark `Property` non-optional                      |
| `type: string/integer/number/boolean` | `DynamicGenerationSchema(type: …)`         |
| `type: array`, `items`          | array-of schema                                   |
| `enum: [...]`                   | anyOf / choices schema                             |
| nested `object`                 | nested `DynamicGenerationSchema` as property schema |
| `$ref` / `$defs`                | named schema + `dependencies:`                     |
| `description`                   | `Property.description` (doubles as a model guide)  |

Unsupported/edge JSON Schema (`anyOf`/`oneOf` unions, `additionalProperties`,
`patternProperties`, tuples, `not`, recursive `$ref`) need an explicit fallback
policy: degrade to a permissive type (e.g. a string the tool parses) and **log
what was dropped** rather than silently misrepresenting the schema.

## Milestones

- [ ] **M0 — Scaffold.** SwiftPM package; depend on
  `.product(name: "MCP", package: "swift-sdk")` and link `FoundationModels`.
  Decide module name(s). CI on macOS (Xcode for OS 27 SDK).
- [ ] **M1 — Schema translation.** `JSONSchemaToGenerationSchema` + the
  `GeneratedContent` ⇄ `Value` codec. Unit-tested against a corpus of real MCP
  `inputSchema` JSON (no FoundationModels runtime needed for most of it).
- [ ] **M2 — `MCPTool` adapter.** Conform to `Tool`; wire `call(arguments:)` to
  `client.callTool`; render results & errors via `ToolContentRenderer`.
- [ ] **M3 — `MCPToolProvider`.** Connection lifecycle, stdio + HTTP transports,
  tool-list caching/refresh, multi-server aggregation, name collision handling.
- [ ] **M4 — End-to-end.** A `LanguageModelSession` driven against a real local
  MCP server (e.g. stdio filesystem/echo server) doing an actual tool call.
- [ ] **M5 — Hardening.** Cancellation, timeouts, `isError` mapping, image/audio
  content handling, structured logging, docs + a sample.
- [ ] **M6 — Sample app.** A small demo target (CLI or app) that connects to a
  real local MCP server over stdio, registers its tools on a
  `LanguageModelSession`, and runs a prompt that triggers a tool call. Doubles as
  the human-facing E2E.

## Testing strategy

- **Schema translation**: table-driven unit tests over a JSON-Schema corpus
  (asserting structure/required/types/fallbacks). Pure, fast, no model needed.
- **Codec**: round-trip `GeneratedContent` ⇄ `Value` property tests.
- **Adapter**: inject a mock `Client` (or in-process MCP server) to verify the
  `callTool` name/arguments and result rendering without a live model.
- **E2E**: gated/optional test that needs the OS 27 SDK + on-device model;
  drives a real stdio MCP server. Kept out of the default unit run.

## Decisions

- **Scope (decided):** consume-only for v1 — MCP server tools → usable in a
  `LanguageModelSession` — **plus a sample app** (see M6). The reverse direction
  (expose FoundationModels as an MCP *server*) is explicitly out of scope for v1.
- **Transports (decided):** ship **stdio + HTTP** from the start
  (`StdioTransport` for local subprocess servers, `HTTPClientTransport` for
  remote/SSE), since swift-sdk provides both cheaply.

### Still open

1. **Module/package name** — e.g. `FoundationModelsMCP` with a single `MCPTools`
   product (and a separate sample target).
2. **Min OS / SDK** — confirm exact FoundationModels availability annotations
   for the OS 27 target, and pin swift-sdk version.

## Prior art

We are building our own. This section records what already exists so we can
learn from it, not adopt it.

- **`sutheesh/SwiftMCP`** (Sutheesh Sukumaran) — announced on
  [Swift Forums](https://forums.swift.org/t/swiftmcp-connect-apples-foundation-models-to-any-mcp-server/85971)
  as exactly this bridge: Foundation Models ↔ any MCP server, runtime tool
  discovery via `DynamicGenerationSchema`, a `SchemaConverter`, stdio + HTTP/SSE,
  Swift 6 strict concurrency, MIT, single dependency on the official MCP SDK.
  Accompanies a "MobileMCP" research paper. **Independent confirmation that our
  core technique (DynamicGenerationSchema + schema converter) is the right one.**
  ⚠️ **The GitHub repo currently 404s** — checked via WebFetch, `gh api`, and the
  user's repo list (no `SwiftMCP` repo present). Deleted, renamed, or made
  private since the announcement, so there is no installable artifact to adopt or
  diff against. *Worth understanding why it vanished before we rely on the
  approach (paper embargo? superseded? pulled?).*
- **Other `SwiftMCP` repos are NOT this** — `Cocoanetics/SwiftMCP`,
  `Compiler-Inc/SwiftMCP`, `gavinaboulhosn/SwiftMCP`, `jpurnell/SwiftMCPClient`,
  etc. are MCP server/client *protocol* implementations, not the
  `LanguageModelSession` dynamic-schema tool bridge.
- **`AnyLanguageModel`** (Hugging Face) — a unified API across local/remote LLMs
  on Apple platforms; not an MCP tool bridge.

## References

- MCP Swift SDK — https://github.com/modelcontextprotocol/swift-sdk
- FoundationModels `Tool` protocol — https://blakecrosley.com/blog/foundation-models-on-device-llm
- Dynamic schemas in FoundationModels — https://justin.searls.co/posts/how-to-generate-dynamic-data-structures-with-apple-foundation-models/
