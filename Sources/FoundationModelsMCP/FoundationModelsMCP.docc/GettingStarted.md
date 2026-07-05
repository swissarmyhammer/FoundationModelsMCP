# Getting started

Connect a `LanguageModelSession` to a stdio MCP server and let the model call
one of its tools.

## Overview

The runnable quick start lives at `Examples/EchoTool/EchoTool.swift` — a
~20-line hello world that spawns a stdio echo server, wraps it in
``MCPServer``, builds a `LanguageModelSession(mcp:)` on the system model, and
drives one prompt that triggers one tool call. Run it with:

```
swift run EchoTool
```

The repository README embeds that same file verbatim (a test —
`Tests/FoundationModelsMCPTests/ReadmeQuickStartTests.swift` — fails the build
if the two ever diverge), so this article doesn't duplicate the listing;
read it there or open the source file directly.

## The shape of every integration

Every consumer of this package follows the same three steps, regardless of
transport or how many tools are involved:

1. **Connect.** Construct an `MCP.Client`, connect it over a `Transport` (the
   swift-sdk's `StdioTransport` for a local subprocess, `HTTPClientTransport`
   for a remote server), and wrap the result in an ``MCPServer``.
2. **Add to a session.** Pass the ``MCPServer`` (or a single ``MCPTool``) to
   `LanguageModelSession(mcp:)` — both conform to ``MCPToolProvider``, so
   servers and loose tools compose freely in one call.
3. **Prompt.** Call `session.respond(to:)` as usual; when the model decides to
   call a tool, its arguments are generated under a `GenerationSchema`
   ``SchemaConverter`` synthesized from the tool's raw `inputSchema` — see
   <doc:EnforcementModel> for what that guarantees.

## Beyond one server

- **Multiple tools, one server:** an ``MCPServer`` vends every tool it
  discovers; add the whole server to expose all of them.
- **Mixing MCP and native tools:** because both ``MCPTool`` and ``MCPServer``
  conform to ``MCPToolProvider``, a session can combine them with an ordinary
  `FoundationModels.Tool` in the same `tools:` array.
- **Many servers, searched on demand:** this package always exposes tools
  directly — no registry, no search tool. A large, searchable catalog across
  many connected servers is the separate, sibling **FoundationModelsMultitool**
  project's job; see <doc:CatalogConsumerContract> for the live catalog
  surface it consumes from ``MCPServer``.
