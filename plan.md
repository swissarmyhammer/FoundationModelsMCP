# FoundationModelsMCP — Plan

A Swift package that lets an Apple **FoundationModels** `LanguageModelSession`
call tools served by any **Model Context Protocol (MCP)** server. It bridges the
official [`modelcontextprotocol/swift-sdk`](https://github.com/modelcontextprotocol/swift-sdk)
(the MCP client) to the FoundationModels `Tool` protocol.

> Target: WWDC26 / OS 27+ (and later). FoundationModels first shipped in OS 26;
> this package targets the newest OS where the framework and its dynamic-schema
> APIs are stable.

## Design principle: thin bridge, not a reimplementation

**Lean entirely on the official MCP `swift-sdk` for everything MCP.** All
connection lifecycle, transports (stdio + HTTP/SSE), the wire protocol, and the
MCP domain types — `MCP.Client`, `MCP.Tool`, `MCP.Value`, `MCP.Tool.Content` —
come from the SDK. We do **not** define our own MCP types, parse the protocol,
or wrap `Value` in a bespoke JSON model.

**Our entire net value-add is the FoundationModels half of the bridge** — the
code that the SDK cannot and should not contain:

- the `Tool`-conforming adapter,
- `MCP.Value` (inputSchema) → `GenerationSchema` at runtime, and
- `GeneratedContent` ⇄ `MCP.Value` conversion + MCP result rendering.

If a piece of work is "MCP plumbing," it belongs to the SDK and we just call it.
If it touches a FoundationModels type, it's ours. Everything in the plan below
is scoped to that line.

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
- `var includesSchemaInInstructions: Bool` (whether the schema is injected into
  the model's instructions — the adapter supplies this; `true` is the typical
  choice)
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

## Why this is better than naive tool calling: guaranteed-valid arguments

An MCP tool call is, fundamentally, "produce a JSON object that conforms to the
tool's `inputSchema`." FoundationModels has **constrained decoding** built in:
when the model emits a tool call, it is forced *at the token level* to produce
arguments that match that tool's `parameters: GenerationSchema`. Strict-mode
constrained decoding gives a formal guarantee — **100% schema-valid tool-call
arguments whenever a call is produced**.

This reframes what `SchemaConverter` is for. It is not merely *describing* the
expected shape to the model — it is **wiring the constraint that guarantees the
generated MCP arguments are well-formed**. The richer the `GenerationSchema` we
synthesize, the tighter the constraint, and the more failure modes vanish before
they happen:

- wrong types, missing required fields, malformed JSON → impossible by
  construction, so **no defensive validation or repair/retry loop** before
  `callTool`;
- enums / bounded values → the model can only pick valid options;
- so reliability comes from the schema, not from prompt-engineering or post-hoc
  fixups.

**Two levers the converter pulls:**

1. **Structure (hard constraints):** types, `required`, nesting, arrays, enums —
   enforced by constrained decoding.
2. **Guides (hard constraints, available at runtime):** JSON Schema `enum`,
   numeric `minimum`/`maximum`, string `pattern`, and `minItems`/`maxItems` map
   to real generation guides, plus `description` as a soft hint.

> ✅ **The rich constraints are runtime-expressible — this is *not* a blocker.**
> `@Guide` is a compile-time macro, but the same guides exist as runtime values:
> `DynamicGenerationSchema.init(type:guides:)` takes `[GenerationGuide<Value>]`,
> and `GenerationGuide` exposes runtime factories — `range(_:)` / `minimum(_:)` /
> `maximum(_:)`, `pattern(_:)` (a `Regex`), `count(_:)` / `minimumCount(_:)` /
> `maximumCount(_:)`, `anyOf(_:)`, `constant(_:)`. So numeric ranges, string
> regex, and array counts become **hard** constraints at runtime, not just
> description hints. Residual unknowns are narrow (see Still open #3): numeric
> guides are typed to `Decimal`, count-guide behavior on nested arrays, and
> whether every JSON Schema keyword maps cleanly. Anything that genuinely can't
> map still degrades to a logged description hint, per the fallback policy.
> *(Confirmed against Apple docs, not yet against a compiled SDK.)*

## Architecture

```
LanguageModelSession(tools: [MCPTool, MCPTool, ...])
        │  model decides to call a tool, emits GeneratedContent args
        ▼
   MCPTool  (conforms to FoundationModels.Tool)
        │  GeneratedContent ──► [String: MCP.Value]   (arg encoding)
        ▼
   MCP.Client.callTool(name:arguments:)
        │  [MCP.Tool.Content] + isError? + structuredContent?  (result)
        ▼
   ToolOutput / String  (PromptRepresentable) ──► back to the model
```

### Components

The three middle components are the value-add (they touch FoundationModels
types). The provider is a thin convenience over the SDK's `MCP.Client` — it owns
**no** protocol logic of its own.

1. **`MCPToolProvider`** (thin) — takes an already-connected `MCP.Client` (the
   caller owns connection/transport setup via the SDK), calls the SDK's
   `listTools()`, and maps each `MCP.Tool` into an `MCPTool`, vending
   `[any Tool]` for `LanguageModelSession(tools:)`. May offer optional helpers
   for tool-list refresh (`tools/list_changed`) and multi-client aggregation,
   but does not reimplement connection/reconnect — that's the SDK's job.

2. **`MCPTool`** ⭐ — the generic adapter conforming to `FoundationModels.Tool`.
   Holds the `MCP.Client`, the source `MCP.Tool` (name/description), and the
   precomputed `GenerationSchema`. Implements `call(arguments:)` by encoding args
   and delegating to the SDK's `client.callTool`.

3. **`SchemaConverter`** ⭐ — pure function converting an `MCP.Tool.inputSchema`
   (a `MCP.Value` carrying JSON Schema) into `DynamicGenerationSchema` →
   `GenerationSchema`. Consumes the SDK's `Value` directly — no bespoke JSON
   model. **This is the hardest part** (see schema-translation section).

4. **`GeneratedContentCodec`** ⭐ — converts FoundationModels `GeneratedContent`
   ⇄ the SDK's `MCP.Value`. Args go out (GeneratedContent → `Value` for
   `callTool`); used for round-tripping.

5. **`ToolContentRenderer`** ⭐ — converts the SDK's `callTool` result —
   `[MCP.Tool.Content]` (`.text`, `.image`, `.audio`, `.resource`,
   `.resourceLink`), `isError: Bool?` (treat `nil` as success), and
   `structuredContent: Value?` — into the adapter's `Output` (a
   `ToolOutput`/`String`) the model can consume. (Whether v1 surfaces
   `structuredContent` is a renderer decision; record it either way.)

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
| `minimum` / `maximum`           | `GenerationGuide.range(_:)` / `minimum`/`maximum` (runtime) |
| `pattern` (string regex)        | `GenerationGuide.pattern(_:)` with a `Regex` (runtime) |
| `minItems` / `maxItems`         | `GenerationGuide.count`/`minimumCount`/`maximumCount` (runtime) |

The last three are **constraint mapping**, not just shape: each is a real
runtime `GenerationGuide` (passed via `DynamicGenerationSchema(type:guides:)`),
so it becomes a **hard** constraint that makes constrained decoding tighter (see
"guaranteed-valid arguments"). Only constraints with no guide equivalent degrade
to a logged description hint.

Unsupported/edge JSON Schema (`anyOf`/`oneOf` unions, `additionalProperties`,
`patternProperties`, tuples, `not`, recursive `$ref`) need an explicit fallback
policy: degrade to a permissive type (e.g. a string the tool parses) and **log
what was dropped** rather than silently misrepresenting the schema.

## Milestones

- [ ] **M0 — Scaffold.** SwiftPM package; depend on
  `.product(name: "MCP", package: "swift-sdk")` and link `FoundationModels`.
  Decide module name(s). CI on macOS (Xcode for OS 27 SDK).
- [ ] **M1 — Schema translation.** `SchemaConverter` (`MCP.Value` →
  `GenerationSchema`) + the `GeneratedContent` ⇄ `MCP.Value` codec. Map JSON
  Schema constraints to runtime `GenerationGuide`s (enum/range/pattern/count) as
  hard constraints, degrading only the no-equivalent cases to logged description
  hints — tighter constraint = better constrained decoding. Unit-tested against a
  corpus of real MCP `inputSchema` values (no FoundationModels runtime needed for
  most of it).
- [ ] **M2 — `MCPTool` adapter.** Conform to `Tool`; wire `call(arguments:)` to
  the SDK's `client.callTool`; render results & errors via `ToolContentRenderer`.
- [ ] **M3 — `MCPToolProvider` (thin).** Map an already-connected `MCP.Client`'s
  `listTools()` into `[any Tool]`; optional tool-list refresh and multi-client
  aggregation; name collision handling. Connection/transport setup stays with the
  SDK and the caller — we don't reimplement it.
- [ ] **M4 — End-to-end.** A `LanguageModelSession` driven against a real local
  MCP server (e.g. stdio filesystem/echo server) doing an actual tool call.
- [ ] **M5 — Hardening.** Cancellation, timeouts, `isError` mapping, image/audio
  content handling, structured logging, docs + a sample. **Tool results are the
  context-window cost** (an MCP result can be huge), so `ToolContentRenderer`
  needs a size/trimming strategy — this is where Apple's
  [managing-the-context-window](https://developer.apple.com/documentation/foundationmodels/managing-the-context-window)
  transcript guidance applies (the *output* side, distinct from the
  constrained-decoding win on the *input* side).
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
2. **Min OS / SDK** — the swift-sdk floor (macOS 13 / iOS 16, Swift 6+ /
   Xcode 16+) is *well below* our target, so **FoundationModels is the sole
   binding minimum** (OS 26+ where `SystemLanguageModel` exists; we target OS 27).
   Nothing to reconcile beyond confirming the exact FoundationModels availability
   annotations and pinning the swift-sdk version.
3. **Constraint mapping edge cases** — the rich guides are confirmed
   runtime-expressible (see the ✅ note); the residual unknowns are narrow:
   numeric `GenerationGuide`s are typed to `Decimal` (handle JSON integer/number
   → `Decimal` cleanly), count-guide behavior on *nested* arrays, exclusive vs.
   inclusive bounds, and whether every JSON Schema keyword has a clean guide
   mapping. Pin these against the compiled SDK.

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
- `@Generable` / `@Guide` & constrained decoding — https://developer.apple.com/videos/play/wwdc2025/301/
- Managing the context window — https://developer.apple.com/documentation/foundationmodels/managing-the-context-window
