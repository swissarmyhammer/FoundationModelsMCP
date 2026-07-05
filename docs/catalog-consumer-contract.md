# The M8 catalog consumer contract

This is the frozen public catalog surface `FoundationModelsMCP` exposes for a
downstream consumer to build a live tool catalog on — primarily
[`swissarmyhammer/FoundationModelsMultitool`](https://github.com/swissarmyhammer/FoundationModelsMultitool),
which surfaces/searches many tools across many connected servers and is out
of scope for this package (see `plan.md` → "Scaling to many tools: out of
scope — see FoundationModelsMultitool"). Anything described here is covered
by `Tests/FoundationModelsMCPTests/StubConsumerTests.swift`, which exercises
it exactly as an external package would: `import FoundationModelsMCP`, never
`@testable import`.

Why a plain Markdown file and not a `.docc` catalog: this package has no
`.docc` bundle and `Package.swift` doesn't depend on the DocC plugin, so a
DocC article has nowhere to live yet. The doc comments on every type below
already render as API documentation via `swift package generate-documentation`
or Xcode's Quick Help regardless of a `.docc` bundle; this file is the
narrative complement — the *shape of the contract*, not the per-symbol
reference, which lives in the doc comments themselves
(`Sources/FoundationModelsMCP/ToolCatalog.swift`,
`Sources/FoundationModelsMCP/MCPServer.swift`).

## The surface

- `MCPServer.catalog` — the current `ToolCatalog` snapshot, throwing
  `MCPServerError.notReady(_:)` only if no `connect(transport:)` call has
  ever fully succeeded. Once a server has connected at least once, `catalog`
  keeps returning a snapshot even after a later fault — see
  `MCPServerState.faulted(_:)`.
- `MCPServer.catalogUpdates: AsyncStream<ToolCatalog>` — every subsequent
  snapshot, one per successful connect/reconnect, failed reconnect, mid-call
  transport fault, and coalesced `tools/list_changed` re-list. Each emission
  is a complete, self-contained snapshot: a consumer can start fresh from any
  one snapshot alone, with no prior state, and can diff any two snapshots on
  demand via `ToolCatalog.diff(from:)`. Only one concurrent consumer should
  iterate this stream at a time.
- `ToolCatalog` — `identity` (`ServerIdentity`, stable across reconnects),
  `epoch` (`Int`, strictly increasing, never reset), `state`
  (`MCPServerState`), and `tools` (`[ToolDescriptor]`).
- `ToolDescriptor` — `name`, `title`, `description`, the raw `inputSchema`
  (`MCP.Value`, exposed verbatim — never only the converted schema),
  `parameters` (`GenerationSchema`, converted for constrained generation),
  `annotations` (`ToolAnnotations`), `icons` (`[MCP.Icon]`), and `fingerprint`
  — a stable, hex-encoded SHA-256 digest of `name` + `inputSchema` +
  `annotations`. Two descriptors have equal fingerprints if and only if all
  three are identical; a schema or annotation change under the same `name`
  always changes it. `fingerprint` is advisory for consumer indexing only —
  never a gate on whether a call is allowed; a schema-changed tool's call
  still goes through, and the MCP server itself is the authoritative
  validator.
- `ToolCatalog.diff(from:)` — classifies every tool that changed between an
  earlier snapshot and this one into `added`, `removed`, and `changed`
  (same `name`, different `fingerprint`) — computed locally, on demand, from
  two snapshots; never transmitted as a delta over the wire.
- `MCPServer.tool(named:)` — resolves a tool name against the *current*
  catalog, returning `nil` (never throwing) if the name isn't present —
  whether because the server was never ready or because a re-list removed
  it.
- `MCPServer.toolNoLongerAvailableResult(named:)` — the rendered, structured
  `isError` text a consumer should show when a previously-resolved tool
  (cached from an earlier catalog snapshot) is later confirmed gone via
  `tool(named:)` returning `nil`.

## The scenario every consumer should expect

`StubConsumerTests.swift` drives one `ScriptedServer` (see
`Sources/MCPTestServer/ScriptedServer.swift`, scenario 5: "add/remove/
re-schema tools on command or timer") through:

1. **Connect** — one tool (`"alpha"`) discovered; `catalog.epoch == 1`.
2. **Add** — a second tool (`"beta"`) is registered on the scripted server,
   which emits `notifications/tools/list_changed`; the resulting snapshot's
   `epoch` increments by exactly one, and
   `diff(from:)` against the prior snapshot reports `added == ["beta"]`.
3. **Remove** — `"alpha"` is removed and the change is re-listed; the next
   snapshot's `diff(from:)` reports `removed == ["alpha"]`, and
   `tool(named: "alpha")` now resolves to `nil` — the point at which a
   consumer should render `toolNoLongerAvailableResult(named: "alpha")` for
   any caller still holding a reference to it.
4. **Same-name schema change** — `"beta"` is re-declared with a structurally
   different `inputSchema` under the *same* name. The next snapshot's
   `diff(from:)` reports it under `changed`, not `added`/`removed`: the
   `ChangedTool.before`/`.after` pair share `name == "beta"` but differ in
   `fingerprint`. `tool(named: "beta")` continues to resolve — a schema
   change is not a disappearance.

Every step's epoch is asserted as an exact integer (never just "increases"),
and every fingerprint comparison is asserted both ways: equal where nothing
changed, unequal exactly where the tool's `name`/`inputSchema`/`annotations`
diverged.
