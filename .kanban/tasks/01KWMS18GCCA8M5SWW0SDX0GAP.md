---
comments:
- actor: claude-code
  id: 01kwq9yxwskm799yx6n7cn0csy
  text: |-
    Implemented via TDD. Added Tests/FoundationModelsMCPTests/ResilienceTests.swift (4 tests, RED confirmed first via compile failure), plus test support: Tests/FoundationModelsMCPTests/Support/ManualClock.swift (virtual Clock using Synchronization.Mutex — NSLock lock()/unlock() are unavailable from async contexts under Swift 6 strict concurrency) and Tests/FoundationModelsMCPTests/Support/RespawningTransport.swift (a Transport double whose connect() always builds a brand-new (transport, ScriptedServer) pair, needed because a real MCP.Server refuses to re-initialize an already-initialized session — reusing the same server across a simulated reconnect crashes with "Server is already initialized").

    MCPServer.swift additions: BackoffPolicy (connectTimeout/baseDelay/maxDelay/maxAttempts, documented defaults), MCPServerError.backoffExhausted(serverName:attempts:lastError:) and .connectAttemptTimedOut, connect(transport:backoffPolicy:) overload (retries the existing single-attempt connect(transport:) with exponential backoff via an injectable `any Clock<Duration>`), call(toolNamed:arguments:) (never throws — mid-call faults render as isError content via ToolContentRenderer and trigger auto-reconnect using the last transport + last-used backoff policy).

    Found and fixed a real concurrency bug along the way: MCP.Client.connect(transport:) never cancels its previous message-handling Task before starting a new one, so calling connect() again on an already-connected client without disconnecting first crashes ("attempt to await next() on more than one task", two Tasks racing on the same AsyncThrowingStream). Fixed by adding `await client.disconnect()` at the top of connect(transport:) — safe no-op when never connected, matches the existing identityStableAcrossReconnect test's own explicit-disconnect-first pattern.

    Design note: BackoffPolicy.connectTimeout is enforced via a TaskGroup race against real Task.sleep(for:), not the injectable clock — deliberate, since a virtual/manual clock's instant "sleep" would always win a race against real async work, which would make the connect-retry tests spuriously hit the timeout path instead of the intended fail/succeed schedule.

    Package.swift: added Logging as a FoundationModelsMCP target dependency (was previously only wired to MCPTestServer).

    swift build && swift test: 124/124 tests green, 0 failures, 0 warnings. Adversarial double-check agent launched to review before handoff.
  timestamp: 2026-07-04T19:33:50.617351+00:00
- actor: claude-code
  id: 01kwqbg7h8fxk61ajqe91zzecp
  text: |-
    Adversarial double-check (round 1) returned REVISE with two findings:
    1. (High) `performConnectAttempt`'s `withThrowingTaskGroup` race between the connect attempt and the timeout blocks on the loser task before returning — a throwing task group always awaits every child (even cancelled ones) before the group itself returns, and `MCP.Client.connect(transport:)` never checks `Task.isCancelled`, so a genuinely wedged `Transport.connect()` would defeat `connectTimeout` entirely. Untested.
    2. (Low-medium) production docs didn't disclose that auto-reconnect only works if the transport's own `connect()` supports redial (the literal same transport instance is reused).

    Fixed both: `performConnectAttempt` now races the connect attempt as an independent, un-joined `Task` against a timeout `Task`, synchronized via a new `SingleResume` helper (`Synchronization.Mutex`-backed, resumes a `CheckedContinuation` exactly once). Added a `connectGeneration` counter and split `connect(transport:)`'s body into `applyConnect(transport:generation:)`, which discards a stale (superseded) result instead of mutating `state`/`identity`/`discoveredTools`. Added `HangingTransport` (connect() that never returns) and a test proving the retry loop returns in ~50ms against a 50ms `connectTimeout` even though the hang is permanent. Added a doc note on `lastTransport` disclosing the redial dependency.

    Round 2 re-check (bounded per really-done's process — this was the last one) found two more real issues, which I fixed directly without spawning a third round:
    1. (High) The generation guard didn't cover the backoff-*exhaustion* path — `connect(transport:backoffPolicy:)` threw `backoffExhausted` without bumping `connectGeneration`, so an orphaned attempt that resolves after exhaustion (not just permanently-hung ones) could still clobber state. Fixed by bumping `connectGeneration` right before throwing `backoffExhausted`. Added a regression test (`lateResolvingAttemptAfterExhaustionIsDiscarded`) using a new `GatedConnectTransport` double (blocks until manually released) that reproduces exactly this timing window and asserts the late success is discarded.
    2. (Medium) `HangingTransport.connect()` used `Task.sleep(for:)`, which is cancellation-responsive — verified empirically by the reviewer that even the old buggy `withThrowingTaskGroup` implementation would pass against it, so it wasn't a real regression guard. Fixed by hanging on an unresumed `withCheckedContinuation` with no cancellation handler, which genuinely never returns regardless of cancellation — confirmed the fixed code still returns in ~55ms against this stricter double (proving the un-joined-Task design, not cooperative cancellation, is what makes it work).

    Final state: swift build clean (0 warnings), swift test 126/126 green (was 124 before this task; +ResilienceTests with 6 tests). Ready for review.
  timestamp: 2026-07-04T20:00:46.120861+00:00
depends_on:
- 01KWMS0RQH4YWDJGDAVR1M7FAY
position_column: doing
position_ordinal: '80'
title: 'MCPServer resilience: backoff connect, auto-reconnect, fault → isError'
---
## What
Add connection resilience to `MCPServer` per plan.md Lifecycle policy: connect retries with **exponential backoff** (per-attempt connect timeout, backoff base/cap, max attempts — all host-overridable via a `BackoffPolicy` config with documented defaults); hard-fail only when backoff is exhausted. **Auto-reconnect** on transport error with the same policy (use the SDK's transport reconnect where available, wrap where not). A mid-call transport fault maps to an `isError`-style rendered result so the model can react. Structured logging (swift-log/OSLog) on every retry/reconnect/fault.

- [ ] BackoffPolicy config (timeout, base, cap, max attempts) + defaults
- [ ] Connect retry loop, hard-fail on exhaustion
- [ ] Auto-reconnect on transport error
- [ ] Mid-call fault → rendered error result; structured log events

## Acceptance Criteria
- [ ] With a fail-twice-then-succeed scripted transport, connect succeeds on attempt 3 with expected backoff schedule (virtual clock — no real sleeps in tests)
- [ ] Exhausted backoff throws a typed error naming the server identity
- [ ] A call during a scripted drop returns an error result (not a hang or crash) and the server re-enters ready after reconnect

## Tests
- [ ] `Tests/FoundationModelsMCPTests/ResilienceTests.swift`: retry counts + schedule via injected clock, exhaustion error, fault→isError mapping, reconnect to ready
- [ ] `swift test --filter Resilience` green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.