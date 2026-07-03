---
depends_on:
- 01KWMRYGMXC08VX2W7P2DK2X0W
position_column: todo
position_ordinal: '8380'
title: 'ToolContentRenderer: content types, isError, structuredContent + outputSchema validation'
---
## What
Create `Sources/FoundationModelsMCP/ToolContentRenderer.swift`: convert a `callTool` result — `[MCP.Tool.Content]` (`.text`, `.image`, `.audio`, `.resource`, `.resourceLink`), `isError: Bool?` (nil = success), `structuredContent: MCP.Value?` — into the adapter's `Output` for the model. `structuredContent` is surfaced when present and checked against the tool's declared `outputSchema` using a **pinned shallow-validation subset** (this is NOT a full JSON Schema engine): top-level `type` match, `required` property presence, per-property primitive `type` match, and `enum` membership — documented as the supported subset; deeper keywords are not validated. A validation failure is rendered to the model as a note, never hidden. `.resourceLink` renders as a link **without dereferencing**.

- [ ] All five content cases rendered deterministically
- [ ] isError mapping (nil = success)
- [ ] structuredContent surfaced + shallow-subset validation (type/required/primitive-type/enum) with failure-as-note
- [ ] resourceLink rendered as link, never fetched

## Acceptance Criteria
- [ ] Each content case produces deterministic, documented output
- [ ] Error results clearly marked in rendered output
- [ ] The validation subset is documented in doc comments and failures appear as notes alongside content; keywords outside the subset are ignored without error

## Tests
- [ ] `Tests/FoundationModelsMCPTests/RendererTests.swift`: per-content-case tests; error case; structuredContent passing/failing each subset rule; an out-of-subset keyword ignored; resourceLink not dereferenced
- [ ] `swift test --filter Renderer` green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.