---
comments:
- actor: claude-code
  id: 01kwregchpqyjfs546rhq3qs4e
  text: 'Implementation complete, all fresh verification commands green: swift build (0 warnings), swift build --target for all 7 Examples/ targets, swift test (222/222 across 23 suites), and swift package generate-documentation --target FoundationModelsMCP --warnings-as-errors (exit 0, 0 warnings). Kicked off an adversarial double-check agent (per really-done) to independently verify the doc-comment-only diffs, the README/EchoTool verbatim match, the drift-detection test''s red/green behavior, and DocC archive contents. Awaiting its verdict before final hand-off; task stays in doing per /implement.'
  timestamp: 2026-07-05T06:12:31.414017+00:00
- actor: claude-code
  id: 01kwrfcagpdvqqr76d0pjn1rxw
  text: |-
    Double-check round 1 verdict: REVISE (high severity). Finding: `swift package generate-documentation --warnings-as-errors` does NOT catch missing documentation for public symbols — DocC has no "undocumented symbol" warning class at all, only genuine diagnostics (broken links, malformed directives). Verified independently: stripping ToolContentRenderer's doc comment and re-running still exits 0 with zero warnings. The ci.yml comment's claim that it did was false.

    Fix applied:
    - Ran `--experimental-documentation-coverage --coverage-summary-level detailed` (the only DocC facility that actually reports missing docs) and found every genuinely-fixable gap: 3 of our own `extension` declarations (`extension Client: MCPToolCalling` in MCPToolCalling.swift, `extension Elicitation.RequestSchema` in ElicitationCoordinator.swift, `extension LanguageModelSession` in MCPToolProvider.swift) were missing a doc comment on the `extension` line itself (a doc comment on the first member inside doesn't count as the extension's own abstract). Added doc comments to all three; Types coverage went 84%→92% as a direct result.
    - Everything else the coverage report flags (47 rows) is compiler/framework-synthesized with no attachment point in our source: Equatable's `!=`, Actor's 4 default isolation-check methods, Foundation's `Error.localizedDescription` bridging, FoundationModels.Tool's synthesized `SessionProperty` type alias, DocC's own "<Protocol> Implementations" CollectionGroup pages, "Extended Module" container pages for MCP/FoundationModels, and the one-level-up "Elicitation" container above the `RequestSchema` extension we do document. None of these are declared anywhere in this package's own source — verified by grep (zero matches for "SessionProperty" anywhere in Sources/).
    - Added `Scripts/check-docc-coverage.py`: parses the coverage report, allowlists exactly the above (by kind, or by kind+reference-path-suffix for specific synthesized members), and fails on anything else undocumented. Verified both directions: passes clean on the current tree (202 symbols checked), and correctly fails when I temporarily stripped a real doc comment (caught it), then passed again after restoring.
    - Wired as a new "DocC documentation coverage" CI step (separate from the existing "DocC" `--warnings-as-errors` step, whose own comment I corrected to stop overclaiming). This is now the actual enforcement mechanism for the "zero missing-documentation warnings for public symbols" acceptance criterion.

    Fresh verification after the fix: swift build (0 warnings), swift test (222/222), swift package generate-documentation --warnings-as-errors (0 warnings), and the new coverage-gate script (OK, 202 symbols, 0 outside allowlist) — all green.
  timestamp: 2026-07-05T06:27:46.838752+00:00
- actor: claude-code
  id: 01kwrfwhvzv2w7cnrpc4202aaa
  text: |-
    Double-check round 2 verdict: PASS. Confirmed the coverage-gate script and CI wiring are honest and functional: allowlist justifications spot-checked correct (SessionProperty has zero source declarations; MCPServer is a genuine `actor`), the crux regression test passed both directions (stripping a doc comment on MCPServer → caught; restored → passes), extension doc comments verified correctly placed, CI YAML verified syntactically correct, and full build/test/examples all green.

    Caught during my own final re-verification after round 2: the reviewing agent's revert step for its own experiment used `git checkout -- Sources/FoundationModelsMCP/MCPServer.swift`, which — since that file already had my uncommitted fixes from earlier in this task, not just the reviewer's temporary strip — reset the ENTIRE file back to its pre-task HEAD state, silently discarding all ~57 broken-doc-link fixes I'd made to it earlier (init signature, call(toolNamed:arguments:timeout:), ProgressToken, emitCatalogSnapshot, coalesceAndRelist, performConnectAttempt, ManualClock, activeBackoffPolicy, lastTransport, handleProgressNotification, defaultCallTimeout, discoveredTools, catalogEpoch, relistOnce, clock, plan.md, and the Elicitation.RequestSchema.requiresURLModeRouting reference). Caught this because `swift package generate-documentation --warnings-as-errors` failed again in my post-round-2 verification pass and `git status`/`git diff` showed MCPServer.swift as unexpectedly clean (no diff from HEAD).

    Reconstructed all fixes from the same replacement list used originally (verified identical occurrence counts to the first pass — a good sign the reconstruction is exact, not a re-guess). Re-verified fresh, all green: swift build (0 warnings), swift build --target for all 7 Examples/, swift test (222/222, 23 suites), swift package generate-documentation --warnings-as-errors (0 warnings, exit 0), and check-docc-coverage.py (OK, 202 symbols, exit 0).

    Lesson for future agents/reviewers touching this tree: `git checkout -- <file>` is destructive to ALL uncommitted changes in that file, not just changes made in the current session — when reverting a scratch experiment on a file with pre-existing uncommitted work, diff/stash the specific hunk instead, or re-apply only the intended change manually.

    Task complete and green. Leaving in `doing` per /implement process for /review to pick up.
  timestamp: 2026-07-05T06:36:38.655710+00:00
depends_on:
- 01KWMS3F3P3HHZ56C1FK7S44DQ
- 01KWMS37EXGG7KRM8YN8ABXV7R
position_column: doing
position_ordinal: '80'
title: DocC documentation + README
---
## What
Author the public documentation: a DocC catalog for the `FoundationModelsMCP` module covering every public symbol (MCPServer, MCPTool, MCPToolProvider, SchemaConverter behavior/fallbacks, ToolContentRenderer contract, ElicitationCoordinator, the frozen catalog surface) plus articles for the consumer contract (Multitool) and the enforcement model (declare vs. enforce). Write `README.md` with a quick-start whose code is the EchoTool example (kept compiling by referencing the example target), the dependency statement (swift-sdk + FoundationModels only), and pointers to Multitool/Router for search.

- [x] DocC catalog; no undocumented public symbols
- [x] Articles: catalog consumer contract, enforcement model
- [x] README with EchoTool quick-start + scope/dependency statement

## Acceptance Criteria
- [x] DocC build succeeds in CI with zero missing-documentation warnings for public symbols
- [x] README quick-start code is the EchoTool source (or verbatim excerpt) so it cannot rot silently

## Tests
- [x] CI step: `swift package generate-documentation` (or xcodebuild docbuild) succeeds
- [x] CI step asserts README's swift snippet matches the EchoTool example source (simple diff check script)

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

## Implementation notes (2026-07-05)

- Added `swift-docc-plugin` (1.5.0) as a package dependency. It is a
  documentation-build-only tool dependency — never imported by any target,
  never linked into a consumer of the library — so it does not change the
  "swift-sdk + FoundationModels only" runtime dependency statement.
- DocC catalog: `Sources/FoundationModelsMCP/FoundationModelsMCP.docc/` —
  top-level `FoundationModelsMCP.md` (curated Topics over every public
  symbol) plus three articles: `GettingStarted.md`, `EnforcementModel.md`
  (the declare-vs-enforce model), and `CatalogConsumerContract.md`
  (converted from the old `docs/catalog-consumer-contract.md`, which is now
  a short pointer stub rather than a duplicate).
- Fixed ~90 pre-existing broken `` ``symbol`` `` doc-comment cross-references
  across MCPServer.swift, MCPTool.swift, MCPElicitationTool.swift,
  ElicitationCoordinator.swift, MCPToolProvider.swift, SchemaConverter.swift,
  and ToolContentRenderer.swift — stale signatures (e.g. `init(client:name:)`
  → the real 6-parameter initializer) were corrected to real resolvable
  double-backtick links; references to private/internal members or external
  (MCP/FoundationModels module) types were converted to plain single-backtick
  code font, since DocC's single-target symbol graph can't/shouldn't resolve
  those as links.
- Package.swift gotcha found and documented in-line: the `.docc` catalog must
  be declared via `resources: [.copy("FoundationModelsMCP.docc")]`, not
  `exclude:` — `exclude` silences the "unhandled file" SwiftPM warning but
  also hides the catalog from swift-docc-plugin's own discovery, silently
  dropping all three articles from the generated archive. Confirmed both ways
  before settling on `.copy`.
- **Coverage-gate correction (found by adversarial double-check, round 1):**
  `swift package generate-documentation --warnings-as-errors` does **not**
  catch missing documentation on a public symbol — DocC has no
  "undocumented symbol" warning class at all, only genuine diagnostics
  (broken links, malformed directives). Verified directly. The actual
  enforcement for "zero missing-documentation warnings for public symbols"
  is `Scripts/check-docc-coverage.py`, run in CI against
  `--experimental-documentation-coverage --coverage-summary-level detailed`
  output (the only DocC facility that reports missing docs, though its own
  exit code ignores coverage). The script allowlists exactly the
  kinds/members DocC synthesizes with no source location to attach a `///`
  comment to (protocol-conformance "Implementations" pages, extended-external-
  module containers, prose articles, Equatable's `!=`, Actor's 4 isolation-
  check defaults, `Error.localizedDescription`, `Tool`'s synthesized
  `SessionProperty`) and fails on anything else — verified to genuinely catch
  a stripped doc comment as a regression. Also added doc comments to 3 of our
  own `extension` declarations (on `MCP.Client`, `Elicitation.RequestSchema`,
  `LanguageModelSession`) that were missing an abstract on the `extension`
  line itself.
- `README.md` quick-start embeds `Examples/EchoTool/EchoTool.swift` verbatim
  between `<!-- ECHOTOOL-SNIPPET:START/END -->` HTML-comment markers.
  `Tests/FoundationModelsMCPTests/ReadmeQuickStartTests.swift` extracts that
  span and asserts it's character-for-character identical to the source
  file. Verified as a genuine red→green cycle, including drift-detection.
- `docs/swift-sdk-notes.md`'s "No other external dependencies" section was
  already stale before this task; corrected and noted swift-docc-plugin's
  build-tool-only status.

All verification commands green (re-verified after reconstructing a file
that an adversarial reviewer's own `git checkout --` cleanup accidentally
reverted — see comments): `swift build` (0 warnings), `swift build --target
<Name>` for all 7 Examples, `swift test` (222/222 tests, 23 suites),
`swift package generate-documentation --target FoundationModelsMCP
--warnings-as-errors` (exit 0, 0 warnings), and
`python3 Scripts/check-docc-coverage.py` against the coverage report (OK,
202 symbols, 0 outside the allowlist).