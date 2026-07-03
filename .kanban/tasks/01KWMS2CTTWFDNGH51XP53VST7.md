---
depends_on:
- 01KWMS18GCCA8M5SWW0SDX0GAP
position_column: todo
position_ordinal: 8c80
title: Protocol-level cancellation, progress, and per-call timeouts
---
## What
Per plan.md M5/Lifecycle: (1) Swift task cancellation of an in-flight tool call **propagates to protocol-level `notifications/cancelled`** (via the SDK where it does this; send explicitly where it doesn't — record which in `docs/swift-sdk-notes.md`) so servers don't run orphaned work. (2) Per-call **timeout** with a host-configurable default; an incoming `notifications/progress` for the call **resets** the timeout. (3) Progress notifications are surfaced to the host as an event stream/callback on `MCPServer`.

- [ ] Swift cancel → notifications/cancelled on the wire
- [ ] Per-call timeout (configurable), reset by progress
- [ ] Progress surfaced to host
- [ ] SDK-vs-explicit cancellation path documented

## Acceptance Criteria
- [ ] Cancelling the Swift task around call() results in a cancelled notification observed by the scripted server
- [ ] A call with no progress times out at the configured bound; the same call with periodic scripted progress does not (virtual clock)
- [ ] Host observer receives each scripted progress event

## Tests
- [ ] `Tests/FoundationModelsMCPTests/CancellationTests.swift`: wire-level cancelled notification, timeout firing/reset via injected clock, progress event delivery
- [ ] `swift test --filter Cancellation` green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.