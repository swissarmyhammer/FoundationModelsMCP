---
depends_on:
- 01KWMS0RQH4YWDJGDAVR1M7FAY
position_column: todo
position_ordinal: '8980'
title: MCPToolProvider + LanguageModelSession(mcp:) convenience + name collisions
---
## What
Create `Sources/FoundationModelsMCP/MCPToolProvider.swift`: `public protocol MCPToolProvider { func sessionTools() async throws -> [any FoundationModels.Tool] }`. Conformances: `MCPTool` → `[self]`; `MCPServer` → awaits readiness, returns its `[MCPTool]`; collection/variadic composition flattens. **Factor the flattening + collision resolution into a directly testable function** (e.g. `resolveSessionTools(from providers:) async throws -> [any Tool]`) and make the `LanguageModelSession(mcp:...)` convenience a thin wrapper that passes its output to `LanguageModelSession(tools:)` — tests assert on the function's output, never on session introspection (`LanguageModelSession` does not expose its tool list). Cross-server tool-name collisions get deterministic, documented disambiguation (e.g. `serverName_toolName`) plus a log record.

- [ ] MCPToolProvider protocol + MCPTool/MCPServer conformances
- [ ] Testable resolveSessionTools (flattening + collision policy)
- [ ] LanguageModelSession(mcp:) thin convenience over it
- [ ] Collision determinism + logging

## Acceptance Criteria
- [ ] resolveSessionTools blocks until servers ready (delayed scripted connect)
- [ ] Two servers with an identically-named tool yield two distinct, deterministic names (same input → same names across runs)
- [ ] The convenience init compiles and forwards resolveSessionTools output verbatim (asserted via the factored function)

## Tests
- [ ] `Tests/FoundationModelsMCPTests/ProviderTests.swift`: flattening, readiness blocking, collision determinism — all against resolveSessionTools
- [ ] `swift test --filter ProviderTests` green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.