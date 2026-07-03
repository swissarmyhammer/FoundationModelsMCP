---
comments:
- actor: claude-code
  id: 01kwn48e98j6s15y6pmey25ayk
  text: |-
    Implemented via TDD.

    Created:
    - Sources/FoundationModelsMCP/ToolContentRenderer.swift
    - Tests/FoundationModelsMCPTests/RendererTests.swift (23 tests)

    Design decision: the renderer's output type is plain `String`. Confirmed via the FoundationModels.framework swiftinterface (macOS 27 SDK) that `Tool.Output` must conform to `PromptRepresentable`, and `String` already conforms — no bespoke Output type needed. `MCPTool` (later task) will use `render(...)` directly as its `call(arguments:)` return value.

    render(_:outputSchema:) takes MCP's own `CallTool.Result` (content/structuredContent/isError already bundled there) plus the tool's outputSchema. Each Tool.Content case renders deterministically (.text verbatim; .image/.audio as "[image: mime]"/"[audio: mime]" placeholders, never the base64 payload; .resource renders embedded text or a placeholder for blobs; .resourceLink renders a "[resource link: ...]" descriptor built only from its own fields, never dereferenced). isError == true prepends an "Error:" paragraph without ever hiding content. structuredContent is rendered as sorted-key JSON and validated against outputSchema via the pinned shallow subset (top-level type, required presence, per-property primitive type, per-property enum); failures render as a "Note:" list alongside the content, never suppressing it. Out-of-subset keywords (additionalProperties, format, nested properties/required inside a property schema, etc.) are silently ignored.

    Went through one round of adversarial double-check (via really-done). First pass returned REVISE with 4 findings, all fixed:
    1. matchesType("string", ...) rejected .data while jsonType(of:) reported .data as "string" -- self-contradictory note. Fixed matchesType to accept .data for "string".
    2. No failing-validation test paired the note with non-empty content -- added validationFailureNeverHidesAccompanyingContent.
    3. Style drift: new files used "--" where the rest of the module uses em-dash "—". Fixed throughout.
    4. No test proved a property's own nested properties/required (one level down) is out-of-subset -- added nestedPropertiesAndRequiredKeywordsAreIgnored.
    Second double-check pass: PASS.

    Verification: `swift build` clean (no warnings/errors), `swift test` 50/50 green (4 suites), `swift test --filter Renderer` 23/23 green.

    Left in `doing` per /implement process -- not moved to review.
  timestamp: 2026-07-03T23:15:41.992729+00:00
depends_on:
- 01KWMRYGMXC08VX2W7P2DK2X0W
position_column: doing
position_ordinal: '80'
title: 'ToolContentRenderer: content types, isError, structuredContent + outputSchema validation'
---
## What
Create `Sources/FoundationModelsMCP/ToolContentRenderer.swift`: convert a `callTool` result — `[MCP.Tool.Content]` (`.text`, `.image`, `.audio`, `.resource`, `.resourceLink`), `isError: Bool?` (nil = success), `structuredContent: MCP.Value?` — into the adapter's `Output` for the model. `structuredContent` is surfaced when present and checked against the tool's declared `outputSchema` using a **pinned shallow-validation subset** (this is NOT a full JSON Schema engine): top-level `type` match, `required` property presence, per-property primitive `type` match, and `enum` membership — documented as the supported subset; deeper keywords are not validated. A validation failure is rendered to the model as a note, never hidden. `.resourceLink` renders as a link **without dereferencing**.

- [x] All five content cases rendered deterministically
- [x] isError mapping (nil = success)
- [x] structuredContent surfaced + shallow-subset validation (type/required/primitive-type/enum) with failure-as-note
- [x] resourceLink rendered as link, never fetched

## Acceptance Criteria
- [x] Each content case produces deterministic, documented output
- [x] Error results clearly marked in rendered output
- [x] The validation subset is documented in doc comments and failures appear as notes alongside content; keywords outside the subset are ignored without error

## Tests
- [x] `Tests/FoundationModelsMCPTests/RendererTests.swift`: per-content-case tests; error case; structuredContent passing/failing each subset rule; an out-of-subset keyword ignored; resourceLink not dereferenced
- [x] `swift test --filter Renderer` green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

## Implementation notes
`ToolContentRenderer.render(_:outputSchema:)` returns a plain `String` (confirmed via the FoundationModels.framework swiftinterface that `Tool.Output` only requires `PromptRepresentable`, which `String` already satisfies — no bespoke Output type needed). Takes MCP's own `CallTool.Result` directly. 23 tests in RendererTests.swift; went through one round of adversarial double-check (4 findings, all fixed) before a clean PASS. See task comments for full detail.