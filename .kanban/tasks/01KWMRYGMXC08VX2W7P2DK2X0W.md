---
comments:
- actor: claude-code
  id: 01kwmth5t6htp9znrmk7c1g3ez
  text: |-
    M0 scaffold complete, TDD'd from scratch.

    Created:
    - Package.swift — library target `FoundationModelsMCP`, test target `FoundationModelsMCPTests`, exactly one external dependency (`.product(name: "MCP", package: "swift-sdk")` pinned `from: "0.12.1"`, confirmed latest stable tag via `git ls-remote --tags`), platforms `.macOS("27")` / `.iOS("27")` only, library target links system `FoundationModels` via `linkerSettings: [.linkedFramework("FoundationModels")]`.
    - Sources/FoundationModelsMCP/FoundationModelsMCP.swift — minimal placeholder that `import FoundationModels` and exposes `targetedProtocolRevision`.
    - Tests/FoundationModelsMCPTests/SmokeTests.swift — imports both `FoundationModelsMCP` and `MCP`, asserts a trivial truth.
    - .github/workflows/ci.yml — runs `swift build` + `swift test`; uses `runs-on: [self-hosted, macOS]` with a comment explaining hosted macos-* runners likely lack the OS 27 SDK yet.
    - docs/swift-sdk-notes.md — records the pinned swift-sdk's supported protocol revision (2025-11-25, confirmed against `Sources/MCP/Base/Versioning.swift` in the 0.12.1 tag) and its elicitation surface (`client.withElicitationHandler`, confirmed against `Sources/MCP/Client/Client.swift` and `Elicitation.swift`).

    TDD: wrote SmokeTests.swift first (no Package.swift existed), ran `swift test` → RED (`error: Could not find Package.swift...`). Then created Package.swift + library source → GREEN.

    Verification (fresh, this session):
    - `swift build` → `Build complete!`, exit 0
    - `swift test` → `Executed 1 test, 0 failures`, exit 0
    - Confirmed no `@available` usage (`grep -rn "@available" Sources Tests` → no matches)
    - Confirmed exactly one `.package(url:)` entry in Package.swift; Package.resolved's other entries are swift-sdk's own transitive deps (swift-nio, swift-log, swift-collections, swift-atomics, swift-system, eventsource), not ours
    - double-check agent (adversarial review) verdict: PASS — independently re-cloned swift-sdk 0.12.1 and confirmed every claim in docs/swift-sdk-notes.md byte-for-byte against source; confirmed TDD red-green sequencing via file birth-times; confirmed CI workflow is a defensible scaffold.

    Leaving task in `doing` for review per /implement process (not moving to review myself).
  timestamp: 2026-07-03T20:25:42.470209+00:00
position_column: done
position_ordinal: '80'
title: 'M0: Scaffold SwiftPM package — swift-sdk + FoundationModels only, CI'
---
## What\nCreate the SwiftPM package skeleton: `Package.swift`, library target `FoundationModelsMCP` (`Sources/FoundationModelsMCP/`), test target (`Tests/FoundationModelsMCPTests/`). **Exactly one external dependency**: `.product(name: \"MCP\", package: \"swift-sdk\")` pinned to the latest stable tag, plus linking the system `FoundationModels` framework — no MLX, no Router (plan.md Decisions → Enforcement). Platform floor macOS 27 / iOS 27 only, no `@available` branching. Add a GitHub Actions CI workflow (macOS, Xcode with the OS 27 SDK — note in the workflow that a self-hosted runner may be required if hosted runners lack the OS 27 SDK) running `swift build` and `swift test`. Verify and record the pinned swift-sdk's supported MCP protocol revision (target: **2025-11-25**) and its elicitation surface (`client.withElicitationHandler`) in `docs/swift-sdk-notes.md`.\n\n- [x] Package.swift with single external dependency + platforms\n- [x] Library + test targets compile\n- [x] CI workflow file present (build + test)\n- [x] docs/swift-sdk-notes.md records SDK protocol revision + elicitation surface\n\n## Acceptance Criteria\n- [x] `swift build` and `swift test` pass **locally**\n- [x] The CI workflow file exists and its steps mirror the local commands (CI greenness itself is verified at merge, not by this task)\n- [x] `Package.swift` declares only swift-sdk as an external dependency\n- [x] `docs/swift-sdk-notes.md` exists and states the SDK's protocol revision and elicitation API\n\n## Tests\n- [x] `Tests/FoundationModelsMCPTests/SmokeTests.swift`: imports `FoundationModelsMCP` and `MCP`, asserts a trivial truth — proves linkage\n- [x] `swift test` green locally\n\n## Workflow\n- Use `/tdd` — write failing tests first, then implement to make them pass.