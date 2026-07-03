---
depends_on:
- 01KWMRYGMXC08VX2W7P2DK2X0W
position_column: todo
position_ordinal: '8180'
title: 'SchemaConverter: JSON Schema structure → DynamicGenerationSchema (+ corpus)'
---
## What
Create `Sources/FoundationModelsMCP/SchemaConverter.swift` converting an MCP `inputSchema` (`MCP.Value`, JSON Schema 2020-12) to `GenerationSchema`. **Because `DynamicGenerationSchema`/`GenerationSchema` are opaque (no public introspection), convert in two stages**: (1) parse into an **inspectable internal IR** (`SchemaIR`: property names, types, optionality, nesting, resolved refs, guide specs) that tests assert on; (2) a thin `SchemaIR → DynamicGenerationSchema → GenerationSchema` emission step. Cover the structure table in plan.md: `type: object`+`properties`, `required`→non-optional, primitives, `array`+`items`, `enum`, nested objects, `$ref`/`$defs`→named schema + `dependencies:`. Unknown keywords fall through gracefully (no throw; guides/logging arrive in the follow-on task). Add corpus fixtures `Tests/FoundationModelsMCPTests/Fixtures/*.json` (≥8 real-world MCP schemas).

- [ ] SchemaIR (inspectable, Sendable) + parser
- [ ] IR → DynamicGenerationSchema emission (thin)
- [ ] Structure table fully mapped; $ref/$defs resolved
- [ ] Corpus fixtures; unknown keywords tolerated

## Acceptance Criteria
- [ ] Every structure row of plan.md's table is represented in the IR for the corpus
- [ ] All corpus fixtures parse and emit without throwing
- [ ] Names, optionality, nesting, and ref resolution asserted on the IR (not on opaque Apple types)

## Tests
- [ ] `Tests/FoundationModelsMCPTests/SchemaConverterStructureTests.swift`: table-driven IR assertions over the corpus; emission smoke test (GenerationSchema constructs without throwing)
- [ ] `swift test --filter SchemaConverterStructure` green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.