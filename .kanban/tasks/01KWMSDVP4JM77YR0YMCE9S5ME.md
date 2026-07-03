---
depends_on:
- 01KWMRYGMXC08VX2W7P2DK2X0W
position_column: todo
position_ordinal: '9580'
title: 'Test fixture: ScriptedServer utility target with full scenario scripting'
---
## What
Create `MCPTestServer` — a **dedicated non-shipped utility target** (internal library + small executable wrapper), usable by BOTH the test target and the `Examples/` executables (never a dependency of the `FoundationModelsMCP` library product). It is a scriptable MCP server with modes/commands for every scenario downstream tasks test: (1) echo tool; (2) filesystem-style multi-tool mode; (3) `tools/list` paginated across N pages (`nextCursor`); (4) `tools/list_changed` emission on command (including rapid bursts); (5) add/remove/re-schema tools on command or timer; (6) **fail-N-times-then-succeed connects** (scripted connect-failure count); (7) transport drop mid-call on command; (8) a tool that **elicits mid-call** (`elicitation/create`) with scripted expectations; (9) periodic **`notifications/progress`** emission during a long call; (10) **records inbound notifications** (esp. `notifications/cancelled`) for test assertion.

- [ ] Utility target wired for tests + Examples, excluded from library product
- [ ] Scenarios 1–5 (tools, pagination, list_changed, mutation)
- [ ] Scenarios 6–7 (connect-failure count, mid-call drop)
- [ ] Scenarios 8–10 (elicit-on-command, progress emission, inbound-notification recording)

## Acceptance Criteria
- [ ] Library product's dependency closure does NOT include MCPTestServer (asserted by a Package.swift check in CI)
- [ ] Each scripted scenario is driveable from a test and observable (self-tests below)
- [ ] Usable both in-process (tests) and as a spawned stdio subprocess (Examples/E2E)

## Tests
- [ ] `Tests/FoundationModelsMCPTests/ScriptedServerSelfTests.swift`: one self-test per scenario 3–10 proving the scripting works (pagination page count, burst emission, connect-failure countdown, elicit round-trip, progress cadence, cancelled-notification recording)
- [ ] `swift test --filter ScriptedServerSelf` green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.