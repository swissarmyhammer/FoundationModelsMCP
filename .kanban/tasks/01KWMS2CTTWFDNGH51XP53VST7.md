---
comments:
- actor: claude-code
  id: 01kwqwmws7bens6ts6txagp4yz
  text: |-
    Implementation complete, pending adversarial double-check before final handoff.

    What was built (TDD: wrote Tests/FoundationModelsMCPTests/CancellationTests.swift first, confirmed compile-fail RED, then implemented):

    1. Sources/FoundationModelsMCP/CallDeadline.swift — new pure `CallDeadline` struct (timeout + resetCount, resetForProgress()). No Clock/Instant state — deliberately, so its "did a reset happen" logic is unit-testable without racing real concurrency.

    2. Sources/FoundationModelsMCP/MCPServer.swift:
       - `call(toolNamed:arguments:timeout:)` now attaches a fresh `ProgressToken`, registers `activeCalls[token]` bookkeeping *before* sending the request (avoids a same-actor-turn race where fast progress could arrive before bookkeeping exists), and wraps the awaited response in `withTaskCancellationHandler` whose `onCancel` fires `client.cancelRequest(_:reason:)` — this is the explicit protocol-level `notifications/cancelled` send, since the swift-sdk does NOT do this automatically on Task cancellation (verified by reading swift-sdk source, documented in docs/swift-sdk-notes.md).
       - New `resultOrTimeout(...)` races the real response against a timeout-enforcement loop in a `withThrowingTaskGroup`, comparing `CallDeadline.resetCount` before/after each sleep to detect a progress-driven reset.
       - IMPORTANT: the timeout loop uses real `Task.sleep(for:)`, NOT the actor's injectable `clock`. I initially used `clock.sleep`, which broke pre-existing ResilienceTests/LiveCatalogTests that inject `ManualClock()` for unrelated backoff-testing — `ManualClock.sleep` never truly suspends, so the timeout race always "won" instantly against genuinely-in-flight calls. Reverted to always-real-wall-clock timing, mirroring the established `connectAttemptTimedOut` precedent ("measured against real wall-clock time — never `clock`"). This matches the task's own hint that ManualClock "doesn't suspend properly for real concurrent racing scenarios."
       - New `progressUpdates: AsyncStream<CallProgress>` (same continuation-pairing pattern as `catalogUpdates`), fed by `registerProgressHandler()`/`handleProgressNotification(_:)`, mirroring the existing `registerToolListChangedHandler()` once-per-actor registration pattern.
       - New `MCPServerError.callTimedOut(toolName:)` case.
       - `call()`'s catch clauses are ordered so `CancellationError` and `.callTimedOut` render their own isError result WITHOUT touching `state`/reconnecting (only genuine transport faults do that).

    3. docs/swift-sdk-notes.md — appended two sections confirming from swift-sdk source: (a) Task cancellation does NOT auto-propagate to `notifications/cancelled` — `Client.cancelRequest` is the explicit, separate API MCPServer now calls; (b) progress notifications are opt-in per-request via `_meta.progressToken`, with no SDK-level timeout/reset semantics — that policy is entirely `MCPServer`'s own.

    Verification: `swift build` clean (no warnings), `swift test` 176/176 passed across 18 suites, `swift test --filter Cancellation` 6/6 passed.

    Design judgment calls: added an optional per-call `timeout:` override parameter (not just the host-configurable default) since it fit the existing `call(toolNamed:arguments:)` signature naturally. Kept `CallDeadline` as module-internal (no `public`) since it's a pure implementation detail, testable via `@testable import`. Currently running the really-done adversarial double-check before final handoff.
  timestamp: 2026-07-05T01:00:24.743310+00:00
- actor: claude-code
  id: 01kwqx58xqbr5qys57wggj576p
  text: |-
    Adversarial double-check (via really-done) returned REVISE with two findings, both documentation-accuracy issues, no functional defects:

    1. Task description said "virtual clock" for the timeout tests, but the implementation deliberately uses real wall-clock timing (justified, and empirically necessary — see below). Fixed: updated this task's Acceptance Criteria/Tests checkboxes and added an inline note explaining the real-clock decision and reconciling it with the original wording; checked off all boxes.
    2. A code comment in MCPServer.swift claimed the onCancel-closure's unstructured `Task {}` was "the one deliberate exception" to the file's no-unmanaged-Task convention, which was inaccurate — `performConnectAttempt(transport:timeout:)` (pre-existing, untouched by this task) already has its own un-joined connect-race Tasks. Fixed: softened the comment to "one of the few deliberate exceptions... (see also `performConnectAttempt`'s un-joined connect-race Tasks)".

    Re-ran `swift build` (clean) and `swift test` (176/176 passed, 18 suites) after both fixes to confirm nothing broke. Per the really-done skill's bounded-loop guidance (fix findings, re-spawn double-check at most once), both findings were doc/record-keeping only and directly actionable, so I applied the fixes and re-verified rather than re-spawning a second full adversarial pass. Ready for /review.
  timestamp: 2026-07-05T01:09:21.463291+00:00
depends_on:
- 01KWMS18GCCA8M5SWW0SDX0GAP
position_column: doing
position_ordinal: '80'
title: Protocol-level cancellation, progress, and per-call timeouts
---
## What
Per plan.md M5/Lifecycle: (1) Swift task cancellation of an in-flight tool call **propagates to protocol-level `notifications/cancelled`** (via the SDK where it does this; send explicitly where it doesn't — record which in `docs/swift-sdk-notes.md`) so servers don't run orphaned work. (2) Per-call **timeout** with a host-configurable default; an incoming `notifications/progress` for the call **resets** the timeout. (3) Progress notifications are surfaced to the host as an event stream/callback on `MCPServer`.

- [x] Swift cancel → notifications/cancelled on the wire
- [x] Per-call timeout (configurable), reset by progress
- [x] Progress surfaced to host
- [x] SDK-vs-explicit cancellation path documented

## Acceptance Criteria
- [x] Cancelling the Swift task around call() results in a cancelled notification observed by the scripted server
- [x] A call with no progress times out at the configured bound; the same call with periodic scripted progress does not — implemented and tested with **real wall-clock timing** (small millisecond durations), not the injectable `clock`/`ManualClock`. Investigated per this card's own hint: `ManualClock.sleep` never truly suspends (no internal await), so racing it against a genuinely in-flight call makes the timeout side always "win" instantly — confirmed empirically when an initial `clock.sleep`-based implementation broke pre-existing ResilienceTests/LiveCatalogTests that inject `ManualClock` for unrelated backoff testing. Reverted to real `Task.sleep(for:)`, mirroring the established `connectAttemptTimedOut` precedent ("measured against real wall-clock time — never `clock`"). The pure reset/expiry arithmetic (`CallDeadline`) is unit-tested directly with no concurrency at all, per the card's suggested alternative.
- [x] Host observer receives each scripted progress event

## Tests
- [x] `Tests/FoundationModelsMCPTests/CancellationTests.swift`: wire-level cancelled notification, timeout firing/reset (real wall-clock, see note above) and `CallDeadline` unit tests, progress event delivery
- [x] `swift test --filter Cancellation` green (6/6)

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.