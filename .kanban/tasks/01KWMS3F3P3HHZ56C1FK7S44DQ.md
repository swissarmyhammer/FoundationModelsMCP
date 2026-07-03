---
depends_on:
- 01KWMS25WBFV42NGTCX3HKWHZP
position_column: todo
position_ordinal: '9080'
title: 'M8: freeze the live catalog API with a stub consumer'
---
## What
Freeze the public catalog surface FoundationModelsMultitool builds on: `MCPServer.catalog`, `catalogUpdates`, `ToolCatalog`/`ToolDescriptor`/`ServerIdentity` (epochs, fingerprints, annotations, icons, raw `inputSchema`, `GenerationSchema`), `diff(from:)`, and `tool(named:)`. Write a **stub consumer** in the test target that exercises the surface exactly as Multitool will: subscribe to `catalogUpdates`, drive the ScriptedServer through add → remove → same-name-schema-change, and assert epochs, fingerprint changes, diff output, and the structured not-found behavior. Mark the frozen API with doc comments; add a DocC article describing the consumer contract.

- [ ] Stub consumer test driving add/remove/schema-change end-to-end
- [ ] Assertions on epochs, fingerprints, diff, not-found
- [ ] Doc comments on every frozen public symbol
- [ ] DocC article: the catalog consumer contract

## Acceptance Criteria
- [ ] The stub consumer compiles against public API only (no @testable import for the surface under test)
- [ ] The full add/remove/schema-change scenario passes with exact epoch and fingerprint assertions
- [ ] Every public catalog symbol has a doc comment

## Tests
- [ ] `Tests/FoundationModelsMCPTests/StubConsumerTests.swift`: the end-to-end scenario above
- [ ] `swift test --filter StubConsumer` green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.