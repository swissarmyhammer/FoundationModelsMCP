import MCP
import MCPTestServer

// Minimal stdio executable wrapper around `ScriptedServer`, so the scripted
// server can also run as a spawned subprocess for `Examples/` executables
// and end-to-end tests that need a real out-of-process MCP server, rather
// than only the in-process `InMemoryTransport` pairing the test suite uses.
//
// Which tool set gets registered is selected via `--mode <echo|filesystem|
// all>` (see `ServerMode`); no `--mode` flag at all (the default `swift run
// MCPTestServerCLI` invocation, and every existing caller predating this
// flag) registers everything, matching this CLI's original stub-level
// behavior.
let mode = ServerMode.parse(from: CommandLine.arguments)
let server = ScriptedServer(name: "mcp-test-server", version: "1.0.0")
await mode.registerTools(on: server)

try await server.start(transport: StdioTransport())
await server.waitUntilCompleted()
