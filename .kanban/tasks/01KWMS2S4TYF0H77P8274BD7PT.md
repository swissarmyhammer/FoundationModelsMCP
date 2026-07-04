---
comments:
- actor: claude-code
  id: 01kwqe526a9d0n0sb181vkzs3j
  text: |-
    Implemented via TDD (RED confirmed: test file referencing not-yet-existing ElicitationCoordinator/ElicitationResponse failed to compile; then implemented to GREEN).

    Created:
    - Sources/FoundationModelsMCP/ElicitationCoordinator.swift — the `ElicitationCoordinator` protocol (`elicit(message:requestedSchema:)` form-mode, `elicit(message:url:)` URL-mode), `ElicitationResponse` enum (accept/decline/cancel), `Elicitation.RequestSchema.requiresURLModeRouting` (checks for a `secret: true` custom keyword per plan.md's "any `secret` marker is our convention" or `format: "url"`), and `ElicitationRouting.route(...)` — the shared routing decision so a later `MCPElicitationTool` (^8abxv7r) can reuse identical enforcement.
    - Wired `MCPServer.swift`: new `elicitationCoordinator` init param (default nil, backward compatible with all existing callers); `applyConnect` registers `client.withElicitationHandler` before `client.connect(transport:)`; `answerElicitation`/`makeElicitationResult` convert between `ElicitationResponse` and `CreateElicitation.Result`.
    - Tests/FoundationModelsMCPTests/ElicitationServerTests.swift + Support/RecordingElicitationCoordinator.swift (actor-based test double).

    Design/judgment calls (documented in code comments):
    1. **Capability declaration**: discovered mid-implementation that `MCP.Client.capabilities` is an actor-isolated stored property with NO public setter — the pinned swift-sdk gives no way to mutate it externally after Client construction (confirmed by compiler: "actor-isolated property can not be mutated on a nonisolated actor instance"). Per docs/swift-sdk-notes.md's own framing ("Registering a handler is how a client declares the elicitation capability"), `withElicitationHandler` is the only declaration mechanism actually available to a caller of this SDK version. A host that also needs the capability reflected in the literal `initialize` wire payload must construct its `MCP.Client` with `capabilities: .init(elicitation: ...)` up front, before handing it to `MCPServer`. Documented clearly on `declareElicitationCapabilityAndRegisterHandler`.
    2. **URL-mode routing for the no-secrets defensive case**: since a form-mode request with a sensitive/format:url field carries no genuine `url` (only a real wire `.url(URLParameters)` request has one), `elicit(message:url:)` takes `url: String?` — `nil` in the defensive-downgrade case, a real link for genuine server url-mode requests. Coordinator is responsible for presenting or safely refusing when `nil`.
    3. Used `secret: true` as the exact custom JSON Schema keyword name, matching plan.md's precise wording ("any `secret` marker is our convention").

    Verification: `swift build` clean (no warnings), `swift test --filter ElicitationServer` — 5/5 green, `swift test` (full suite) — 131/131 green. `mcp__sah__review` (review working) — 0 findings.
  timestamp: 2026-07-04T20:47:05.930654+00:00
depends_on:
- 01KWMS0RQH4YWDJGDAVR1M7FAY
position_column: doing
position_ordinal: '80'
title: 'Elicitation: ElicitationCoordinator protocol + server-initiated routing'
---
## What
Create `Sources/FoundationModelsMCP/ElicitationCoordinator.swift`: the host-owned coordinator protocol (`func elicit(message:requestedSchema:) async -> ElicitationResponse` with `accept(content)` / `decline` / `cancel`). Wire `MCPServer` to declare the **elicitation client capability** at connect and register `client.withElicitationHandler` routing each `elicitation/create` to the coordinator and returning the user's response. Enforce the no-secrets rule: a field marked sensitive (our convention) or `format: "url"` routes to **URL mode**, never form mode.

- [x] ElicitationCoordinator protocol + response types
- [x] Capability declared; withElicitationHandler routed
- [x] accept/decline/cancel round-trip to the server
- [x] Sensitive/format:url fields → URL mode routing

## Acceptance Criteria
- [x] A scripted server tool that elicits mid-call receives the coordinator's accept content, decline, and cancel (one test each)
- [x] A requestedSchema containing a sensitive-marked field triggers the URL-mode path on the coordinator, never form mode

## Tests
- [x] `Tests/FoundationModelsMCPTests/ElicitationServerTests.swift`: coordinator test double asserting request payloads and each response action; URL-mode routing case
- [x] `swift test --filter ElicitationServer` green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

## Note on capability declaration
`MCP.Client.capabilities` is an actor-isolated stored property with no public setter in the pinned swift-sdk — it cannot be mutated from outside the Client actor after construction (confirmed by compiler error during implementation). `MCPServer` therefore declares elicitation support the only way the SDK actually allows: registering `client.withElicitationHandler`, per `docs/swift-sdk-notes.md`'s own framing of that call as the declaration mechanism. See the doc comment on `declareElicitationCapabilityAndRegisterHandler` in MCPServer.swift for the documented host-side responsibility (construct `MCP.Client` with `capabilities: .init(elicitation: ...)` up front if the literal `initialize` wire payload must reflect it).