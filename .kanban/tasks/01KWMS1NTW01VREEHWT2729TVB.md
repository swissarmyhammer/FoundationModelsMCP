---
comments:
- actor: claude-code
  id: 01kwqnnce5q6gh719pkqjcmm48
  text: |-
    Implemented via TDD.

    - Wrote Tests/FoundationModelsMCPTests/CatalogTypeTests.swift first (13 tests: fingerprint stability/sensitivity to schema/annotations/name changes, diff add/remove/change classification including a mixed scenario, Sendable compile-time proof via a `some Sendable` helper + crossing a `Task {}` boundary, and two MCPServer.catalog smoke tests). Confirmed RED: `swift test --filter CatalogType` failed to compile (`value of type 'MCPServer' has no member 'catalog'`, `ToolDescriptor`/`ToolCatalog` undefined).
    - Implemented Sources/FoundationModelsMCP/ToolCatalog.swift:
      - `ToolAnnotations` — a typealias to the swift-sdk's `MCP.Tool.Annotations` (already Sendable/Hashable/Codable with exactly the readOnly/destructive/idempotent/openWorld/title shape) rather than a reinvented parallel type.
      - `ToolDescriptor` — Sendable struct: name/title/description/inputSchema (verbatim `Value`)/parameters (`GenerationSchema`)/annotations/icons (`[MCP.Icon]`)/fingerprint. Two public initializers: `init(tool: MCP.Tool) throws` (runs SchemaConverter.parse/emit from scratch, for standalone construction e.g. in tests) and `init(mcpTool: MCPTool)` (non-throwing — reuses `MCPTool`'s already-precomputed `.parameters` instead of re-running SchemaConverter a second time; this is the path `MCPServer.catalog` takes). `fingerprint` is a hex SHA-256 (CryptoKit) digest of a JSONEncoder(.sortedKeys) encoding of name+inputSchema+annotations — deliberately not Swift's randomly-seeded `Hasher`, so it's stable across processes/runs, not just within one. `nonConformingFloatEncodingStrategy` is set so the encode is total even for a hand-built NaN/Infinity `Value` literal in a test.
      - `ToolCatalog` — Sendable struct: identity (reuses the pre-existing `ServerIdentity`)/epoch/state/tools, with `diff(from:) -> ToolCatalogDiff` (dictionary-keyed by name, O(n), `Dictionary(_:uniquingKeysWith:)` so a malformed duplicate-name tool list can't crash it).
      - `ToolCatalogDiff` — added/removed/[ChangedTool(before:after:)].
    - MCPServer.swift: added `private var catalogEpoch = 0`, incremented once per successful `applyConnect` discovery (right where `discoveredTools` is assigned, before `state = .ready`), and a new `public var catalog: ToolCatalog { get throws { ... } }` throwing `MCPServerError.notReady` if `identity` was never established (mirrors `mcpTools()`'s guard style but keyed on `identity` rather than `state == .ready`, so a snapshot after a later faulted reconnect still returns the last-known tools).

    Verification: `swift build` clean (no warnings/errors). `swift test --filter CatalogType` → 13/13 green. Full `swift test` → 164/164 green across 16 suites, no regressions.

    Design judgment calls:
    - Reused `MCP.Tool.Annotations` and `MCP.Icon` directly rather than inventing parallel types, per the "reuse before re-implementing" guidance and since the SDK shapes already match plan.md's spec.
    - Fingerprint uses SHA-256 over sorted-key JSON rather than Swift's `Hasher`, since `Hasher`'s per-process random seed would make the fingerprint unstable across runs/processes, contradicting plan.md's "stable hash" framing.
    - `ToolDescriptor.init(mcpTool:)` is non-throwing (reuses `MCPTool.parameters` instead of re-converting), avoiding redundant work and a redundant failure mode for the `MCPServer.catalog` hot path.
    - `MCPServer.catalog`'s not-ready guard is keyed on `identity != nil` rather than `state == .ready`, so it stays usable after a later faulted reconnect (per plan.md's Dynamic discovery decision that snapshots stay available and idempotent).

    Spawned the double-check adversarial review agent; awaiting its verdict before final hand-off.
  timestamp: 2026-07-04T22:58:20.741628+00:00
- actor: claude-code
  id: 01kwqp1n5adswxn618xgj28z0c
  text: |-
    Double-check adversarial review verdict: REVISE, with exactly one low-severity cosmetic nit — a stray `// swiftlint:disable:next force_try` comment in ToolCatalog.swift referencing a linter not configured anywhere in this repo (no .swiftlint.yml, no SwiftLint dependency, no other reference in the codebase). Everything substantive (fingerprint determinism/sensitivity, diff classification, Sendable/no-reference-leakage, epoch placement, init(mcpTool:) consistency with init(tool:), try! soundness, Dictionary uniquing safety) was independently re-verified by the reviewer and passed.

    Fixed: removed the stray pragma comment (the preceding prose already documents why `try!` is safe). Re-ran full verification after the fix:
    - `swift build` — clean, 0 warnings/errors.
    - `swift test --filter CatalogType` — 13/13 green.
    - `swift test` (full suite) — 164/164 green across 16 suites, no regressions.

    Task is complete and green. Leaving in `doing` for `/review` per the implement workflow.
  timestamp: 2026-07-04T23:05:02.890357+00:00
depends_on:
- 01KWMS0RQH4YWDJGDAVR1M7FAY
position_column: doing
position_ordinal: '80'
title: 'ToolCatalog value types: snapshot, epoch, fingerprints, annotations'
---
## What
Create `Sources/FoundationModelsMCP/ToolCatalog.swift` with plain `Sendable` value types per plan.md Dynamic discovery: `ServerIdentity`; `ToolDescriptor` (name, `title`, description, **raw `inputSchema` verbatim**, converted `GenerationSchema`, `ToolAnnotations` — readOnly/destructive/idempotent/openWorld hints — and icons, plus a **fingerprint** = stable hash of name + raw inputSchema + annotations); `ToolCatalog` (server identity, per-server **epoch**, server state, `[ToolDescriptor]`) with a `diff(from:)` helper (added/removed/changed-by-fingerprint). Expose `MCPServer.catalog` returning the current snapshot.

- [ ] Sendable value types: ServerIdentity, ToolDescriptor, ToolCatalog
- [ ] Fingerprint: stable across runs, changes when raw schema or annotations change
- [ ] diff(from:) helper (added/removed/changed)
- [ ] MCPServer.catalog current-snapshot accessor

## Acceptance Criteria
- [ ] Fingerprint equal for identical descriptors, different when only the inputSchema changes (same name)
- [ ] diff correctly classifies add/remove/change across two snapshots
- [ ] All types compile as Sendable with no reference-type leakage

## Tests
- [ ] `Tests/FoundationModelsMCPTests/CatalogTypeTests.swift`: fingerprint stability/sensitivity, diff classification, Sendable conformance (compile-time)
- [ ] `swift test --filter CatalogType` green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.