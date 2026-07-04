---
comments:
- actor: claude-code
  id: 01kwqg46zwn1gs0nhdyvdpfgbs
  text: |-
    Implementation complete via TDD:

    - Wrote Tests/FoundationModelsMCPTests/ProviderTests.swift first (RED: confirmed build failure — resolveSessionTools/LanguageModelSession(mcp:) didn't exist).
    - Created Sources/FoundationModelsMCP/MCPToolProvider.swift: `MCPToolProvider` protocol, `MCPTool`/`MCPServer` conformances, `resolveSessionTools(from:logger:)`, and `LanguageModelSession(mcp:)` convenience init.
    - Modified Sources/FoundationModelsMCP/MCPTool.swift: added private `nameOverride: String?` (name = nameOverride ?? tool.name) and internal `renamed(to:) -> MCPTool`, used only by the collision-resolution code — avoids needing a generic wrapper type since every provider in this package only ever vends MCPTool.
    - `MCPServer.sessionTools()` polls `state` every 5ms until `.ready` (mirrors ScriptedServer's own poll pattern for actor-isolated state with no completion signal) or throws `MCPServerError.notReady` on `.faulted`.
    - Collision policy: every tool sharing a name across >1 provider gets renamed to "<providerLabel>_<name>" (symmetric — both/all colliding tools renamed, not just the second one). providerLabel = MCPServer's ServerIdentity.name, or "provider<index>" fallback for a provider with no server identity (e.g. standalone MCPTool). Deterministic since ServerIdentity.name and providers array order are stable across runs. Logged via swift-log at "com.foundationmodelsmcp.mcptoolprovider".

    Design judgment calls:
    - Chose a private stored `nameOverride` + `renamed(to:)` on MCPTool over a generic type-erasing wrapper Tool, since collision handling only ever needs to rename concrete MCPTool instances in this codebase; a non-MCPTool colliding tool falls back to a logged warning + passthrough (documented as unreached in practice).
    - `waitUntilReady()`/`readinessPollInterval` added as an MCPServer extension inside MCPToolProvider.swift (not MCPServer.swift) since it's a provider-resolution-specific concern, not part of MCPServer's own public API surface.
    - `resolveSessionTools` takes `logger: Logger = Logger(label: "com.foundationmodelsmcp.mcptoolprovider")` as a default parameter (inline literal, not a shared top-level constant, to sidestep an unwanted public-API constant purely for default-argument visibility).

    Verification: `swift build` — clean, zero warnings. `swift test --filter ProviderTests` — 6/6 green. Full `swift test` — 137/137 green across 14 suites, zero compiler warnings.

    Adversarial double-check agent spawned for sign-off before handoff.
  timestamp: 2026-07-04T21:21:35.228056+00:00
- actor: claude-code
  id: 01kwqgeaavmfdn3zqegbmfg6e3
  text: |-
    Adversarial double-check verdict: REVISE (one finding). Independently re-ran `swift build`/`swift test` and confirmed 137/137 green, zero warnings; correctness review of waitUntilReady()'s actor isolation, the as?-casts for provider labeling/renaming, and the disambiguation algorithm all checked out. The one gap: the acceptance criterion "MCPServer conforms... throwing MCPServerError.notReady if it reaches .faulted" was implemented but had zero test coverage through the new MCPToolProvider path (existing .faulted tests in MCPServerDiscoveryTests/ResilienceTests never call sessionTools()/resolveSessionTools(from:)).

    Fixed: added `throwsWhenServerConnectionIsFaulted` to ProviderTests.swift — uses FlakyConnectTransport (failingConnectAttempts: 1) to fault a server's connect(transport:), confirms state == .faulted, then asserts resolveSessionTools(from: [server]) throws MCPServerError.notReady carrying the .faulted state.

    Re-verified: swift build clean (zero warnings), swift test — 138/138 green across 14 suites (ProviderTests now 7/7).
  timestamp: 2026-07-04T21:27:06.331971+00:00
depends_on:
- 01KWMS0RQH4YWDJGDAVR1M7FAY
position_column: doing
position_ordinal: '80'
title: MCPToolProvider + LanguageModelSession(mcp:) convenience + name collisions
---
## What\nCreate `Sources/FoundationModelsMCP/MCPToolProvider.swift`: `public protocol MCPToolProvider { func sessionTools() async throws -> [any FoundationModels.Tool] }`. Conformances: `MCPTool` → `[self]`; `MCPServer` → awaits readiness, returns its `[MCPTool]`; collection/variadic composition flattens. **Factor the flattening + collision resolution into a directly testable function** (e.g. `resolveSessionTools(from providers:) async throws -> [any Tool]`) and make the `LanguageModelSession(mcp:...)` convenience a thin wrapper that passes its output to `LanguageModelSession(tools:)` — tests assert on the function's output, never on session introspection (`LanguageModelSession` does not expose its tool list). Cross-server tool-name collisions get deterministic, documented disambiguation (e.g. `serverName_toolName`) plus a log record.\n\n- [x] MCPToolProvider protocol + MCPTool/MCPServer conformances\n- [x] Testable resolveSessionTools (flattening + collision policy)\n- [x] LanguageModelSession(mcp:) thin convenience over it\n- [x] Collision determinism + logging\n\n## Acceptance Criteria\n- [x] resolveSessionTools blocks until servers ready (delayed scripted connect)\n- [x] Two servers with an identically-named tool yield two distinct, deterministic names (same input → same names across runs)\n- [x] The convenience init compiles and forwards resolveSessionTools output verbatim (asserted via the factored function)\n\n## Tests\n- [x] `Tests/FoundationModelsMCPTests/ProviderTests.swift`: flattening, readiness blocking, collision determinism — all against resolveSessionTools\n- [x] `swift test --filter ProviderTests` green\n\n## Workflow\n- Use `/tdd` — write failing tests first, then implement to make them pass.