---
depends_on:
- 01KWMRYGMXC08VX2W7P2DK2X0W
position_column: todo
position_ordinal: '8280'
title: 'GeneratedContentCodec: GeneratedContent ⇄ MCP.Value round-trip'
---
## What
Create `Sources/FoundationModelsMCP/GeneratedContentCodec.swift`: convert FoundationModels `GeneratedContent` → `[String: MCP.Value]` (outbound tool-call arguments) and `MCP.Value` → `GeneratedContent` (for round-tripping). Handle nested objects, arrays, strings (incl. unicode/escaping), integer vs. double distinction, booleans, and null.

- [ ] GeneratedContent → [String: MCP.Value]
- [ ] MCP.Value → GeneratedContent
- [ ] Numeric fidelity (int vs double), null, unicode strings

## Acceptance Criteria
- [ ] Round-trip of any supported value tree is lossless (value-equal)
- [ ] Integers survive as integers (no silent double-ification) where the SDK distinguishes them

## Tests
- [ ] `Tests/FoundationModelsMCPTests/CodecTests.swift`: round-trip property-style tests over generated value trees (nested objects/arrays, numbers, null, unicode)
- [ ] `swift test --filter Codec` green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.