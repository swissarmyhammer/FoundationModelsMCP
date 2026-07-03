---
depends_on:
- 01KWMS2S4TYF0H77P8274BD7PT
- 01KWMRZYD0ZMNYS0A0QA3M3X75
position_column: todo
position_ordinal: 8f80
title: 'MCPElicitationTool: agent-initiated elicitation'
---
## What
Create `Sources/FoundationModelsMCP/MCPElicitationTool.swift`: a `FoundationModels.Tool` letting the *agent* elicit. Constrained input `{ message, requestedSchema }` where `requestedSchema` is the flat-primitive elicitation subset — declared via a SchemaConverter-built `parameters` whose **SchemaIR is asserted in tests** (flat primitives only; nesting impossible by construction). `call` routes through the shared `ElicitationCoordinator`, awaits `accept`/`decline`/`cancel`, and renders the structured answer (or non-accept outcome) for the model. Sensitive/`format:"url"` fields route to URL mode per the coordinator contract.

- [ ] Tool with { message, requestedSchema } constrained parameters
- [ ] Routes through the same ElicitationCoordinator as server-initiated
- [ ] accept content / decline / cancel each rendered distinctly
- [ ] Parameters' SchemaIR asserts flat-primitive-only shape

## Acceptance Criteria
- [ ] Calling with a fixture args payload invokes the coordinator with the exact message + schema
- [ ] Each of accept/decline/cancel produces distinct, documented model-facing output
- [ ] The declared parameters' SchemaIR contains no nested-object/array-of-object nodes (asserted on the IR, not on opaque Apple types)

## Tests
- [ ] `Tests/FoundationModelsMCPTests/MCPElicitationToolTests.swift`: coordinator double asserting payloads; all three response actions; flat-primitive IR assertion
- [ ] `swift test --filter MCPElicitationTool` green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.