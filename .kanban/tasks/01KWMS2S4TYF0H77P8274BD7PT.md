---
depends_on:
- 01KWMS0RQH4YWDJGDAVR1M7FAY
position_column: todo
position_ordinal: '8e80'
title: 'Elicitation: ElicitationCoordinator protocol + server-initiated routing'
---
## What
Create `Sources/FoundationModelsMCP/ElicitationCoordinator.swift`: the host-owned coordinator protocol (`func elicit(message:requestedSchema:) async -> ElicitationResponse` with `accept(content)` / `decline` / `cancel`). Wire `MCPServer` to declare the **elicitation client capability** at connect and register `client.withElicitationHandler` routing each `elicitation/create` to the coordinator and returning the user's response. Enforce the no-secrets rule: a field marked sensitive (our convention) or `format: "url"` routes to **URL mode**, never form mode.

- [ ] ElicitationCoordinator protocol + response types
- [ ] Capability declared; withElicitationHandler routed
- [ ] accept/decline/cancel round-trip to the server
- [ ] Sensitive/format:url fields → URL mode routing

## Acceptance Criteria
- [ ] A scripted server tool that elicits mid-call receives the coordinator's accept content, decline, and cancel (one test each)
- [ ] A requestedSchema containing a sensitive-marked field triggers the URL-mode path on the coordinator, never form mode

## Tests
- [ ] `Tests/FoundationModelsMCPTests/ElicitationServerTests.swift`: coordinator test double asserting request payloads and each response action; URL-mode routing case
- [ ] `swift test --filter ElicitationServer` green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.