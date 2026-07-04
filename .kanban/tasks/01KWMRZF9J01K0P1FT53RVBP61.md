---
comments:
- actor: claude-code
  id: 01kwpfnmtf6t72zrg2ysfejckk
  text: |-
    Implemented via TDD.

    Context resolved: the blocked sibling task (MCPTool adapter, ^je50tar) says "the client seam protocol (defined by the MCPTool adapter task)", but that task actually depends on this one (not vice versa), so the protocol didn't exist yet. Defined it here instead, in Sources/ (library code, since the future MCPTool task will consume it), not Tests/.

    Created:
    - Sources/FoundationModelsMCP/MCPToolCalling.swift — new public protocol `MCPToolCalling: Sendable` with `func callTool(name: String, arguments: [String: Value]?) async throws -> CallTool.Result`. `MCP.Client` conforms via extension.
      - Design note: `MCP.Client`'s own built-in async `callTool(name:arguments:meta:)` convenience method discards `structuredContent` (only returns `(content: [Tool.Content], isError: Bool?)`). The SDK's other `callTool` overload (throws, returns `RequestContext<CallTool.Result>`) has the identical parameter list to the async one, so calling it by name from the extension is ambiguous with the async overload (confirmed by compiler: attempting to disambiguate by omitting `await` still resolved to the async overload and errored). Both overloads' capability check (`validateServerCapability`) is also `private`, so unreachable either way. Resolved by building the `tools/call` request directly and going through the public `send(_:)` (returns `RequestContext<CallTool.Result>`) + awaiting `.value` — same mechanism the SDK's own advanced overload uses internally.
    - Tests/FoundationModelsMCPTests/Support/MockClient.swift — `final class MockClient: MCPToolCalling, @unchecked Sendable`. Records `[Invocation]` (name + arguments) exactly, in order; plays back a FIFO queue of `Result<CallTool.Result, Error>` scripted via `script(_:)` / `script(throwing:)`; throws `MockClientError.noScriptedResult` when exhausted. Test-target only.
    - Tests/FoundationModelsMCPTests/Support/MockClientSelfTests.swift — 15 self-tests: seam conformance, recording fidelity (incl. nested arguments, and empty-dict vs nil arguments distinguished), playback of success/isError/structuredContent and each Tool.Content case (.text/.image/.audio/.resource/.resourceLink) with full-result equality, FIFO ordering across calls, scripted throw, and exhaustion.

    Verification (all fresh, this session):
    - `swift test --filter MockClientSelf` → 15/15 pass.
    - Clean rebuild (`rm -rf .build/out && swift build`) → Build complete, zero warnings.
    - Full `swift test` after clean build → 67/67 tests pass across 5 suites, zero warnings.
    - Ran adversarial double-check (REVISE → fixed both findings: reused-overload ambiguity turned out to not compile as suggested, so reverted to the original send()+RequestContext.value approach with clarifying doc comment; added the missing empty-dict-vs-nil test; strengthened 5 content-case tests from `.content`-only to full-result equality). Re-verified green after fixes.

    Leaving in `doing` per /implement process — not moving to review myself.
  timestamp: 2026-07-04T11:54:23.439324+00:00
depends_on:
- 01KWMRYGMXC08VX2W7P2DK2X0W
position_column: done
position_ordinal: '8480'
title: 'Test fixture: MockClient conforming to the library''s client seam'
---
## What\nCreate `Tests/FoundationModelsMCPTests/Support/MockClient.swift`: a mock/recording implementation of the **library's client seam protocol**. Note: the protocol was expected to be defined by the MCPTool adapter task, but that task actually depends on this one (not vice versa), so this task defined the seam itself — `Sources/FoundationModelsMCP/MCPToolCalling.swift` (public protocol `MCPToolCalling`, with `MCP.Client` conforming via extension) — since the swift-sdk's `MCP.Client` is a concrete actor and cannot be substituted directly. MockClient records `callTool(name:arguments:)` invocations exactly and returns scripted results: success, `isError`, `structuredContent`, and each content type (`.text`/`.image`/`.audio`/`.resource`/`.resourceLink`). Test-target only. (The scriptable server lives in its own utility-target task.)\n\n- [x] MockClient conforms to the client seam protocol\n- [x] Records name + arguments byte-for-byte\n- [x] Scripted results for success/error/structured/every content case\n\n## Acceptance Criteria\n- [x] Compiles in the test target only (never shipped in the library) — the seam protocol itself lives in Sources/ since the future MCPTool task depends on it\n- [x] Self-test proves exact recording and scripted-result playback\n\n## Tests\n- [x] `Tests/FoundationModelsMCPTests/Support/MockClientSelfTests.swift`: recording fidelity + playback of each scripted result kind\n- [x] `swift test --filter MockClientSelf` green\n\n## Workflow\n- Use `/tdd` — write failing tests first, then implement to make them pass.\n\n## Review Findings (2026-07-04 06:56)\n\n- [x] `Tests/FoundationModelsMCPTests/Support/MockClient.swift:22` — `@unchecked Sendable` conformance requires a documented synchronization invariant explaining how the mutable state (`invocations` and `scriptedResults`) remains safe across task boundaries. The comment \"Test-target only\" describes scope, not synchronization. Either: (1) Add a comment documenting the invariant (e.g., \"Used serially within single tests; no concurrent access occurs\"), or (2) convert to an actor, or (3) protect mutable state with a lock.