---
comments:
- actor: claude-code
  id: 01kwppd5332kcea05jsybsa730
  text: |-
    Implemented via TDD.

    - Wrote Tests/FoundationModelsMCPTests/RendererTrimTests.swift first (10 tests), confirmed RED (build failure: `budget:` param / `defaultRenderBudget` didn't exist yet).
    - Extended Sources/FoundationModelsMCP/ToolContentRenderer.swift:
      - `public static let defaultRenderBudget = 8_192` (characters, documented rationale tying to Apple's context-window guidance).
      - `render(_:outputSchema:budget:)` threads `budget` through to `.text` content, `.resource` embedded text, and `structuredContent`'s rendered JSON.
      - New `trimmed(_:budget:)` — deterministic two-pass head/tail trim: first pass sizes the head/tail split using an approximate marker, second pass renders the marker with the exact elided-character count, so the marker names precisely what's missing. Text at/under budget returned unchanged, byte-for-byte (early guard).
      - `structuredContent` schema validation still runs against the *untrimmed* value, so trimming never changes which schema issues are reported.
      - image/audio already rendered as compact `[image: mimeType]`/`[audio: mimeType]` placeholders pre-existing — confirmed via tests they stay compact and budget-independent (no base64 ever dumped).
    - Full suite: `swift build` clean (0 warnings/errors), `swift test` 101/101 passed (8 suites), `swift test --filter RendererTrim` 10/10 passed.
    - No prior comments/attempts on this task.
  timestamp: 2026-07-04T13:52:05.219620+00:00
- actor: claude-code
  id: 01kwpq3gm2rgav2g5sp5efqyd1
  text: |-
    Adversarial double-check (round 1) found a real bug in `trimmed(_:budget:)`: the two-pass marker-sizing used an *approximate* elided count (`totalCount - budget`) to reserve space for the marker before computing the head/tail split, then re-rendered the marker with the *actual* elided count. When the approximate and actual counts had different digit widths (e.g. straddling a 9999→10000 boundary), the final output could silently exceed `budget` by a few characters — and the original tests had too much slack (`<= budget + 128/256`) to catch it.

    Fixed by reserving marker space using the *worst-case* digit width instead: `elisionMarker(elidedCount: totalCount)`. Since the actual elided count can never exceed `totalCount` and decimal digit count is monotonic non-decreasing in value, the worst-case marker is provably always >= the actual marker's length, so `head + marker + tail` never exceeds `budget` (except when `budget` itself is smaller than the marker's own minimum length — an inherent, now-documented edge case: a marker can't state a count in fewer characters than the statement requires).

    Added (TDD, watched fail against the old algorithm before applying the fix):
    - A digit-boundary regression test sweeping budgets 19_900...19_999 against a 20_000-char text (this reproduced the exact overshoot).
    - A multi-byte Unicode test (emoji + CJK) confirming grapheme-safe head/tail slicing.
    - A shared `assertBudgetSafeTrim` helper doing self-consistency checks (marker's claimed elided count + kept text == totalCount) plus a hard `rendered.count <= budget` (no slack).
    - A one-line doc note that `.resourceLink`'s descriptor, like image/audio's placeholder, is declared metadata and intentionally out of budget scope.

    Adversarial double-check (round 2) verdict: PASS — independently re-derived the budget-safety proof, reconstructed the old algorithm to confirm the regression test is a real catch (not coincidental), and confirmed doc-comments/coverage remained intact.

    Final verification: `swift build` clean (0 warnings/errors), `swift test --filter RendererTrim` 12/12 green, full `swift test` 103/103 green across 8 suites. Task left in `doing` for /review per process (not moved to review by implement).
  timestamp: 2026-07-04T14:04:17.922951+00:00
depends_on:
- 01KWMRZ90WFKXY5GZK58M75STZ
position_column: doing
position_ordinal: '80'
title: ToolContentRenderer size/trimming strategy
---
## What
Extend `ToolContentRenderer` with a bounded-output strategy per plan.md M5 (tool results are the context-window cost): a configurable budget (bytes/characters) with a documented default; oversized text content trimmed deterministically (head + tail with an explicit elision marker stating how much was elided); image/audio content represented compactly (metadata, never raw base64 dumped at full size beyond budget); `structuredContent` subject to the same budget.

- [ ] Configurable render budget + documented default
- [ ] Deterministic head/tail trim with elision annotation
- [ ] Compact representation for binary content
- [ ] Budget applies to structuredContent too

## Acceptance Criteria
- [ ] A 1MB text result renders within budget with an elision marker naming the elided size
- [ ] Rendering is deterministic (same input + budget → identical output)
- [ ] Under-budget results are untouched byte-for-byte

## Tests
- [ ] `Tests/FoundationModelsMCPTests/RendererTrimTests.swift`: oversized text/image/structured cases, determinism, untouched small results
- [ ] `swift test --filter RendererTrim` green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.