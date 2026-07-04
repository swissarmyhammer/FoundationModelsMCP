import MCP
import MCPTestServer

// Minimal stdio executable wrapper around `ScriptedServer`, so the scripted
// server can also run as a spawned subprocess — for future `Examples/`
// executables and end-to-end tests that need a real out-of-process MCP
// server, rather than only the in-process `InMemoryTransport` pairing the
// test suite uses. Deliberately stub-level: a fixed echo tool plus a
// filesystem-tool mode. Scripting richer scenarios by process argument or
// stdin protocol is future `Examples/` work, not this fixture task.
let server = ScriptedServer(name: "mcp-test-server", version: "1.0.0")
await server.addEchoTool()
await server.addFilesystemTools()

try await server.start(transport: StdioTransport())
await server.waitUntilCompleted()
