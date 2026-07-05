---
comments:
- actor: claude-code
  id: 01kwqrjkbtx10cz5wtvnz7hvx8
  text: |-
    Implemented in Sources/FoundationModelsMCP/MCPServer.swift:
    - `catalogUpdates: AsyncStream<ToolCatalog>` (continuation wired at init) and a single emission point `emitCatalogSnapshot()` that increments `catalogEpoch` and yields — called from `applyConnect` success/failure, `call(toolNamed:)`'s mid-call fault path, and the coalesced re-list.
    - `registerToolListChangedHandler()` registers `client.onNotification(ToolListChangedNotification.self)` exactly once per actor (guarded by `hasRegisteredToolListChangedHandler`, since `MCP.Client.onNotification` appends handlers rather than replacing them — unlike `withMethodHandler`).
    - `tool(named:)` resolves against current `discoveredTools` (nil once removed); `MCPServer.toolNoLongerAvailableResult(named:)` + private `notAvailableResult(for:)` render the "no longer available" `isError` text via `ToolContentRenderer`, mirroring the existing `faultResult(for:)` pattern.

    Design dead-end worth recording: my first coalescing implementation used a background `Task` per notification that polled `toolListChangedGeneration` after `clock.sleep(for:)`, expecting a burst of concurrent notifications to "arrive during the sleep." This failed under `ManualClock`, because `ManualClock.sleep(until:tolerance:)` has no internal `await` and never actually suspends — so the spawned watcher task consistently raced ahead of and "won" against the concurrent notification-delivery pipeline (client message loop → our handler), producing 5 separate re-lists instead of 1, every run. I tried patching `ManualClock` to add `Task.yield()` calls to force cooperative scheduling — this "worked" with 50 yields but was still flaky at 10 yields (majority failures across 8 runs), confirming a fixed yield count is not a robust fix and I reverted `ManualClock.swift` entirely (no diff there).

    The actual fix: `coalesceAndRelist()` now does one initial `clock.sleep(for: toolListChangedCoalesceWindow)` (catches a burst that's fully queued before the watcher even starts), then repeats the **real** `tools/list` discovery round trip (`relistOnce()`) until a full round trip completes with the generation unchanged. Because a `tools/list` round trip is a genuine cross-actor, cross-transport exchange (unlike a clock sleep), it naturally gives concurrently-arriving notifications real scheduling room to be observed before the next stability check — this converged reliably across 10+ repeated runs of `--filter LiveCatalog` and 5 repeated full-suite runs (168 tests, 17 suites), with zero flakiness. Exactly one `catalogUpdates` emission happens at the end, regardless of how many internal discovery round trips it took to converge.

    Verification: `swift build` clean; `swift test --filter LiveCatalog` green (4/4) across 10 repeated runs; `swift test` full suite green (168 tests/17 suites) across 5 repeated runs.
  timestamp: 2026-07-04T23:49:15.258372+00:00
- actor: claude-code
  id: 01kwqs598y9tz3vqxqw5n3wdxm
  text: |-
    Adversarial double-check (via really-done) returned REVISE with two findings, both fixed:

    1. Stale doc-comment references to a method named `performRelist()` (leftover from the design iteration described in the previous comment) — the actual method is `relistOnce()`. Fixed both occurrences in MCPServer.swift's `emitCatalogSnapshot()` and `toolNoLongerAvailableResult(named:)` doc comments. Verified with `grep -rn performRelist . --include=*.swift` → no matches.

    2. Missing test coverage for the "readiness-state changes" emission trigger (the task's own third bullet) — none of the original 4 tests observed a `.faulted` snapshot from a failed reconnect or a mid-call transport fault. Added two tests to LiveCatalogTests.swift:
       - `failedReconnectEmitsFaultedSnapshot` — a reconnect via `FlakyConnectTransport` that fails after a prior successful connect emits a snapshot with `state == .faulted` and a higher epoch.
       - `midCallFaultEmitsFaultedThenReadySnapshots` — a mid-call transport fault (via `RespawningTransport`, mirroring `ResilienceTests`' own technique) emits a `.faulted` snapshot, then a `.ready` snapshot once auto-reconnect heals it, with strictly increasing epochs across all three emissions (connect, fault, reconnect).

    Re-verified after fixes: `swift build` clean; `swift test --filter LiveCatalog` green (6/6) across 9 repeated runs, no flakiness; full `swift test` green (170 tests/17 suites, up from 168 — the 2 new tests).

    Task is green and left in `doing` per /implement's process — ready for /review.
  timestamp: 2026-07-04T23:59:27.518269+00:00
depends_on:
- 01KWMS18GCCA8M5SWW0SDX0GAP
- 01KWMS1NTW01VREEHWT2729TVB
position_column: doing
position_ordinal: '80'
title: 'Live catalog: catalogUpdates stream, coalesced re-list, tool(named:) resolution'
---
## What\nAdd the dynamic half of the catalog to `MCPServer` per plan.md Dynamic discovery: `catalogUpdates: AsyncStream<ToolCatalog>` emitting a new versioned snapshot on (a) **coalesced** `tools/list_changed` re-list (debounce a burst of notifications into one re-list), (b) reconnect (implicit re-list — the returning server may differ), (c) readiness-state changes. Per-server epoch increments monotonically per emission. Add `tool(named:) -> MCPTool?` resolving against the **current** catalog (nil once gone) plus a helper producing the structured \"tool no longer available\" result text for consumers.\n\n- [x] catalogUpdates AsyncStream with epoch monotonicity\n- [x] list_changed burst coalesced into a single re-list\n- [x] Reconnect and state changes emit snapshots\n- [x] tool(named:) call-time resolution + not-available result helper\n\n## Acceptance Criteria\n- [x] 5 rapid scripted list_changed notifications produce exactly 1 re-list and 1 new snapshot (virtual clock)\n- [x] Epochs strictly increase across emissions; snapshots are complete (idempotent — consumable without prior state)\n- [x] After scripted tool removal, tool(named:) returns nil and the helper renders the structured not-available message\n\n## Tests\n- [x] `Tests/FoundationModelsMCPTests/LiveCatalogTests.swift`: coalescing, epoch monotonicity, reconnect-implies-relist, resolution nil-after-removal\n- [x] `swift test --filter LiveCatalog` green\n\n## Workflow\n- Use `/tdd` — write failing tests first, then implement to make them pass.