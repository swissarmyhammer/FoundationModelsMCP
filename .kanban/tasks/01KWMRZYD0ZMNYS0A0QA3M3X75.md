---
comments:
- actor: claude-code
  id: 01kwpj939w2vkfx2kj1wmkz0fn
  text: |-
    Implemented via TDD.

    ## What was built

    - `SchemaIR.guided(base:guide:)` — new case wrapping a base structural schema (`.integer`/`.number`/`.string`/`.array`) with a `SchemaIR.GuideSpec`:
      - `.numericRange(minimum: Decimal?, maximum: Decimal?)` — from `minimum`/`maximum`/`exclusiveMinimum`/`exclusiveMaximum`. Exclusive bounds nudge inward (integer: ±1; number: ±1e-9 Decimal epsilon) since `GenerationGuide`'s numeric factories are inclusive-only; when both inclusive and exclusive forms of the same bound are present, the stricter (nudged) one wins.
      - `.pattern(String)` — from `pattern`. Parse-time validates the ECMA-262 source compiles as a Swift `Regex` (`try? Regex(source)`); on failure, falls back to plain `.string` and logs `keyword: "pattern"` instead of throwing.
      - `.count(minimum: Int?, maximum: Int?)` — from `minItems`/`maxItems`, including on nested arrays (pinned by `nestedArrayCountGuideSpec`).
      - `enum` → already fully handled by the pre-existing `.enumeration` case (a named choice schema at emission); documented as the "enum → anyOf" guide-equivalent rather than re-wrapped.
    - New public `SchemaConversionLogRecord` (keyword + slash-delimited JSON path) and `SchemaConversionLogHandler` typealias, injected via a new `onDrop:` parameter on `SchemaConverter.parse(_:name:onDrop:)` (defaults to no-op — source compatible with existing call sites).
    - Unsupported constructs (`anyOf`, `oneOf`, `additionalProperties` except literal `false`, `patternProperties`, `not`, `prefixItems`, legacy array-form `items` tuples, unresolved/self-referential `$ref`) degrade the whole node to `.unknown` and log exactly one record per dropped keyword.
    - Emission: `.guided` → `DynamicGenerationSchema(type: Decimal.self, guides: [.range/.minimum/.maximum])` for numeric ranges (regardless of `.integer` vs `.number` base, per Decimal-typed `GenerationGuide`); `DynamicGenerationSchema(type: String.self, guides: [.pattern(regex)])` for string patterns; `DynamicGenerationSchema(arrayOf:minimumElements:maximumElements:)` for array counts (that initializer's own dedicated API, not a `GenerationGuide`).
    - New fixtures: `numeric_range.json`, `pattern_match.json`, `bounded_list.json`, `unsupported_constructs.json`.
    - New test file `Tests/FoundationModelsMCPTests/SchemaConverterGuideTests.swift` (14 tests).

    ## Adversarial review found and fixed two real bugs (not just the 3 originally scoped)

    1. **Crash**: nudging `exclusiveMinimum`/`exclusiveMaximum` inward could cross (`minimum > maximum`) for a legal-but-narrow/vacuous schema (e.g. `exclusiveMinimum: 5, exclusiveMaximum: 6` on an integer), and `ClosedRange`'s `minimum...maximum` traps on a crossed bound — reproduced in an isolated script before fixing. Fixed by guarding the crossed case in `applyNumericRangeGuide`, falling back to the plain base type with a logged record instead of constructing the range.
    2. **Silent drop**: a node with both a resolvable `$ref` and a sibling unsupported keyword (e.g. `anyOf`) returned `.reference(...)` immediately, silently discarding the sibling constraint (2020-12 treats `$ref` as a normal applicator, not draft-04-style replacement) and risking `GenerationSchema.SchemaError.undefinedReferences` at emission if the ref target wasn't real. Fixed by checking `unsupportedKeywordsPresent` before the `$ref` branch in `parseNode`.
    3. A second re-check surfaced the same crash *shape* in `applyCountGuide` (`minItems > maxItems`). Empirically verified `DynamicGenerationSchema(arrayOf:minimumElements:maximumElements:)` does NOT crash on crossed bounds (no `ClosedRange` involved there) — but it does silently encode a self-contradictory (unsatisfiable) count constraint. Added the same guard-and-log pattern for consistency and to avoid ever emitting an unsatisfiable schema unflagged.

    All three were fixed via TDD (failing test first, confirmed RED, then GREEN), except the numeric-range crash itself: reproducing that RED in the real test binary would have crashed the whole `swift test` process (a `fatalError`-style trap, not a catchable assertion failure), so the fix was applied first (informed by an isolated standalone-script repro) and the regression test added and verified against the already-fixed code — documented here as a deliberate, justified deviation from strict red-green for that one item.

    ## Verification
    - `swift build` — exit 0, zero warnings.
    - `swift test --filter SchemaConverterGuide` — 14/14 pass.
    - `swift test` (full suite) — 81/81 pass across 6 suites (SchemaConverterStructure's 11 pre-existing tests unaffected).

    Leaving in `doing` per /implement's contract — ready for /review.
  timestamp: 2026-07-04T12:39:58.012245+00:00
depends_on:
- 01KWMRYXFKKEW3QDHEFF7Z2QB4
position_column: doing
position_ordinal: '80'
title: 'SchemaConverter: runtime GenerationGuides + fallback policy with logging'
---
## What
Extend `SchemaConverter` with constraint mapping per plan.md, expressed as **guide specs in the SchemaIR** (assertable) and emitted as runtime `GenerationGuide`s: `enum`→`anyOf`, `minimum`/`maximum`→`range`/`minimum`/`maximum` (`Decimal`; document `exclusiveMinimum`/`exclusiveMaximum` handling), `pattern`→best-effort ECMA-262 → Swift `Regex` compile (on failure: description-hint fallback), `minItems`/`maxItems`→count guides (pin nested-array behavior with a test). Unsupported constructs (`anyOf`/`oneOf` unions, `additionalProperties`, `patternProperties`, tuples, `not`, recursive `$ref`) degrade to a permissive IR node and **log what was dropped** (keyword + JSON path) — never silently misrepresent.

- [x] Guide specs in IR: enum/range/pattern/count
- [x] pattern best-effort with logged fallback
- [x] Unsupported constructs → permissive IR + one log record each
- [x] exclusive bounds + Decimal conversion documented

## Acceptance Criteria
- [x] Corpus schemas with enum/min/max/minItems/pattern produce the expected guide specs in the IR
- [x] Invalid regex pattern falls back without throwing and emits a log record
- [x] Every dropped construct emits exactly one log record naming keyword and path

## Tests
- [x] `Tests/FoundationModelsMCPTests/SchemaConverterGuideTests.swift`: IR guide-spec assertions per fixture; fallback logging via injected log handler; nested-array count pin; emission smoke test
- [x] `swift test --filter SchemaConverterGuide` green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.