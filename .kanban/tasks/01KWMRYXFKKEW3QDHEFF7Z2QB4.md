---
comments:
- actor: claude-code
  id: 01kwmvsm7z7e2tt0bhcf0ymcc4
  text: |-
    Implemented via TDD.

    Created:
    - Sources/FoundationModelsMCP/SchemaConverter.swift — SchemaIR (inspectable indirect enum: object/string/integer/number/boolean/array/enumeration/reference/unknown), SchemaConversion (root + $defs table), and SchemaConverter.parse(_:name:) / SchemaConverter.emit(_:) (thin SchemaIR → DynamicGenerationSchema → GenerationSchema).
    - Tests/FoundationModelsMCPTests/Fixtures/*.json — 9 corpus fixtures (read_file, search_code, list_directory, set_log_level, create_user, create_ticket, weather_query, git_commit, advanced_filter) covering every plan.md structure-table row (object+properties+required, all 4 primitives, array+items, enum, nested objects, $ref/$defs) plus a deliberate anyOf case to exercise the graceful non-throwing .unknown fallback.
    - Tests/FoundationModelsMCPTests/SchemaConverterStructureTests.swift — table-driven IR assertions per row + corpus-wide parse and emission-smoke tests.
    - Package.swift — added `resources: [.copy("Fixtures")]` to the test target (cosmetic; silences an "unhandled files" build warning — fixtures are actually loaded via #filePath, not Bundle.module).

    Process: watched RED first (build failed with "cannot find 'SchemaConverter' in scope"), then implemented to GREEN.

    Ran the really-done adversarial double-check (Task tool, double-check agent). It independently re-verified build/tests, checked the real FoundationModels.framework linkage (not a stub — this box is macOS 27 with Xcode-beta), traced $ref/$defs dependency wiring and undefined-ref behavior by hand, and confirmed corpus coverage against plan.md's table. Verdict: REVISE with 2 findings, both fixed (RED→GREEN again for the first):
    1. $ref/$defs resolution only recognized "#/$defs/" — broadened parseDefinitions/definitionName(fromRef:) to also recognize the legacy "#/definitions/" container (common in schemas ported from draft-07 generators). Added a new failing-first test `legacyDefinitionsRefPrefix` (watched it fail, then implemented).
    2. No test asserted `description` propagation (a real plan.md table row, already correctly implemented but uncovered) — added description assertions to 4 existing tests (read_file's path, set_log_level's level+enum node, create_user's nested address object, create_ticket's Priority definition). All passed immediately since the implementation was already correct.

    Final verification (fresh, this session): `swift build` — exit 0, zero warnings. `swift test --filter SchemaConverterStructure` — 10/10 pass. `swift test` (full suite) — 11/11 pass across Smoke + SchemaConverterStructure.

    Leaving in `doing` per /implement process — ready for /review.
  timestamp: 2026-07-03T20:47:47.967166+00:00
depends_on:
- 01KWMRYGMXC08VX2W7P2DK2X0W
position_column: doing
position_ordinal: '80'
title: 'SchemaConverter: JSON Schema structure → DynamicGenerationSchema (+ corpus)'
---
## What\nCreate `Sources/FoundationModelsMCP/SchemaConverter.swift` converting an MCP `inputSchema` (`MCP.Value`, JSON Schema 2020-12) to `GenerationSchema`. **Because `DynamicGenerationSchema`/`GenerationSchema` are opaque (no public introspection), convert in two stages**: (1) parse into an **inspectable internal IR** (`SchemaIR`: property names, types, optionality, nesting, resolved refs, guide specs) that tests assert on; (2) a thin `SchemaIR → DynamicGenerationSchema → GenerationSchema` emission step. Cover the structure table in plan.md: `type: object`+`properties`, `required`→non-optional, primitives, `array`+`items`, `enum`, nested objects, `$ref`/`$defs`→named schema + `dependencies:`. Unknown keywords fall through gracefully (no throw; guides/logging arrive in the follow-on task). Add corpus fixtures `Tests/FoundationModelsMCPTests/Fixtures/*.json` (≥8 real-world MCP schemas).\n\n- [x] SchemaIR (inspectable, Sendable) + parser\n- [x] IR → DynamicGenerationSchema emission (thin)\n- [x] Structure table fully mapped; $ref/$defs resolved\n- [x] Corpus fixtures; unknown keywords tolerated\n\n## Acceptance Criteria\n- [x] Every structure row of plan.md's table is represented in the IR for the corpus\n- [x] All corpus fixtures parse and emit without throwing\n- [x] Names, optionality, nesting, and ref resolution asserted on the IR (not on opaque Apple types)\n\n## Tests\n- [x] `Tests/FoundationModelsMCPTests/SchemaConverterStructureTests.swift`: table-driven IR assertions over the corpus; emission smoke test (GenerationSchema constructs without throwing)\n- [x] `swift test --filter SchemaConverterStructure` green\n\n## Workflow\n- Use `/tdd` — write failing tests first, then implement to make them pass.