# FoundationModelsMCP — Plan

A Swift package that lets an Apple **FoundationModels** `LanguageModelSession`
call tools served by any **Model Context Protocol (MCP)** server. It bridges the
official [`modelcontextprotocol/swift-sdk`](https://github.com/modelcontextprotocol/swift-sdk)
(the MCP client) to the FoundationModels `Tool` protocol.

> Target: **OS 27+ only** (macOS 27 / iOS 27 and later). No back-deployment to OS
> 26, **no `@available` branching, no degrade path** — the framework and its
> dynamic-schema APIs are assumed stable at the OS 27 floor, so compatibility code
> is omitted by design. (See Decisions → Min OS.)

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
tool's `inputSchema`." The FoundationModels API enforces **constrained decoding**
at the tool-call boundary: when the model emits a tool call, it is forced *at the
token level* to produce arguments that match that tool's
`parameters: GenerationSchema` — a formal guarantee, **100% schema-valid
tool-call arguments whenever a call is produced**. *Which engine* delivers that
guarantee depends on the model backing the session — Apple's built-in guided
generation on `SystemLanguageModel`, or xgrammar under an MLX-backed session
(see **Models & enforcement**, next section). The bridge code below is identical
for both.

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

## Models & enforcement: we declare, the session enforces

The bridge never drives generation. `MCPTool` **declares** each tool's argument
shape (`parameters: GenerationSchema`); **enforcing** it while the arguments are
generated is the job of whatever engine backs the `LanguageModelSession`:

- **Apple `SystemLanguageModel`** — Apple's built-in guided generation (closed;
  enforcement strength must be verified — Still open #3).
- **MLX-backed session** — `MLXLanguageModel` from
  [`swissarmyhammer/mlx-swift-lm`](https://github.com/swissarmyhammer/mlx-swift-lm)
  (`MLXFoundationModels` + `MLXGuidedGeneration`), a drop-in model for
  `LanguageModelSession` whose generation is **xgrammar-constrained** (logit
  masking) — the inspectable, verifiable engine (xgrammar cannot attach to the
  closed system model — no logit access — so the two engines are what they
  are). **This package does not depend on mlx-swift-lm or MLX**: the
  FoundationModels API is the seam, so an MLX-backed session works through the
  bridge with zero MCP-side code — the host (or FoundationModelsMultitool, via
  Router) supplies the model. Engine-level verification of xgrammar enforcement
  lives downstream, where MLX is actually a dependency.

The bridge code is identical over both; the host picks the model at session
construction. Two consequences:

- **Declaration vs. enforcement.** By the time `MCPTool.call(arguments:)` runs,
  the args were already generated (and constrained) upstream — the adapter is a
  pass-through: encode args → `client.callTool` → render the result. No
  validation or repair layer in the tool; the **MCP server is the real
  validator**, and its `isError` result bubbles back to the model, which adjusts
  and retries with full context.
- **Expose the raw schema.** Alongside the converted `GenerationSchema`,
  `MCPTool` / `MCPServer` expose the **original MCP `inputSchema` verbatim** as
  plain data — the integration point for drivers that *do* own generation (e.g.
  **FoundationModelsMultitool**, constraining calls with xgrammar at full schema
  fidelity — `anyOf`/`oneOf`/`additionalProperties` — instead of our lossy
  `GenerationSchema` mapping).

## Scaling to many tools: out of scope — see FoundationModelsMultitool

This package **directly exposes tools**: add an `MCPServer` (all its tools) or
individual `MCPTool`s to `LanguageModelSession(tools:)`. Every exposed tool's
schema lands in the session's instructions — right for a curated handful.

Tool *search* — deferring a large catalog and surfacing tools on demand (the
Claude Code [MCP tool search](https://code.claude.com/docs/en/mcp#scale-with-mcp-tool-search)
pattern) — is deliberately **not in this package**. It is an agent-architecture
concern, and it lives in **`swissarmyhammer/FoundationModelsMultitool`**, which
builds on this package (it consumes the catalog below) and on
FoundationModelsRouter for the search model.

**What this package provides to enable that: the catalog as plain data.**
`MCPServer` exposes every tool as inspectable values — server identity, tool
name, `title`, description, the **raw MCP `inputSchema`**, the converted
`GenerationSchema`, `ToolAnnotations`, and icons — so Multitool (or a host UI:
pickers, autocomplete) can build on it. Values only; no search, no UI logic here.

**And the catalog is live.** MCP tool sets are dynamic by spec (`tools/list` is
a point-in-time answer; `tools/list_changed` can arrive any time), so the
catalog is also an **observable stream of versioned snapshots**
(`catalogUpdates` — see the Dynamic discovery decision). Multitool stays the one
fixed tool in the session and absorbs every change below it: it composes
**multiple sources — plain `Tool`s and `MCPServer`s, several of each** — into a
single searchable set, keyed on stable (server, tool) identity. A plain `Tool`
is just the trivial never-changing source; this package provides the dynamic
one.

**The unit is a server, not a tool.** One MCP **server** (a connected
`MCP.Client`) exposes *many* tools: an **`MCPServer`** vends all of them; an
**`MCPTool`** is a single (server, tool) pair. Both go straight into a session.
A tool you want callable from host code but not model-visible is simply not
added — hold the `MCPServer` / `MCPTool` and call it yourself.

## Elicitation: user input, in both directions

MCP **elicitation** lets a server pause mid-tool-call and ask the *user* for
structured input: the server sends `elicitation/create` with a `message` and a
`requestedSchema` (a flat object of primitive fields), and the client returns an
`action` — `accept` (with `content` matching the schema), `decline`, or
`cancel`. Supporting it is a **client capability** we declare at connect time;
the swift-sdk exposes it via `client.withElicitationHandler { … }`.

Two consequences, one mechanism:

1. **Server tools can elicit.** `MCPServer` declares the elicitation capability
   and registers a handler that routes each request to a host-provided
   **`ElicitationCoordinator`** (the app's UI), then returns the user's response
   to the server.
2. **The agent itself can elicit** — by making elicitation a tool.
   **`MCPElicitationTool`** is a `FoundationModels.Tool` the on-device model can
   call to ask the user a structured question (same `message` + `requestedSchema`),
   routed through the *same* `ElicitationCoordinator`, with the user's answer
   returned as the tool's output. So the agent stops and gathers missing input
   instead of guessing.

Both paths share one coordinator and one UI; the only difference is who started
the request — a server, or the model. The `requestedSchema` flat-primitive subset
reuses part of `SchemaConverter`, and the model's *call* is constrained to valid
JSON like every other tool here. (Per spec, form mode must **not** request
secrets — passwords, tokens, payment credentials — those use URL mode; the
coordinator enforces consent.)

## Connection lifecycle: async discovery, faults, reconnect

Populating a session with a server's tools is **async** — connect (stdio spawn or
HTTP) then `listTools()` — and a connection can drop, reconnect, or change its
tool set (`tools/list_changed`) mid-run. FoundationModels fixes the `tools:`
array at construction, so the exposed tool set is a **frozen snapshot**:

- **Building the session blocks on connect.** A server's tools must be in the
  `tools:` array when the first prompt is built, so `sessionTools()` awaits
  readiness, **retrying with exponential backoff** (per-attempt connect timeout,
  bounded max attempts — host-overridable); it hard-fails only when backoff is
  exhausted. `MCPServer` exposes a readiness state (connecting / ready / faulted).
- **Faults mid-run surface as tool errors.** A call that hits a dropped transport
  is mapped to an `isError` result so the model can react; the server
  auto-reconnects with the same backoff (using the SDK's transport reconnect
  where available, wrapping it where not).
- **Cancellation, progress, health.** Swift task cancellation of an in-flight
  tool call **propagates to protocol-level `notifications/cancelled`** (via the
  SDK where it does this, explicitly where it doesn't) so servers don't keep
  running orphaned work. `notifications/progress` on a long call **resets the
  per-call timeout** and is surfaced to the host as an event. Responding to
  server `ping` is SDK plumbing; reconnect triggers on transport error.
- **Tool-set changes need a rebuild — the host's call.** `tools/list_changed` is
  **surfaced as an event, never auto-applied** (an invisible rebuild would bust
  the session cache). Hosts that need live tool-set changes at scale should use
  FoundationModelsMultitool, which dispatches at call time.

## Uniform entry point: one `MCPToolProvider` protocol

`MCPTool` and `MCPServer` both answer the same question — *"what tools do I add
to a session?"* — so they share one protocol:

```swift
public protocol MCPToolProvider {
    // async because discovery (connect + listTools) may be required
    func sessionTools() async throws -> [any FoundationModels.Tool]
}
```

- `MCPTool` → `[self]` (one tool).
- `MCPServer` → awaits readiness, returns its tools as `[MCPTool]`.
- `[any MCPToolProvider]` → flattens (compose servers + loose tools).

So every shape is **addable to a session the same way**, and `sessionTools()` is
the single **async boundary** where discovery (connect + `listTools()`) blocks.
A convenience wraps it:

```swift
let session = try await LanguageModelSession(mcp: serverA, serverB, someTool,
                                             instructions: …)
```

That's the symmetry: **get a server and add all its tools, or hand over a single
tool — one protocol, one call site.** (FoundationModelsMultitool conforms its own
search layer to the same protocol to compose alongside.)

## Architecture

```
LanguageModelSession(mcp: provider)   // provider: MCPTool | MCPServer
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

The ⭐ components are the value-add (they touch FoundationModels types).
`MCPServer` is a thin wrapper over the SDK's `MCP.Client` and owns **no** protocol
logic of its own. `MCPTool` and `MCPServer` both conform to **`MCPToolProvider`**
(`sessionTools()`) — the uniform way to add either to a session (above).

1. **`MCPServer`** — the **core unit**: wraps one `MCP.Client` (the caller owns
   connection/transport setup via the SDK) and represents that server *and its
   many tools*. Connect + `listTools()` are **async** — discovery **follows
   `nextCursor` to exhaustion** (`tools/list` is paginated; a one-page read would
   silently truncate the tool set) — so it exposes a readiness state
   (connecting / ready / faulted); once ready it maps each `MCP.Tool` into an
   `MCPTool` and **vends `[any Tool]`** for direct session use, and exposes its
   **catalog as plain data** — tool name, `title`, description, raw
   `inputSchema`, converted `GenerationSchema`, `ToolAnnotations`
   (readOnly / destructive / idempotent / openWorld hints), icons — for hosts
   and FoundationModelsMultitool. The catalog is **observable**: `catalog` is
   the current `ToolCatalog` snapshot (stable server identity, a per-server
   **epoch**, server state, and per-tool **fingerprints** — hash of name + raw
   `inputSchema` + annotations), and `catalogUpdates: AsyncStream<ToolCatalog>`
   emits a new snapshot on every **coalesced** `tools/list_changed` re-list, on
   reconnect (an implicit re-list — the returning server may differ), and on
   readiness-state changes; `tool(named:)` resolves a name against the
   **current** catalog (nil once gone). Declares the **elicitation** client capability
   and routes server `elicitation/create` requests to the host
   `ElicitationCoordinator`. **Owns auto-reconnect with retry + exponential
   backoff** (using the SDK's transport reconnect where available, wrapping it
   where not) plus tool-list refresh (`tools/list_changed`) — connection
   *resilience* is the server's job, the *wire protocol* stays the SDK's.

2. **`MCPTool`** ⭐ — the generic adapter conforming to `FoundationModels.Tool`.
   Holds the `MCP.Client`, the source `MCP.Tool` (name/description/metadata),
   and the precomputed `GenerationSchema`. Implements `call(arguments:)` by
   encoding args and delegating to the SDK's `client.callTool`.

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
   `ToolOutput`/`String`) the model can consume. **Decided:** v1 surfaces
   `structuredContent` when present, validated against the tool's
   **`outputSchema`** when the tool declares one — a validation failure is
   rendered to the model as a note, not hidden. `.resourceLink` results render
   as links **without dereferencing** (that would need `resources/read`, which
   is out of scope — see Decisions → Tools only).

6. **`MCPElicitationTool`** ⭐ — a `FoundationModels.Tool` that lets the *agent*
   elicit. Constrained input `{ message, requestedSchema }` (the flat-primitive
   elicitation subset); `call` routes to the shared **`ElicitationCoordinator`**,
   awaits the user's `accept` / `decline` / `cancel`, and returns the structured
   answer (or non-accept outcome) to the model. Same coordinator as
   server-initiated elicitation; the host owns the UI.

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

Two notes on the input side. **Dialect:** MCP 2025-11-25 makes JSON Schema
**2020-12** the default `inputSchema` dialect — the converter targets that
dialect. **The mapping bounds only our declaration:** the **raw `inputSchema` is
also exposed verbatim** (see Models & enforcement), so an external driver that
compiles it directly — e.g. FoundationModelsMultitool via xgrammar — is not
limited by this table.

## Examples

Examples are **explicit, runnable deliverables** — each a small executable
target under `Examples/` (`swift run <Name>`), kept compiling in CI. Together
they are the living documentation of every capability in this plan:

1. **`EchoTool`** — the ~20-line hello world. Spawns a stdio echo server
   (`StdioTransport`), wraps it in `MCPServer`, builds
   `LanguageModelSession(mcp: echo)` on the system model, and runs one prompt
   that triggers one tool call. Proves the bridge end-to-end.
2. **`FileAssistant`** — a real multi-tool server (stdio filesystem).
   Direct-adds the whole server, then drives natural prompts ("what's in
   config.yaml?") so the model picks among several tools. Also demonstrates
   error bubbling: a prompt about a missing file produces an `isError` result
   the model recovers from in-session.
3. **`ToolPicking`** — provider composition: one loose `MCPTool` (a single
   (server, tool) pair) plus a native Swift `Tool` in the same session
   (`LanguageModelSession(mcp: clockTool, readFileTool)`), showing
   `MCPToolProvider` flattening and that MCP and native tools coexist.
4. **`RemoteHTTP`** — connects to a remote server over `HTTPClientTransport`
   with a host-supplied bearer token, demonstrating the authorization decision
   (auth is the host's; the bridge just uses the authenticated transport).
5. **`ElicitingAgent`** — both elicitation directions through one console
   `ElicitationCoordinator`: a server tool that pauses mid-call with
   `elicitation/create`, and the model calling `MCPElicitationTool` to ask the
   user a structured question. Shows accept / decline / cancel at the terminal.
6. **`CatalogBrowser`** — connects one or more servers and prints the full
   catalog (name, `title`, description, `ToolAnnotations`, icons, raw
   `inputSchema`, converted `GenerationSchema`) — the exact M8 surface
   FoundationModelsMultitool consumes; doubles as its integration stub.
7. **`DynamicToolset`** — a toy stdio server that adds, removes, and re-schemas
   a tool on a timer; prints each `ToolCatalog` snapshot as it arrives on
   `catalogUpdates` (epoch, membership diff, fingerprint changes) and then
   demonstrates call-time resolution — calling a tool that just vanished yields
   the structured "no longer available" result. The live half of M8.

(An MLX-backed variant — same bridge, xgrammar-constrained arguments — belongs
to the packages that actually depend on MLX; see FoundationModelsMultitool.)

Each example doubles as the acceptance demo for its milestone (`EchoTool` ↔ M4,
`ElicitingAgent` ↔ M7, `CatalogBrowser` + `DynamicToolset` ↔ M8).

## Milestones

- [ ] **M0 — Scaffold.** SwiftPM package with **exactly one external
  dependency** — `.product(name: "MCP", package: "swift-sdk")` — plus the system
  `FoundationModels` framework; nothing else (no MLX, no Router — see
  Enforcement). **Verify the pinned swift-sdk's supported MCP protocol revision
  (target: 2025-11-25) and its elicitation surface.** Decide module name(s). CI
  on macOS (Xcode for OS 27 SDK).
- [ ] **M1 — Schema translation.** `SchemaConverter` (`MCP.Value` →
  `GenerationSchema`) + the `GeneratedContent` ⇄ `MCP.Value` codec. Map JSON
  Schema constraints to runtime `GenerationGuide`s (enum/range/pattern/count) as
  hard constraints, degrading only the no-equivalent cases to logged description
  hints — tighter constraint = better constrained decoding. Unit-tested against a
  corpus of real MCP `inputSchema` values (no FoundationModels runtime needed for
  most of it).
- [ ] **M2 — `MCPTool` adapter.** Conform to `Tool`; wire `call(arguments:)` to
  the SDK's `client.callTool`; render results & errors via `ToolContentRenderer`
  (incl. `structuredContent` validated against `outputSchema` when declared).
- [ ] **M3 — `MCPServer`.** Wrap an already-connected `MCP.Client` and expose its
  tools as `[MCPTool]` / `[any Tool]` for direct session use; `listTools()`
  pagination to exhaustion; optional tool-list refresh; name collision handling
  across servers; the `MCPToolProvider` conformances + the
  `LanguageModelSession(mcp:)` convenience. Connection/transport setup stays with
  the SDK and the caller — we don't reimplement it.
- [ ] **M4 — End-to-end.** A `LanguageModelSession` driven against a real local
  MCP server (e.g. stdio filesystem/echo server) doing an actual tool call, on
  the system model. (Engine-level verification under an MLX-backed session
  happens downstream where MLX is a dependency — Multitool/Router.)
- [ ] **M5 — Hardening.** Cancellation (Swift task cancel → protocol
  `notifications/cancelled` so servers don't run orphaned work), per-call
  timeouts (reset by `notifications/progress`, which also surfaces to the host),
  `isError` mapping, image/audio content handling, structured logging, docs.
  **Tool results are the context-window cost** (an MCP result can be
  huge), so `ToolContentRenderer` needs a size/trimming strategy — this is where
  Apple's
  [managing-the-context-window](https://developer.apple.com/documentation/foundationmodels/managing-the-context-window)
  transcript guidance applies (the *output* side, distinct from the
  constrained-decoding win on the *input* side).
- [ ] **M6 — Examples.** Build the `Examples/` suite (see **Examples**):
  `EchoTool`, `FileAssistant`, `ToolPicking`, `RemoteHTTP`, `ElicitingAgent`,
  `CatalogBrowser`, `DynamicToolset` — each a runnable executable target
  (`swift run <Name>`), compiled in CI. `EchoTool` and `FileAssistant` double
  as the human-facing E2E.
- [ ] **M7 — Elicitation (both directions).** Declare the elicitation client
  capability on `MCPServer` and route server `elicitation/create` → the host
  `ElicitationCoordinator`; add `MCPElicitationTool` so the agent can elicit
  through the same coordinator. Handle `accept`/`decline`/`cancel`; keep secrets
  out of form mode (URL mode).
- [ ] **M8 — Live catalog surface for Multitool.** Freeze the public catalog API
  (`MCPServer` → stable server identity, tool name, `title`, description, raw
  `inputSchema`, `GenerationSchema`, `ToolAnnotations`, icons) **plus its
  dynamics**: `ToolCatalog` snapshots with epochs and per-tool fingerprints,
  `catalogUpdates: AsyncStream<ToolCatalog>` (+ `diff(from:)` helper), coalesced
  re-list on `tools/list_changed` and reconnect, and call-time `tool(named:)`
  resolution with the structured not-found result. Validate with a stub consumer
  driving an add / remove / same-name-schema-change sequence and asserting
  epochs, fingerprints, and not-found behavior.

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
  `LanguageModelSession` — **plus the explicit runnable examples** (see
  **Examples** / M6). The reverse direction
  (expose FoundationModels as an MCP *server*) is explicitly out of scope for v1.
- **Spec revision (decided):** targets MCP **2025-11-25** (the current revision).
  M0 verifies the pinned swift-sdk actually speaks it (and its elicitation
  surface); `SchemaConverter` targets the JSON Schema **2020-12** default dialect.
- **Enforcement (decided):** the bridge never drives generation — it **declares**
  each tool's schema and the session's engine **enforces** it (Apple's guided
  generation on the system model; xgrammar under an MLX-backed session). **No
  dependency on mlx-swift-lm or MLX**: the FoundationModels API is the seam, so
  MLX-backed sessions work through the bridge unchanged, supplied by the host or
  by Multitool via Router. *(Supersedes the earlier "mandatory mlx-swift-lm"
  decision — a holdover from when this package hosted tool search and drove
  constrained generation itself.)* This keeps the dependency set to **swift-sdk +
  the system FoundationModels framework only**, removes the mlx-swift-lm
  branch-pin from our release path, and eliminates the version diamond with
  Router. The **raw MCP `inputSchema` is exposed verbatim** alongside the
  converted `GenerationSchema` as the integration point for external constraint
  drivers (FoundationModelsMultitool).
- **Tool search is out of scope (decided):** this package **directly exposes
  tools** — no registry, no search tool, no generic call tool, no deferred
  surfacing. Tool search and dynamic surfacing live in
  **`swissarmyhammer/FoundationModelsMultitool`**, built on this package's
  catalog and FoundationModelsRouter. *(Supersedes the earlier registry /
  agentic-search / custom-segment-surfacing decisions, which move to Multitool.)*
- **Catalog as plain data (decided):** `MCPServer` exposes tools as inspectable
  values — name, `title`, description, raw `inputSchema`, `GenerationSchema`,
  **`ToolAnnotations`** (readOnly / destructive / idempotent / openWorld), icons —
  for Multitool and host UIs. Annotations are **untrusted hints** per spec: the
  bridge never auto-retries or gates on them; hosts may (e.g. confirm
  destructive-hinted calls). **No search or UI/autocomplete code lives here.**
- **Dynamic discovery (decided):** the catalog is a **stream of versioned
  snapshots**, never transmitted deltas — snapshots are idempotent, so a missed
  event costs nothing (a `diff(from:)` helper derives deltas locally). Each
  snapshot carries a per-server **epoch** and per-tool **fingerprints** (hash of
  name + raw `inputSchema` + annotations) so consumers detect the
  same-name-changed-schema case, not just membership changes.
  `tools/list_changed` notifications are **coalesced** into one re-list;
  reconnect is an implicit re-list; readiness-state changes also emit.
  Resolution is **call-time**: `tool(named:)` answers from the *current* catalog —
  a vanished tool yields a structured "no longer available" result the model can
  react to, and a schema-changed tool's call goes **through** (the server
  validates; `isError` bubbles — fingerprints are advisory for consumer
  indexing, never a gate). We define **no consumer protocol**: the surface is
  plain `Sendable` values + `AsyncStream`, and consumers adapt it —
  **FoundationModelsMultitool depends on this package directly** and takes
  `Tool`s and `MCPServer`s (multiples of each) as sources, keying its merged
  namespace on stable (server, tool) identity; a plain `Tool` is its trivial
  static source and needs nothing from us.
- **Transports (decided):** ship **stdio + HTTP** from the start
  (`StdioTransport` for local subprocess servers, `HTTPClientTransport` for
  remote/SSE), since swift-sdk provides both cheaply.
- **Authorization (decided — delegated):** OAuth for remote HTTP servers is the
  **host's responsibility**: the host supplies an authenticated transport /
  token via the SDK's `HTTPClientTransport` hooks. This package implements no
  OAuth flow (discovery, `WWW-Authenticate`, consent are host/SDK concerns);
  without host-provided auth, HTTP works against unauthenticated servers only.
- **Client capabilities (decided):** v1 declares **elicitation only**. **Sampling**
  (`sampling/createMessage`) and **roots** are *not* declared in v1 — servers
  requiring them degrade per spec. Recorded as deliberate: sampling is the
  natural post-v1 addition (this client uniquely owns a `LanguageModelSession`;
  a `SamplingCoordinator` would mirror the elicitation design), and roots would
  be a trivial host-provided list on `MCPServer`. Deferred to keep v1's
  capability surface minimal, not because they don't fit.
- **Tools only (decided):** v1 consumes **tools** (plus elicitation as above).
  **Prompts, resources, completion (`completion/complete`), server→client log
  routing, and experimental tasks are out of scope** — they're host-app surface,
  not tool-bridge surface. Consequence recorded: `.resourceLink` tool results
  are rendered as links, **not dereferenced** (that would require
  `resources/read`).
- **Core unit is `MCPServer` (decided):** one MCP server exposes many tools. You
  add an `MCPServer` (all its tools) or a single `MCPTool` to a session.
- **Elicitation is unified (decided):** one host `ElicitationCoordinator` serves
  both server-initiated elicitation (a declared client capability on `MCPServer`)
  and agent-initiated elicitation (`MCPElicitationTool`). The package defines the
  coordinator protocol; the host owns the UI; secrets go via URL mode, not form
  mode.
- **Resilience (decided):** the exposed tool set is a **frozen snapshot** (rebuild
  to change it). Servers block session construction until connect, **retrying
  with exponential backoff** (hard-fail only when backoff is exhausted); every
  `MCPServer` auto-reconnects with the same backoff; mid-run transport faults map
  to `isError` results; Swift cancellation propagates to protocol
  `notifications/cancelled`; `tools/list_changed` is surfaced as an event, never
  auto-applied.
- **Uniform entry point (decided):** `MCPTool` / `MCPServer` conform to
  `MCPToolProvider`; `sessionTools() async throws` is the single discovery
  boundary, and `LanguageModelSession(mcp:)` is the one call site.

### Still open

1. ✅ **Module name — decided:** one library module **`FoundationModelsMCP`**
   (`import FoundationModelsMCP`; matches the repo, distinct from the SDK's
   `import MCP`), plus the executable example targets under `Examples/` (see
   **Examples**).
2. ✅ **Min OS — decided: OS 27 only.** The whole package targets OS 27
   unconditionally — no `@available` branching, no OS-26 degrade path. The
   swift-sdk floor (macOS 13 / iOS 16, Swift 6+) is far below this; pin its
   latest stable tag at M0.
3. ✅ **Constraint mapping — decided: full in v1, `pattern` best-effort.** v1 maps
   `enum`→`anyOf`, `minimum`/`maximum`→`range`, `minItems`/`maxItems`→count as
   hard guides; **`pattern` is best-effort** — try-compile the JSON Schema
   (ECMA-262) regex as a Swift `Regex`; on failure, fall back to a logged
   description hint. Implementation must still pin against the compiled SDK:
   numeric guides are `Decimal` (clean JSON integer/number → `Decimal`),
   exclusive vs. inclusive bounds (`exclusiveMinimum` → epsilon/round,
   documented), and count-guide behavior on nested arrays. Enforcement inside
   Apple's closed decoder can't be inspected — an MLX-backed session (xgrammar;
   no dependency here) is the independent, testable enforcement path, exercised
   downstream where MLX is a dependency, and the raw-`inputSchema` catalog gives
   external drivers the same escape.
4. ✅ **Agent-elicitation arg shape — decided: full `requestedSchema`.**
   `MCPElicitationTool` takes `{ message, requestedSchema }` and the **model
   generates the flat-primitive `requestedSchema` itself, constrained** (mirrors
   exactly what a server sends over the wire — one shape for both elicitation
   directions, no second representation to maintain). Constrained decoding keeps
   the generated schema well-formed and within the flat-primitive subset. A
   sensitive field (or `format: "url"`) routes to **URL mode**, never form mode —
   the spec-backed rule is no-secrets-in-form-mode; any `secret` marker is our
   convention, honored by the coordinator, not a spec field.
5. ✅ **Lifecycle policy — decided.**
   - **Connect failure → retry with backoff.** A failed/timed-out connect is
     retried with **exponential backoff** (per-attempt connect timeout, bounded
     total budget / max attempts); the session blocks on these retries during
     construction and hard-fails only when backoff is exhausted. Defaults are
     host-overridable. Every `MCPServer` auto-reconnects with the same backoff —
     it's connection hygiene, not a mode.
   - **`tools/list_changed` → host's call.** The exposed tool set is an explicit
     frozen snapshot; the package **surfaces the change event but does not
     auto-rebuild** (that would bust the cache invisibly). Hosts needing live
     tool-set changes use FoundationModelsMultitool.

*(Former open items on registry search tuning, custom-segment surfacing, and
generic-call-tool cross-field constraints moved out with tool search — they are
FoundationModelsMultitool concerns now.)*

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

- MCP specification (2025-11-25 — the targeted revision) —
  https://modelcontextprotocol.io/specification/2025-11-25
- MCP elicitation (2025-11-25) —
  https://modelcontextprotocol.io/specification/2025-11-25/client/elicitation
- MCP Swift SDK — https://github.com/modelcontextprotocol/swift-sdk
- mlx-swift-lm (`MLXFoundationModels` / `MLXGuidedGeneration` — the xgrammar
  schema-constrained model path; **not a dependency of this package**, used
  downstream via Router/Multitool) —
  https://github.com/swissarmyhammer/mlx-swift-lm
- FoundationModelsMultitool (sibling pkg — tool search / dynamic surfacing, built
  on this package's catalog) —
  https://github.com/swissarmyhammer/FoundationModelsMultitool
- FoundationModelsRouter (sibling pkg — model selection; used by Multitool, not by
  this package) — ../FoundationModelsRouter
- FoundationModels `Tool` protocol — https://blakecrosley.com/blog/foundation-models-on-device-llm
- Dynamic schemas in FoundationModels — https://justin.searls.co/posts/how-to-generate-dynamic-data-structures-with-apple-foundation-models/
- `@Generable` / `@Guide` & constrained decoding — https://developer.apple.com/videos/play/wwdc2025/301/
- Managing the context window — https://developer.apple.com/documentation/foundationmodels/managing-the-context-window
- Claude Code MCP tool search (the pattern Multitool implements) —
  https://code.claude.com/docs/en/mcp#scale-with-mcp-tool-search
