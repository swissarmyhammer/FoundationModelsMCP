---
comments:
- actor: claude-code
  id: 01kwpnq6r9399516n4fycza8x9
  text: |-
    Implemented via TDD.

    Reused the existing client seam (Sources/FoundationModelsMCP/MCPToolCalling.swift) and MockClient test double as instructed — did not recreate them.

    Created:
    - Sources/FoundationModelsMCP/MCPTool.swift — public struct `MCPTool: FoundationModels.Tool` (had to write the conformance as `FoundationModels.Tool` explicitly; bare `Tool` is ambiguous with `MCP.Tool` in this file, both imported). Holds the source `tool: MCP.Tool` and `private let client: any MCPToolCalling`. `typealias Arguments = GeneratedContent`. `name`/`description`/`title`/`inputSchema` are computed properties forwarding verbatim to `tool` (description falls back to `""` since `Tool.description` is non-optional but MCP's is `String?`). `parameters: GenerationSchema` is precomputed in `init(tool:client:) throws` via `SchemaConverter.parse` → `SchemaConverter.emit` (throws on invalid schema graphs). `includesSchemaInInstructions = true`. `call(arguments:)` is a pure pass-through: `GeneratedContentCodec.arguments(from:)` → `client.callTool(name:arguments:)` → `ToolContentRenderer.render(result, outputSchema: tool.outputSchema)` — no validation/repair logic, isError bubbles to the renderer (never thrown), a thrown transport error propagates unchanged.
    - Tests/FoundationModelsMCPTests/MCPToolTests.swift — 10 tests via MockClient: exact name/argument forwarding (incl. nested object+array), success/isError/structuredContent rendering, thrown-transport-error propagation, name/description/title/inputSchema sourced verbatim from MCP.Tool, description empty-string fallback, includesSchemaInInstructions always true, parameters construction succeeds.

    TDD: wrote the test file first, watched it fail (`cannot find type 'MCPTool' in scope`), then implemented to green.

    Verification (all fresh, this session):
    - `swift test --filter MCPToolTests` → 10/10 pass.
    - Clean rebuild (`rm -rf .build/out && swift build`) → Build complete, zero warnings.
    - Full `swift test` after clean build → 91/91 tests pass across 7 suites, zero warnings.
    - Adversarial double-check agent → PASS (verified the pass-through has no validation/repair, isError renders rather than throws, thrown errors propagate, nested arguments round-trip exactly, protocol shape matches plan.md, and test quality/doc-comment conventions hold).

    Leaving in `doing` per /implement process — not moving to review myself.
  timestamp: 2026-07-04T13:40:06.025805+00:00
depends_on:
- 01KWMRYXFKKEW3QDHEFF7Z2QB4
- 01KWMRZ2ZKRP65RWRWM8W5R0FG
- 01KWMRZ90WFKXY5GZK58M75STZ
- 01KWMRZF9J01K0P1FT53RVBP61
position_column: doing
position_ordinal: '80'
title: 'MCPTool: the FoundationModels.Tool adapter'
---
## What\nCreate `Sources/FoundationModelsMCP/MCPTool.swift`: the generic adapter conforming to `FoundationModels.Tool`. **First, define the client seam**: a minimal library protocol (e.g. `MCPToolCalling`) with the `callTool(name:arguments:) async throws -> CallTool.Result` requirement; extend the SDK's `MCP.Client` to conform. This is a deliberate, narrow exception to \"no bespoke MCP types\" — it is a seam for substitutability (the SDK client is a concrete actor), not a domain-type re-model; document that rationale. `MCPTool` holds `any MCPToolCalling`. Then: `typealias Arguments = GeneratedContent`; `parameters` precomputed via `SchemaConverter`; `name`/`description`/`title`/metadata from the source `MCP.Tool`; `includesSchemaInInstructions = true`. `call(arguments:)` encodes via `GeneratedContentCodec` → seam `callTool` → renders via `ToolContentRenderer`. Pure pass-through — no validation/repair (server is the validator; `isError` bubbles). Expose the **raw `inputSchema` verbatim** as a public property.\n\nNote: the client seam (`MCPToolCalling` + `MCP.Client` conformance) was already created by a prior task (Sources/FoundationModelsMCP/MCPToolCalling.swift) and reused here as-is, per that task's own resolution note.\n\n- [x] Client seam protocol + MCP.Client conformance (documented rationale) — reused from prior task, not recreated\n- [x] Tool conformance with Arguments = GeneratedContent\n- [x] call(): codec → seam callTool → renderer; errors rendered\n- [x] Raw inputSchema exposed as public data\n\n## Acceptance Criteria\n- [x] Exact tool name and encoded arguments reach the seam (verified via MockClient)\n- [x] Success, isError, and thrown-transport-error paths each produce model-consumable output\n- [x] No JSON-Schema validation code exists in call()\n\n## Tests\n- [x] `Tests/FoundationModelsMCPTests/MCPToolTests.swift`: with MockClient — forwarded name/args byte-for-byte; rendering of success/error/structuredContent results\n- [x] `swift test --filter MCPToolTests` green\n\n## Workflow\n- Use `/tdd` — write failing tests first, then implement to make them pass.