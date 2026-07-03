---
position_column: todo
position_ordinal: '80'
title: 'M0: Scaffold SwiftPM package — swift-sdk + FoundationModels only, CI'
---
## What
Create the SwiftPM package skeleton: `Package.swift`, library target `FoundationModelsMCP` (`Sources/FoundationModelsMCP/`), test target (`Tests/FoundationModelsMCPTests/`). **Exactly one external dependency**: `.product(name: "MCP", package: "swift-sdk")` pinned to the latest stable tag, plus linking the system `FoundationModels` framework — no MLX, no Router (plan.md Decisions → Enforcement). Platform floor macOS 27 / iOS 27 only, no `@available` branching. Add a GitHub Actions CI workflow (macOS, Xcode with the OS 27 SDK — note in the workflow that a self-hosted runner may be required if hosted runners lack the OS 27 SDK) running `swift build` and `swift test`. Verify and record the pinned swift-sdk's supported MCP protocol revision (target: **2025-11-25**) and its elicitation surface (`client.withElicitationHandler`) in `docs/swift-sdk-notes.md`.

- [ ] Package.swift with single external dependency + platforms
- [ ] Library + test targets compile
- [ ] CI workflow file present (build + test)
- [ ] docs/swift-sdk-notes.md records SDK protocol revision + elicitation surface

## Acceptance Criteria
- [ ] `swift build` and `swift test` pass **locally**
- [ ] The CI workflow file exists and its steps mirror the local commands (CI greenness itself is verified at merge, not by this task)
- [ ] `Package.swift` declares only swift-sdk as an external dependency
- [ ] `docs/swift-sdk-notes.md` exists and states the SDK's protocol revision and elicitation API

## Tests
- [ ] `Tests/FoundationModelsMCPTests/SmokeTests.swift`: imports `FoundationModelsMCP` and `MCP`, asserts a trivial truth — proves linkage
- [ ] `swift test` green locally

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.