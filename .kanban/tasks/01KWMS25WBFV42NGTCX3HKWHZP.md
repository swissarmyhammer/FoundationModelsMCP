---
depends_on:
- 01KWMS18GCCA8M5SWW0SDX0GAP
- 01KWMS1NTW01VREEHWT2729TVB
position_column: todo
position_ordinal: 8b80
title: 'Live catalog: catalogUpdates stream, coalesced re-list, tool(named:) resolution'
---
## What
Add the dynamic half of the catalog to `MCPServer` per plan.md Dynamic discovery: `catalogUpdates: AsyncStream<ToolCatalog>` emitting a new versioned snapshot on (a) **coalesced** `tools/list_changed` re-list (debounce a burst of notifications into one re-list), (b) reconnect (implicit re-list — the returning server may differ), (c) readiness-state changes. Per-server epoch increments monotonically per emission. Add `tool(named:) -> MCPTool?` resolving against the **current** catalog (nil once gone) plus a helper producing the structured "tool no longer available" result text for consumers.

- [ ] catalogUpdates AsyncStream with epoch monotonicity
- [ ] list_changed burst coalesced into a single re-list
- [ ] Reconnect and state changes emit snapshots
- [ ] tool(named:) call-time resolution + not-available result helper

## Acceptance Criteria
- [ ] 5 rapid scripted list_changed notifications produce exactly 1 re-list and 1 new snapshot (virtual clock)
- [ ] Epochs strictly increase across emissions; snapshots are complete (idempotent — consumable without prior state)
- [ ] After scripted tool removal, tool(named:) returns nil and the helper renders the structured not-available message

## Tests
- [ ] `Tests/FoundationModelsMCPTests/LiveCatalogTests.swift`: coalescing, epoch monotonicity, reconnect-implies-relist, resolution nil-after-removal
- [ ] `swift test --filter LiveCatalog` green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.