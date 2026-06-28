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

## Scaling to many tools: registry, search, dynamic surfacing

Direct-adding every MCP tool to a session puts *every* tool's schema in the
instructions — fine for a handful, ruinous for dozens. This is exactly the
problem Claude Code's [MCP tool search](https://code.claude.com/docs/en/mcp#scale-with-mcp-tool-search)
solves (defer tool defs; only names + a search tool load up front; only tools
actually used enter context). We support both ends of the scale.

**The unit is a server, not a tool.** One MCP **server** (a connected
`MCP.Client`) exposes *many* tools. So the thing you register and pass around is
an **`MCPServer`**; an **`MCPTool`** is a single (server, tool) pair. Both can go
straight into a session.

**Two usage modes:**

1. **Direct add** (small N) — add an `MCPServer` (it exposes *all* its tools as
   `MCPTool`s) and/or individual `MCPTool`s straight to
   `LanguageModelSession(tools:)`. Everything in context; simplest path.
2. **Registry + search** (large N) — put one or more `MCPServer`s in an
   `MCPToolRegistry`, add the generic search/call tools (built over those
   servers) to the session, and let the model discover and invoke tools on
   demand. Only what's used reaches context.

**The three FoundationModels tools** (the generic two take one or more
`MCPServer`s, or the registry):

- **`MCPTool`** (specific) — one tool, **constrained to that tool's JSON schema**
  (full per-field constrained decoding). Direct-add, or surfaced on demand.
- **`MCPSearchTool`** (generic, **agentic**) — input is a natural-language
  **task**; runs an isolated sub-session over the servers' catalog to pick the
  right tool(s). See "Agentic search."
- **`MCPCallTool`** (generic) — input is `{ server, tool, arguments }`: *which
  server*, *which tool*, then the parameters. `server` and `tool` are
  **`anyOf`-constrained to the known names**; `arguments` is a generic JSON
  object. A **different generation constraint** from the specific tool — three
  fields, params left generic.

**The constraint that matters is valid JSON.** Malformed / unescaped JSON is the
thing that actually goes wrong; constrained decoding makes it *impossible* —
every tool here, generic or specific, emits well-formed JSON by construction. The
specific `MCPTool` adds per-field typing/guides on top; `MCPCallTool` adds
`anyOf` server/tool names but leaves the params as a valid-JSON object for
unlimited scale.

**Three load modes** (per tool, or per server as a default for its tools),
mirroring Claude Code's `alwaysLoad` / deferred:

- **alwaysLoad** — in the session's initial `tools:` with
  `includesSchemaInInstructions = true`; always visible, always in context. For
  the few tools needed every turn.
- **deferred** — not in the initial instructions; discovered via `MCPSearchTool`
  and **surfaced on demand** (below). The default for scale.
- **hidden** — in the registry but **never exposed to the model**: not loaded,
  not searchable, invoked only programmatically / behind policy. *(Decided.)*

### Agentic search (`MCPSearchTool`)

Search is **agentic and isolated**, not a lexical lookup. The calling agent
describes the *task* it's trying to accomplish; `MCPSearchTool.call`:

1. spins up a **separate, ephemeral `LanguageModelSession`** — its own context
   budget, so the full tool catalog **never pollutes the main session**;
2. seeds it with **curated tool-selection instructions** plus the registry's
   **listing of every (non-hidden) tool's name + description**;
3. has it reason over the catalog and return the best-matching tool(s)
   (constrained output: tool name(s) + rationale); and
4. returns those to the parent and **surfaces** the chosen tool(s) so the parent
   can call them (next section).

The expensive "reason over hundreds of tools" happens off to the side; only the
selected few re-enter the main session. (The sub-session is itself a
`LanguageModelSession`, so its selection output is constrained too.)

The search agent is configured where the registry is assembled — via
`MCPToolRegistry.Builder`:

```swift
let registry = try await MCPToolRegistry.Builder()
    .add(server: filesystem, mode: .deferred)
    .add(server: github, mode: .deferred)
    .add(tool: clock, mode: .alwaysLoad)
    .searchAgent(instructions: "Pick the fewest tools that accomplish the task…",
                 model: .default, effort: .medium, maxResults: 5)
    .elicitation(coordinator)
    .build()                 // connects servers, discovers tools (async)
let session = try await LanguageModelSession(mcp: registry, instructions: …)
```

`build()` is the async discovery point; the result is an `MCPToolProvider`.

**The dynamic-surfacing mechanism (the "real trick").** FoundationModels fixes
the `tools:` array at construction — you can't mutate a live session's tool list,
and rebuilding the session busts the cache. **But OS 27 lets you append to the
transcript, and appended entries are processed incrementally — prior tokens stay
cached.** So a discovered deferred tool is surfaced by **appending it to the
ongoing transcript as a custom segment** (a `PromptRepresentable` carrying the
tool's definition + its `GenerationSchema`), *not* by reconstructing the session.
The model sees the tool inline, calls it with full constrained decoding, and the
cache is preserved. **"Add the tool inline where it's needed" = append a segment,
not rebuild.** (OS 27 **Skills** — just-in-time transcript injection of
directions/tools, with `allowsDeactivation` to remove them mid-turn — are the
higher-level form of the same primitive and a candidate surfacing vehicle.)

> ⚠️ **The one thing M8 must pin against the compiled SDK:** that a custom
> segment (or a Skill) can carry a tool definition that becomes *callable with
> constrained decoding* — not merely descriptive text in context. Strong
> evidence exists that custom segments carry content into the transcript cheaply
> (cache-preserving append); first-party confirmation that this makes a *tool
> callable* was not found. **Fallback if it doesn't hold:** route the call
> through `MCPCallTool(server, tool, args)` instead — the args lose *per-tool*
> typing but are still constrained to valid, escaped JSON, so deferred tools stay
> usable.

### The registry is also a UI catalog

`MCPToolRegistry` exposes its full contents as plain, inspectable data — every
tool's server, name, description, load mode, **and parameters (the full value
list / schema)** — so a host UI can drive discovery, pickers, and autocomplete
against it. **This package exposes the values only; it contains no UI or
autocomplete logic.**

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

Populating an agent with a server's tools is **async** — connect (stdio spawn or
HTTP) then `listTools()` — and a connection can drop, reconnect, or change its
tool set (`tools/list_changed`) mid-run. FoundationModels fixes the `tools:`
array at construction, so *where the tools live* decides how faults are handled:

- **Direct-add (a frozen snapshot).** You await the server, snapshot its tools,
  and build the session. That snapshot is frozen: reflecting a fault/reconnect or
  a changed tool list means **rebuilding the session (cache bust)**. Fine for a
  small, stable, already-running server. A call that hits a dropped transport
  surfaces as a tool error — the SDK reconnects; we map the failure to an
  `isError` result so the agent can react — but *new/removed* tools won't appear
  without a rebuild.
- **Registry + generic tools (the resilient default).** The session holds only
  the stable `MCPSearchTool` / `MCPCallTool` (+ any alwaysLoad tools), which
  dispatch through the registry **at call time**. So the registry is the mutable
  layer: servers can connect late, fault, reconnect, or change their tool lists
  and the registry just **refreshes — the session stays warm, no rebuild.** This
  is *why* the registry path is the default for many or unreliable servers.

**Startup blocking mirrors Claude Code.** `alwaysLoad` tools must be present when
the first prompt is built, so they **block session construction until connect**
(bounded by a timeout); deferred/registry servers connect in the **background**
and become searchable as they come online. `MCPServer` therefore exposes async
readiness and a state (connecting / ready / faulted); a faulted server is simply
absent from search until it recovers, rather than failing the whole session.

## Uniform entry point: one `MCPToolProvider` protocol

`MCPTool`, `MCPServer`, and `MCPToolRegistry` all answer the same question —
*"what tools do I add to a session?"* — so they share one protocol:

```swift
public protocol MCPToolProvider {
    // async because discovery (connect + listTools) may be required
    func sessionTools() async throws -> [any FoundationModels.Tool]
}
```

- `MCPTool` → `[self]` (one tool).
- `MCPServer` → awaits readiness, returns its tools as `[MCPTool]`.
- `MCPToolRegistry` → its alwaysLoad tools **plus** the generic `MCPSearchTool` /
  `MCPCallTool` / `MCPElicitationTool`.
- `[any MCPToolProvider]` → flattens (compose servers + loose tools + a registry).

So every shape is **addable to a session the same way**, and `sessionTools()` is
the single **async boundary** where discovery happens — alwaysLoad blocks here;
deferred tools arrive later via the registry's search/call tools. A convenience
wraps it:

```swift
let session = try await LanguageModelSession(mcp: registry, instructions: …)
// or:  LanguageModelSession(mcp: serverA, serverB, someTool, instructions: …)
```

That's the symmetry: **get a server and add it, hand over a single tool, or let a
registry manage discovery dynamically — one protocol, one call site.**

## Architecture

```
LanguageModelSession(mcp: provider)   // provider: MCPTool | MCPServer | MCPToolRegistry
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
logic of its own; the registry holds metadata and powers search/UI. `MCPTool`,
`MCPServer`, and `MCPToolRegistry` all conform to **`MCPToolProvider`**
(`sessionTools()`) — the uniform way to add any of them to a session (above).

1. **`MCPServer`** — the **core unit**: wraps one `MCP.Client` (the caller owns
   connection/transport setup via the SDK) and represents that server *and its
   many tools*. Connect + `listTools()` are **async**, so it exposes a readiness
   state (connecting / ready / faulted); once ready it maps each `MCP.Tool` into
   an `MCPTool` and **vends `[any Tool]`** for direct session use, the registry,
   or the search/call tools. Declares the **elicitation** client capability and
   routes server `elicitation/create` requests to the host `ElicitationCoordinator`.
   Optional tool-list refresh (`tools/list_changed`); does not reimplement
   connection/reconnect — that's the SDK's job.

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

6. **`MCPToolRegistry`** ⭐ — assembled via **`MCPToolRegistry.Builder`** (servers
   + per-tool load modes + search-agent config + elicitation coordinator; async
   `build()`). Holds one or more `MCPServer`s and the load mode
   (alwaysLoad / deferred / hidden) of each tool. Vends the session's initial
   `tools:` set (alwaysLoad tools + the search/call tools), answers searches over
   non-hidden tools, builds the custom segment to surface a tool on demand, and
   **exposes the full catalog as plain data (server, tool name, description,
   parameters/schema) for host UIs** — values only, no UI logic. **Refreshes** on
   reconnect / `tools/list_changed` so search and call stay current **without
   rebuilding the session.** Holds metadata; the SDK owns connections.

7. **`MCPSearchTool`** ⭐ — a generic `FoundationModels.Tool` built over a
   registry (or one or more `MCPServer`s). Constrained input `{ task }`; `call`
   runs the **isolated agentic sub-session** (see "Agentic search") across those
   servers' tools and surfaces the selection. Can read the parent transcript via
   `ToolCallContext`.

8. **`MCPCallTool`** ⭐ — a generic `FoundationModels.Tool` built over a registry
   (or one or more `MCPServer`s). Constrained input `{ server, tool, arguments }`:
   `server` and `tool` are `anyOf`-constrained to known names; `arguments` is a
   valid-JSON object (not per-tool typed). Resolves the (server, tool) pair and
   delegates to that server's `callTool`. The fallback invoke path when a tool
   isn't surfaced as a specific `MCPTool`.

9. **`MCPElicitationTool`** ⭐ — a `FoundationModels.Tool` that lets the *agent*
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
- [ ] **M3 — `MCPServer`.** Wrap an already-connected `MCP.Client` and expose its
  tools as `[MCPTool]` / `[any Tool]` for direct session use; optional tool-list
  refresh; name collision handling across servers. Connection/transport setup
  stays with the SDK and the caller — we don't reimplement it.
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
- [ ] **M7 — Registry + generic tools.** `MCPToolRegistry` (built via
  `MCPToolRegistry.Builder`) over one+ `MCPServer`s with per-tool load modes and a
  public catalog (server/tool/description/parameters) for host UIs; the
  `MCPToolProvider` conformances + `LanguageModelSession(mcp:)` convenience;
  generic `MCPCallTool` (constrained `{ server, tool, arguments }`, server/tool as
  `anyOf` → SDK `callTool`). The direct-add path stays unchanged.
- [ ] **M8 — Agentic search + dynamic surfacing.** `MCPSearchTool` running an
  isolated sub-session over the catalog from a task description. Surface a
  discovered deferred tool by appending a custom segment (cache-preserving) and
  **confirm it's callable with constrained decoding**; fall back to `MCPCallTool`
  if not. (The riskiest milestone — see Still open #4.)
- [ ] **M9 — Elicitation (both directions).** Declare the elicitation client
  capability on `MCPServer` and route server `elicitation/create` → the host
  `ElicitationCoordinator`; add `MCPElicitationTool` so the agent can elicit
  through the same coordinator. Handle `accept`/`decline`/`cancel`; keep secrets
  out of form mode (URL mode).

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
- **Core unit is `MCPServer` (decided):** one MCP server exposes many tools. You
  add an `MCPServer` (all its tools) or a single `MCPTool` to a session, and put
  `MCPServer`s in the registry / search / call. `MCPCallTool`'s constraint is
  `{ server, tool, arguments }` (server & tool `anyOf`-constrained; arguments a
  valid-JSON object).
- **Tool load modes (decided):** `alwaysLoad` / `deferred` / `hidden`, mirroring
  Claude Code. `hidden` = in the registry, never exposed to the model.
- **Search is agentic (decided):** `MCPSearchTool` runs an isolated sub-session
  over the registry catalog from a task description — not a lexical match.
- **Surfacing (decided, pending SDK verification):** surface discovered deferred
  tools by appending a **custom segment** to the transcript (cache-preserving,
  constrained); `MCPCallTool` (generic, valid-JSON-constrained) is the fallback.
  *This supersedes the earlier "generic-invoke-only" direction — generic invoke
  is now the fallback, not the primary.*
- **Registry as UI catalog (decided):** the registry exposes tools + parameters
  as plain data for host UIs; **no UI/autocomplete code lives in this package.**
- **Elicitation is unified (decided):** one host `ElicitationCoordinator` serves
  both server-initiated elicitation (a declared client capability on `MCPServer`)
  and agent-initiated elicitation (`MCPElicitationTool`). The package defines the
  coordinator protocol; the host owns the UI; secrets go via URL mode, not form
  mode.
- **Resilience (decided):** the **registry path keeps the session warm** across
  late connects / faults / reconnects / `tools/list_changed` (refresh, no
  rebuild); **direct-add is a frozen snapshot** (rebuild to change its tool set).
  `alwaysLoad` blocks startup until connect (timeout-bounded); other servers
  connect in the background.
- **Uniform entry point (decided):** `MCPTool` / `MCPServer` / `MCPToolRegistry`
  conform to `MCPToolProvider`; `sessionTools() async throws` is the single
  discovery boundary, and `LanguageModelSession(mcp:)` is the one call site.
- **Registry built via a builder (decided):** `MCPToolRegistry.Builder` assembles
  the registry — servers + per-tool load modes, the elicitation coordinator, and
  **the search agent's configuration** (instructions, model, effort, max
  results). `build()` is the async step that connects/discovers and returns a
  ready registry.

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
4. **Custom-segment / Skill callability** — the M8 crux: confirm a custom
   segment (or a Skill) makes a tool *callable with constrained decoding*, not
   just visible as text. If it can't, `MCPCallTool` is the surfacing fallback.
5. **Surfacing vehicle** — custom segment vs. OS 27 Skill (`allowsDeactivation`):
   pin which to use, and whether removing a surfaced tool mid-conversation is
   needed.
6. **Search tuning** — the sub-session's model/effort, how many tools it returns,
   whether to auto-surface the top pick or let the parent choose, and catalog
   size limits for the sub-session's own context.
7. **Cross-field constraint in `MCPCallTool`** — can `tool` be constrained to the
   chosen `server`'s tools (a dependent `anyOf`), or only to the global union of
   tool names? If dependent enums aren't expressible at runtime, validate the
   (server, tool) pair after generation and re-prompt on mismatch.
8. **Agent-elicitation arg shape** — does `MCPElicitationTool` take a full
   `requestedSchema` (the model generates the flat-primitive schema, constrained)
   or a simpler field list? And how URL-mode / secret elicitation surfaces to the
   coordinator.
9. **Lifecycle policy** — the `alwaysLoad` connect-timeout value; what to do when
   an `alwaysLoad` server fails to connect (fail the session vs. degrade); and
   whether to auto-rebuild a *direct-add* session on `tools/list_changed` or
   leave that to the host.

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
- Claude Code MCP tool search (alwaysLoad / deferred) — https://code.claude.com/docs/en/mcp#scale-with-mcp-tool-search
- Custom segments & transcript append (WWDC26) — https://developer.apple.com/videos/play/wwdc2026/339/
- MCP elicitation — https://modelcontextprotocol.io/specification/draft/client/elicitation
