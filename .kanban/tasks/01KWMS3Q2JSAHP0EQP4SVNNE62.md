---
comments:
- actor: claude-code
  id: 01kwr0xrf88ghqy0afk6ywes5g
  text: |-
    Implemented Tests/FoundationModelsMCPTests/E2ETests.swift per spec.

    Design:
    - Gated by two independent Swift Testing `.enabled(if:)` traits (never `#if`, never an empty body): (1) `FOUNDATIONMODELSMCP_E2E == "1"`, (2) `SystemLanguageModel.default.isAvailable`, but the second trait's condition short-circuits to `true` whenever the first flag is unset (`!isE2EFlagSet || SystemLanguageModel.default.isAvailable`) so the default `swift test` run never touches `SystemLanguageModel` at all — only the cheap env-var read.
    - Spawns the existing `MCPTestServerCLI` executable via `Foundation.Process` + two `Pipe`s, wraps the pipes' file descriptors in a real `MCP.StdioTransport` (input = child's stdout pipe read end, output = child's stdin pipe write end), connects a real `MCPServer`/`MCP.Client` over it (no mock, no `InMemoryTransport`).
    - Builds `LanguageModelSession(mcp: server, instructions: ...)` on the system model, sends a prompt with a random UUID marker asking the model to call the echo tool with that marker.
    - Asserts three things: the final response text contains the marker; `session.transcript` contains a `.toolCalls` entry naming "echo" (proof the tool was actually invoked, not just text-matched); `session.transcript` contains a `.toolOutput` entry from "echo" whose text segment contains the marker (proof the actual tool result reached the session, not just the model's paraphrase).
    - Locating the sibling `MCPTestServerCLI` binary: parses this process's own `--test-bundle-path` argument (how `swift test` invokes the swift-testing runner on Darwin) to find the Products/Debug directory MCPTestServerCLI is built into alongside the test bundle; falls back to `CommandLine.arguments[0]`'s directory otherwise. Verified empirically that `Bundle.allBundles` does NOT surface the xctest bundle in this invocation mode, so that common trick doesn't work here — went with argument-parsing instead.

    Verification (all fresh, this session):
    - `swift build` — clean, 0 warnings/errors.
    - `swift build --build-tests` — clean, 0 warnings/errors.
    - `swift test` (default, no env var) — 178/178 tests pass; E2E suite shows the test explicitly SKIPPED with message "Set FOUNDATIONMODELSMCP_E2E=1 to run this gated end-to-end test...".
    - `FOUNDATIONMODELSMCP_E2E=1 swift test --filter E2E` — ran TWICE on this actual dev machine (which has a working on-device SystemLanguageModel/OS 27): the test genuinely PASSED both times (not skipped) — real subprocess spawned, real tool call happened, both transcript assertions passed, response contained the marker. ~4.5s per run.
    - Could not directly exercise the "flag set but model unavailable" skip path on this machine since the model IS available here, but the short-circuit logic was reasoned through carefully and is structurally sound (same trait mechanism Swift Testing uses either way).

    Adversarial double-check agent dispatched for a second pair of eyes on gating correctness, pipe/transport wiring, CLI-path-discovery robustness, and transcript-assertion soundness.
  timestamp: 2026-07-05T02:15:09.544238+00:00
- actor: claude-code
  id: 01kwr1e5tp6xrvxxsnknmnf315
  text: |-
    Adversarial double-check verdict: REVISE, with 2 significant findings (both applied) and 2 minor/informational (accepted, logged below):

    1. FIXED — missing explicit `await server.disconnect()` before subprocess teardown, inconsistent with every other MCPServer-constructing test in this package (MCPServerDiscoveryTests, LiveCatalogTests). Added `defer { await server.disconnect() }` right after `server.connect(transport:)`. Confirmed Swift supports `await` directly inside a `defer` body in an `async` function (verified with a standalone repro before relying on it in the real test) — no unstructured `Task {}` wrapper needed, and defer LIFO ordering means this disconnect now runs before the process-teardown defer, exactly the right order.
    2. FIXED — `process.terminate()` alone doesn't reap the child (zombie until the test binary exits). Changed to `defer { process.terminate(); process.waitUntilExit() }`.
    3. Accepted as-is (informational) — no `.timeLimit()`/timeout wrapper around `session.respond(to:)`. Matches this suite's existing convention (no test anywhere uses `.timeLimit()`), so not a deviation; noted as a residual risk given this is the one test hitting real non-deterministic infrastructure, but not fixing since it would be inventing a new pattern not otherwise used in this codebase.
    4. Accepted as-is (informational) — `productsDirectoryURL()`'s `.xctest`-bundle-layout traversal (4x `deletingLastPathComponent()`) is coupled to the current Darwin swiftpm-testing-helper argument format. Fails loudly via `SetupError.testServerCLINotFound` rather than silently if that ever changes; empirically verified correct on this toolchain across multiple real runs. Left as-is per the double-check's own assessment ("not a blocking issue").

    Everything else the double-check checked came back clean: gating short-circuit logic, pipe/fd direction, tool-name/initializer usage, transcript-assertion soundness, no force-unwraps/try!/excess nesting/duplicated literals.

    Re-verified after applying fixes 1–2 (fresh, this session):
    - `swift build --build-tests` — clean, 0 warnings/errors.
    - `swift test` (default) — 178/178 pass, E2E still cleanly skipped.
    - `FOUNDATIONMODELSMCP_E2E=1 swift test --filter E2E` — passed again for real (4.577s), no lingering `MCPTestServerCLI` process afterward (checked via `ps aux`).

    Leaving task in `doing` for `/review` per the implement skill's workflow — not moving it myself.
  timestamp: 2026-07-05T02:24:07.510051+00:00
depends_on:
- 01KWMS1F9CC0XYB0Q446930PBX
- 01KWMSDVP4JM77YR0YMCE9S5ME
position_column: doing
position_ordinal: '80'
title: 'M4: gated E2E — LanguageModelSession + real stdio MCP server (system model)'
---
## What
Create the gated end-to-end test: spawn a real stdio MCP server (the ScriptedServer as a subprocess, or a filesystem echo server), wrap in `MCPServer`, build `LanguageModelSession(mcp:)` on the **system model**, run a prompt engineered to trigger a tool call, and assert the tool was called and its result content appears in the response. Gated behind an environment flag (`FOUNDATIONMODELSMCP_E2E=1`) and excluded from the default unit run — it needs the OS 27 SDK + on-device model availability (`SystemLanguageModel.availability`).

- [x] Gated E2E target/flag, skipped by default with a clear skip message
- [x] Real stdio server spawn + session construction via LanguageModelSession(mcp:)
- [x] Prompt → tool call → result assertion

## Acceptance Criteria
- [x] `swift test` (default) skips the E2E with an explanatory message
- [x] `FOUNDATIONMODELSMCP_E2E=1 swift test --filter E2E` on capable hardware performs a real tool call and asserts on the returned content
- [x] Unavailable model (availability check fails) → clean skip, not failure

## Tests
- [x] `Tests/FoundationModelsMCPTests/E2ETests.swift` as described (this task IS the test)
- [x] Default `swift test` remains green on CI without the model

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.