---
depends_on:
- 01KWMS3F3P3HHZ56C1FK7S44DQ
- 01KWMS37EXGG7KRM8YN8ABXV7R
position_column: todo
position_ordinal: '9480'
title: DocC documentation + README
---
## What
Author the public documentation: a DocC catalog for the `FoundationModelsMCP` module covering every public symbol (MCPServer, MCPTool, MCPToolProvider, SchemaConverter behavior/fallbacks, ToolContentRenderer contract, ElicitationCoordinator, the frozen catalog surface) plus articles for the consumer contract (Multitool) and the enforcement model (declare vs. enforce). Write `README.md` with a quick-start whose code is the EchoTool example (kept compiling by referencing the example target), the dependency statement (swift-sdk + FoundationModels only), and pointers to Multitool/Router for search.

- [ ] DocC catalog; no undocumented public symbols
- [ ] Articles: catalog consumer contract, enforcement model
- [ ] README with EchoTool quick-start + scope/dependency statement

## Acceptance Criteria
- [ ] DocC build succeeds in CI with zero missing-documentation warnings for public symbols
- [ ] README quick-start code is the EchoTool source (or verbatim excerpt) so it cannot rot silently

## Tests
- [ ] CI step: `swift package generate-documentation` (or xcodebuild docbuild) succeeds
- [ ] CI step asserts README's swift snippet matches the EchoTool example source (simple diff check script)

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.