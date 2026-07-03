---
depends_on:
- 01KWMS0CJ2DMWM46AB5JE50TAR
- 01KWMSDVP4JM77YR0YMCE9S5ME
position_column: todo
position_ordinal: '8780'
title: 'MCPServer core: async discovery, pagination to exhaustion, readiness states'
---
## What
Create `Sources/FoundationModelsMCP/MCPServer.swift` (actor): wraps one `MCP.Client` (caller owns transport setup). Async connect + `listTools()` **following `nextCursor` to exhaustion** (tools/list is paginated — a one-page read silently truncates). Readiness state machine: `connecting / ready / faulted`, exposed as an async-awaitable property. Once ready, maps each `MCP.Tool` into an `MCPTool` and vends `[MCPTool]` / `[any FoundationModels.Tool]`. Establish a **stable `ServerIdentity`** value (host-supplied name or derived, documented) that survives reconnects.

- [ ] Actor wrapping MCP.Client, async connect + full paginated discovery
- [ ] Readiness state machine (connecting/ready/faulted)
- [ ] Vend [MCPTool] / [any Tool]
- [ ] Stable ServerIdentity

## Acceptance Criteria
- [ ] With a 3-page scripted tools/list, all pages' tools are discovered (no truncation)
- [ ] State transitions connecting→ready observed; faulted on scripted connect failure
- [ ] ServerIdentity is identical before and after a scripted reconnect

## Tests
- [ ] `Tests/FoundationModelsMCPTests/MCPServerDiscoveryTests.swift`: paginated discovery completeness, state transitions, identity stability (uses ScriptedServer/MockClient)
- [ ] `swift test --filter MCPServerDiscovery` green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.