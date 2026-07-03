---
depends_on:
- 01KWMRYXFKKEW3QDHEFF7Z2QB4
- 01KWMRZ2ZKRP65RWRWM8W5R0FG
- 01KWMRZ90WFKXY5GZK58M75STZ
- 01KWMRZF9J01K0P1FT53RVBP61
position_column: todo
position_ordinal: '8680'
title: 'MCPTool: the FoundationModels.Tool adapter'
---
## What
Create `Sources/FoundationModelsMCP/MCPTool.swift`: the generic adapter conforming to `FoundationModels.Tool`. **First, define the client seam**: a minimal library protocol (e.g. `MCPToolCalling`) with the `callTool(name:arguments:) async throws -> CallTool.Result` requirement; extend the SDK's `MCP.Client` to conform. This is a deliberate, narrow exception to "no bespoke MCP types" — it is a seam for substitutability (the SDK client is a concrete actor), not a domain-type re-model; document that rationale. `MCPTool` holds `any MCPToolCalling`. Then: `typealias Arguments = GeneratedContent`; `parameters` precomputed via `SchemaConverter`; `name`/`description`/`title`/metadata from the source `MCP.Tool`; `includesSchemaInInstructions = true`. `call(arguments:)` encodes via `GeneratedContentCodec` → seam `callTool` → renders via `ToolContentRenderer`. Pure pass-through — no validation/repair (server is the validator; `isError` bubbles). Expose the **raw `inputSchema` verbatim** as a public property.

- [ ] Client seam protocol + MCP.Client conformance (documented rationale)
- [ ] Tool conformance with Arguments = GeneratedContent
- [ ] call(): codec → seam callTool → renderer; errors rendered
- [ ] Raw inputSchema exposed as public data

## Acceptance Criteria
- [ ] Exact tool name and encoded arguments reach the seam (verified via MockClient)
- [ ] Success, isError, and thrown-transport-error paths each produce model-consumable output
- [ ] No JSON-Schema validation code exists in call()

## Tests
- [ ] `Tests/FoundationModelsMCPTests/MCPToolTests.swift`: with MockClient — forwarded name/args byte-for-byte; rendering of success/error/structuredContent results
- [ ] `swift test --filter MCPToolTests` green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.