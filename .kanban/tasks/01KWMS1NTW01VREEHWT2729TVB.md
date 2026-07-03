---
depends_on:
- 01KWMS0RQH4YWDJGDAVR1M7FAY
position_column: todo
position_ordinal: 8a80
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