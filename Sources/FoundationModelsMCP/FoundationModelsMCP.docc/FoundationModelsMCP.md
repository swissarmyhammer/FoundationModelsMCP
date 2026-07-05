# ``FoundationModelsMCP``

Bridge Apple's FoundationModels `LanguageModelSession` to tools served by any
Model Context Protocol (MCP) server.

## Overview

`FoundationModelsMCP` is a thin bridge, not a reimplementation of MCP: every
connection lifecycle, transport (stdio + HTTP/SSE), and wire-protocol concern
comes from the official
[`modelcontextprotocol/swift-sdk`](https://github.com/modelcontextprotocol/swift-sdk).
This package's entire value-add is the FoundationModels half of the bridge —
converting an MCP tool's `inputSchema` into a `GenerationSchema` at runtime,
adapting the result into `FoundationModels.Tool`, and rendering an MCP
`tools/call` result back into model-consumable text.

Start with <doc:GettingStarted> for the quick-start (the same source as
`Examples/EchoTool`), then <doc:EnforcementModel> for how schema constraints
are declared here and enforced by the session's model, and
<doc:CatalogConsumerContract> for the live catalog surface a downstream tool
router (`FoundationModelsMultitool`) builds on.

## Topics

### Articles

- <doc:GettingStarted>
- <doc:EnforcementModel>
- <doc:CatalogConsumerContract>

### Connecting to a server

- ``MCPServer``
- ``MCPServerState``
- ``MCPServerError``
- ``ServerIdentity``
- ``BackoffPolicy``
- ``CallProgress``

### Adding tools to a session

- ``MCPToolProvider``
- ``MCPTool``
- ``MCPToolCalling``

### Schema translation

- ``SchemaConverter``
- ``SchemaIR``
- ``SchemaConversion``
- ``SchemaConversionLogRecord``
- ``SchemaConversionLogHandler``

### Argument and result codecs

- ``GeneratedContentCodec``
- ``GeneratedContentCodecError``
- ``ToolContentRenderer``

### The live catalog surface

- ``ToolCatalog``
- ``ToolCatalogDiff``
- ``ToolDescriptor``
- ``ToolAnnotations``

### Elicitation

- ``ElicitationCoordinator``
- ``ElicitationResponse``
- ``ElicitationRouting``
- ``MCPElicitationTool``

### Package metadata

- ``FoundationModelsMCP/FoundationModelsMCP``
