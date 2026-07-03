---
depends_on:
- 01KWMRYXFKKEW3QDHEFF7Z2QB4
position_column: todo
position_ordinal: '8580'
title: 'SchemaConverter: runtime GenerationGuides + fallback policy with logging'
---
## What
Extend `SchemaConverter` with constraint mapping per plan.md, expressed as **guide specs in the SchemaIR** (assertable) and emitted as runtime `GenerationGuide`s: `enum`→`anyOf`, `minimum`/`maximum`→`range`/`minimum`/`maximum` (`Decimal`; document `exclusiveMinimum`/`exclusiveMaximum` handling), `pattern`→best-effort ECMA-262 → Swift `Regex` compile (on failure: description-hint fallback), `minItems`/`maxItems`→count guides (pin nested-array behavior with a test). Unsupported constructs (`anyOf`/`oneOf` unions, `additionalProperties`, `patternProperties`, tuples, `not`, recursive `$ref`) degrade to a permissive IR node and **log what was dropped** (keyword + JSON path) — never silently misrepresent.

- [ ] Guide specs in IR: enum/range/pattern/count
- [ ] pattern best-effort with logged fallback
- [ ] Unsupported constructs → permissive IR + one log record each
- [ ] exclusive bounds + Decimal conversion documented

## Acceptance Criteria
- [ ] Corpus schemas with enum/min/max/minItems/pattern produce the expected guide specs in the IR
- [ ] Invalid regex pattern falls back without throwing and emits a log record
- [ ] Every dropped construct emits exactly one log record naming keyword and path

## Tests
- [ ] `Tests/FoundationModelsMCPTests/SchemaConverterGuideTests.swift`: IR guide-spec assertions per fixture; fallback logging via injected log handler; nested-array count pin; emission smoke test
- [ ] `swift test --filter SchemaConverterGuide` green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.