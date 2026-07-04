---
comments:
- actor: claude-code
  id: 01kwq7xcysv5vzr6t2ecskw06g
  text: |-
    Implemented via TDD:
    - Tests/FoundationModelsMCPTests/MCPServerDiscoveryTests.swift written first (6 tests), confirmed RED (compile failure — MCPServer didn't exist).
    - Sources/FoundationModelsMCP/MCPServer.swift implemented: actor wrapping MCP.Client directly (not through MCPToolCalling — MCPServer owns the client's whole connect/discover/reconnect lifecycle, unlike MCPTool which only forwards individual tools/call). Types: MCPServerState (connecting/ready/faulted(String)), ServerIdentity (Sendable/Hashable wrapper around a stable name), MCPServerError.notReady(state).
    - connect(transport:) resets state to .connecting, calls client.connect(transport:), establishes identity once (host-supplied name if given at init, else derived from serverInfo.name — never recomputed on later connects), then paginates tools/list via nextCursor to exhaustion, maps each MCP.Tool into MCPTool, and only then sets state = .ready. Any throw along the way sets state = .faulted(description) and rethrows.
    - mcpTools()/foundationModelsTools() throw MCPServerError.notReady(state) unless ready.

    Verification: swift build (clean, no warnings) and swift test (119/119 tests pass, including the new MCPServerDiscovery suite's 6 tests: pagination completeness across a 3-page scripted tools/list, state transitions connecting→ready, faulted on a FlakyConnectTransport-scripted connect failure, notReady-before-first-connect, and identity stability across a reconnect where the second scripted server deliberately reports a DIFFERENT name to prove identity isn't recomputed).

    Design judgment calls:
    1. MCPServer wraps MCP.Client concretely (not via a protocol seam) per the task's own suggestion, since this actor owns the client's lifecycle at a different level than MCPTool.
    2. faulted(String) instead of faulted(any Error) since Error isn't Sendable/Equatable generically; needed for the state to cross actor boundaries and be asserted in tests.
    3. identity is nil until first successful connect, then permanently cached — proven via a reconnect test against a second ScriptedServer with a different name.

    Adversarial double-check agent launched to review before final handoff.
  timestamp: 2026-07-04T18:58:03.353196+00:00
- actor: claude-code
  id: 01kwq86v8bc3z86g4es1pyewcz
  text: |-
    Adversarial double-check round 1 found a real High-severity bug: `identity` was assigned right after the transport handshake succeeded but before pagination/discovery completed, so a discovery-phase failure (e.g. a tool with a malformed inputSchema) left `identity` set while `state == .faulted` — contradicting the documented "identity only survives a fully successful connect" invariant. Also a Low finding: the `Throws` doc on `connect(transport:)` didn't mention `MCPTool.init` as a throw source.

    Fixed via proper red-green-red TDD cycle:
    1. Added a regression test (`identityRemainsNilWhenDiscoveryFailsAfterSuccessfulHandshake`) using a tool with an unresolvable `$ref` inputSchema (confirmed via SchemaConverter.swift that this throws GenerationSchema.SchemaError from SchemaConverter.emit).
    2. Temporarily reverted the fix, ran the test, confirmed it failed for the right reason (identity was non-nil when it should have been nil).
    3. Re-applied the fix (moved discoverAllTools() before the identity assignment in connect(transport:)) and confirmed the test passes.
    4. Updated doc comments on `identity` and `connect(transport:)` (including the Throws clause) to describe the corrected invariant.

    swift build clean, swift test: 120/120 pass (was 119, +1 for the new regression test).

    Re-spawned double-check once (bounded per really-done's contract) to independently verify the fix. Awaiting its verdict before final handoff.
  timestamp: 2026-07-04T19:03:12.907222+00:00
- actor: claude-code
  id: 01kwq8amcnc4xva55egp20e3r6
  text: |-
    Double-check round 2: PASS. Independently re-verified the identity/state fix by tracing all four connect(transport:) paths (success, handshake failure, first-attempt discovery failure, reconnect discovery failure with identity already set) and confirmed identity/state stay consistent in every case. Confirmed the Throws doc fix and re-ran build+tests independently (120/120).

    Final fresh verification run by me:
    - swift build: clean, exit 0.
    - swift test (full suite): 120/120 pass, 11 suites.
    - swift test --filter MCPServerDiscovery: 7/7 pass.

    Task is complete and green. Leaving in `doing` per the implement workflow — ready for `/review`.

    Summary of what was built:
    - Sources/FoundationModelsMCP/MCPServer.swift — new actor wrapping MCP.Client directly. Types: MCPServerState (connecting/ready/faulted(String)), ServerIdentity (Sendable/Hashable), MCPServerError.notReady(state). connect(transport:) resets to .connecting, performs the handshake, paginates tools/list to exhaustion via nextCursor, maps each MCP.Tool to MCPTool, establishes identity only once the whole call succeeds (host-supplied name takes precedence, else derived from serverInfo.name, never recomputed after), then sets .ready. Any failure anywhere in that sequence sets .faulted(description) without touching identity, and rethrows. mcpTools()/foundationModelsTools() throw MCPServerError.notReady(state) unless ready. disconnect() delegates to the wrapped client.
    - Tests/FoundationModelsMCPTests/MCPServerDiscoveryTests.swift — 7 tests: 3-page pagination completeness (mcpTools() and foundationModelsTools()), state transitions connecting→ready, faulted on a FlakyConnectTransport-scripted connect failure, notReady-before-first-connect, identity stability across a reconnect (second scripted server deliberately reports a different name), and the discovery-phase-failure regression test added during review.

    All work done via TDD throughout, including a red-green-red cycle for the review-driven fix.
  timestamp: 2026-07-04T19:05:16.949036+00:00
depends_on:
- 01KWMS0CJ2DMWM46AB5JE50TAR
- 01KWMSDVP4JM77YR0YMCE9S5ME
position_column: doing
position_ordinal: '80'
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