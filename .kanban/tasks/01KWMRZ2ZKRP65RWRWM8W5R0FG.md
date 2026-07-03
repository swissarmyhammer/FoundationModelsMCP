---
comments:
- actor: claude-code
  id: 01kwn2xc51x6kjtdhqbpw40wbn
  text: |-
    Implemented via TDD. Created Sources/FoundationModelsMCP/GeneratedContentCodec.swift and Tests/FoundationModelsMCPTests/CodecTests.swift.

    Key discovery (empirically verified against the real macOS 27 beta FoundationModels SDK, not just the .swiftinterface): `GeneratedContent.Kind` has exactly one numeric case, `.number(Double)` — no separate Int case — and `GeneratedContent(json: "5.0").jsonString` normalizes to `"5"`, confirming the SDK genuinely cannot distinguish "generated as integer 5" from "generated as double 5.0" once wrapped. The codec recovers integer-ness via `Int(exactly:)` on the Double (zero fractional part -> `.int`), which is the only signal the SDK actually preserves. Round-trip tests deliberately use whole numbers for the int path and numbers with a genuine fractional part for the double path (never a whole-number double like 5.0), since that ambiguity is a real SDK limitation, not a codec bug.

    Also discovered dictionary key order is NOT preserved through GeneratedContent's Kind/jsonString (orderedKeys does not match original JSON text order), so `.object`/`.structure` conversion doesn't attempt to preserve key order — harmless since `Value.object` is an unordered dictionary.

    Adversarial double-check (via /really-done) caught a real bug on first pass: `Value.int` beyond ±2^53 (Double's exact-integer-representation limit) silently round-tripped to a *different, wrong* Int instead of erroring (e.g. 9007199254740993 came back as 9007199254740992). Fixed by adding `GeneratedContentCodecError.integerPrecisionLoss(Int)`, thrown when `Int(exactly: Double(int)) != int`. Also added `Sendable` conformance to the error type per double-check finding. Re-ran double-check once more (bounded per really-done's "at most once" rule) — found one minor test-coverage gap (negative-boundary case untested), fixed it. Final state: PASS.

    Verification: `swift build` exit 0, `swift test` — 27/27 tests pass across 3 suites (Smoke, Codec, SchemaConverterStructure), zero failures, zero warnings. `swift test --filter Codec` — all 18 Codec tests green.

    Leaving in `doing` for /review per the implement skill contract.
  timestamp: 2026-07-03T22:52:10.785882+00:00
depends_on:
- 01KWMRYGMXC08VX2W7P2DK2X0W
position_column: done
position_ordinal: '8280'
title: 'GeneratedContentCodec: GeneratedContent ⇄ MCP.Value round-trip'
---
## What\nCreate `Sources/FoundationModelsMCP/GeneratedContentCodec.swift`: convert FoundationModels `GeneratedContent` → `[String: MCP.Value]` (outbound tool-call arguments) and `MCP.Value` → `GeneratedContent` (for round-tripping). Handle nested objects, arrays, strings (incl. unicode/escaping), integer vs. double distinction, booleans, and null.\n\n- [x] GeneratedContent → [String: MCP.Value]\n- [x] MCP.Value → GeneratedContent\n- [x] Numeric fidelity (int vs double), null, unicode strings\n\n## Acceptance Criteria\n- [x] Round-trip of any supported value tree is lossless (value-equal)\n- [x] Integers survive as integers (no silent double-ification) where the SDK distinguishes them\n\n## Tests\n- [x] `Tests/FoundationModelsMCPTests/CodecTests.swift`: round-trip property-style tests over generated value trees (nested objects/arrays, numbers, null, unicode)\n- [x] `swift test --filter Codec` green\n\n## Workflow\n- Use `/tdd` — write failing tests first, then implement to make them pass.