---
depends_on:
- 01KWMS1F9CC0XYB0Q446930PBX
- 01KWMSDVP4JM77YR0YMCE9S5ME
position_column: todo
position_ordinal: '9180'
title: 'M4: gated E2E — LanguageModelSession + real stdio MCP server (system model)'
---
## What
Create the gated end-to-end test: spawn a real stdio MCP server (the ScriptedServer as a subprocess, or a filesystem echo server), wrap in `MCPServer`, build `LanguageModelSession(mcp:)` on the **system model**, run a prompt engineered to trigger a tool call, and assert the tool was called and its result content appears in the response. Gated behind an environment flag (`FOUNDATIONMODELSMCP_E2E=1`) and excluded from the default unit run — it needs the OS 27 SDK + on-device model availability (`SystemLanguageModel.availability`).

- [ ] Gated E2E target/flag, skipped by default with a clear skip message
- [ ] Real stdio server spawn + session construction via LanguageModelSession(mcp:)
- [ ] Prompt → tool call → result assertion

## Acceptance Criteria
- [ ] `swift test` (default) skips the E2E with an explanatory message
- [ ] `FOUNDATIONMODELSMCP_E2E=1 swift test --filter E2E` on capable hardware performs a real tool call and asserts on the returned content
- [ ] Unavailable model (availability check fails) → clean skip, not failure

## Tests
- [ ] `Tests/FoundationModelsMCPTests/E2ETests.swift` as described (this task IS the test)
- [ ] Default `swift test` remains green on CI without the model

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.