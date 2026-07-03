---
depends_on:
- 01KWMS37EXGG7KRM8YN8ABXV7R
- 01KWMS3F3P3HHZ56C1FK7S44DQ
- 01KWMSDVP4JM77YR0YMCE9S5ME
position_column: todo
position_ordinal: '9380'
title: 'Examples: ElicitingAgent, CatalogBrowser, DynamicToolset'
---
## What
Create the remaining three `Examples/` executable targets per plan.md Examples §5–7, runnable via `swift run <Name>` and compiled in CI. **Toy servers come from the `MCPTestServer` utility target** (stdio subprocess; examples never import the test target): **ElicitingAgent** (both elicitation directions through one console ElicitationCoordinator — MCPTestServer's elicit-on-command tool mid-call, plus the model calling MCPElicitationTool; accept/decline/cancel at the terminal); **CatalogBrowser** (connect one or more servers, print the full catalog — name, title, description, annotations, icons, raw inputSchema, GenerationSchema — the M8 surface, doubling as Multitool's integration stub); **DynamicToolset** (MCPTestServer in timer add/remove/re-schema mode; prints each ToolCatalog snapshot from catalogUpdates with epoch, membership diff, fingerprint changes; then demonstrates call-time resolution of a vanished tool → structured not-available result).

- [ ] ElicitingAgent (console coordinator, both directions)
- [ ] CatalogBrowser (full catalog dump)
- [ ] DynamicToolset (timer mode + snapshot stream + resolution demo)
- [ ] All three wired into CI as build targets

## Acceptance Criteria
- [ ] `swift build --target <Name>` succeeds for all three locally and in CI
- [ ] CatalogBrowser output includes every catalog field named in plan.md M8
- [ ] DynamicToolset visibly shows an epoch increment and a fingerprint change across a scripted re-schema
- [ ] No example imports the test target

## Tests
- [ ] CI job builds all three example targets
- [ ] Snapshot-formatting and diff-printing logic covered in `Tests/FoundationModelsMCPTests/ExampleHelperTests.swift`

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.