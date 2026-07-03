---
depends_on:
- 01KWMRYGMXC08VX2W7P2DK2X0W
position_column: todo
position_ordinal: '8480'
title: 'Test fixture: MockClient conforming to the library''s client seam'
---
## What
Create `Tests/FoundationModelsMCPTests/Support/MockClient.swift`: a mock/recording implementation of the **library's client seam protocol** (defined by the MCPTool adapter task — the swift-sdk's `MCP.Client` is a concrete actor and cannot be substituted directly). MockClient records `callTool(name:arguments:)` invocations exactly and returns scripted results: success, `isError`, `structuredContent`, and each content type (`.text`/`.image`/`.audio`/`.resource`/`.resourceLink`). Test-target only. (The scriptable server lives in its own utility-target task.)

- [ ] MockClient conforms to the client seam protocol
- [ ] Records name + arguments byte-for-byte
- [ ] Scripted results for success/error/structured/every content case

## Acceptance Criteria
- [ ] Compiles in the test target only (never shipped in the library)
- [ ] Self-test proves exact recording and scripted-result playback

## Tests
- [ ] `Tests/FoundationModelsMCPTests/Support/MockClientSelfTests.swift`: recording fidelity + playback of each scripted result kind
- [ ] `swift test --filter MockClientSelf` green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.