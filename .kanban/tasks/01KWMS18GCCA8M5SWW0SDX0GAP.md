---
depends_on:
- 01KWMS0RQH4YWDJGDAVR1M7FAY
position_column: todo
position_ordinal: '8880'
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