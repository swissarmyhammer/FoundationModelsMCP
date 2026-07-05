import Testing

import MCP
import MCPTestServer

/// Coverage for ``ServerMode``, the `--mode` selector `MCPTestServerCLI`
/// parses to decide which scripted tool set to register — added so
/// `Examples/EchoTool` and `Examples/FileAssistant` can spawn a
/// single-purpose `MCPTestServerCLI` subprocess instead of the CLI's
/// original stub-level "always register everything" behavior.
@Suite("ServerMode")
struct ServerModeTests {

    /// Connects a fresh `MCP.Client` to `server` over an in-memory transport
    /// pair and returns the names of every tool `tools/list` reports.
    ///
    /// - Parameter server: The scripted server to list tools from.
    /// - Returns: The registered tools' names, in `tools/list` order.
    private func registeredToolNames(on server: ScriptedServer) async throws -> [String] {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        try await server.start(transport: serverTransport)

        let client = Client(name: "ServerModeTestClient", version: "1.0")
        _ = try await client.connect(transport: clientTransport)

        let (tools, _) = try await client.listTools()
        return tools.map(\.name)
    }

    @Test("parse(from:) recognizes --mode echo")
    func parsesEchoMode() {
        #expect(ServerMode.parse(from: ["MCPTestServerCLI", "--mode", "echo"]) == .echo)
    }

    @Test("parse(from:) recognizes --mode filesystem")
    func parsesFilesystemMode() {
        #expect(ServerMode.parse(from: ["MCPTestServerCLI", "--mode", "filesystem"]) == .filesystem)
    }

    @Test("parse(from:) recognizes --mode all")
    func parsesAllMode() {
        #expect(ServerMode.parse(from: ["MCPTestServerCLI", "--mode", "all"]) == .all)
    }

    @Test("parse(from:) defaults to .all when no --mode flag is present")
    func defaultsToAllWhenFlagAbsent() {
        #expect(ServerMode.parse(from: ["MCPTestServerCLI"]) == .all)
    }

    @Test("parse(from:) defaults to .all when --mode's value is unrecognized")
    func defaultsToAllWhenValueUnrecognized() {
        #expect(ServerMode.parse(from: ["MCPTestServerCLI", "--mode", "bogus"]) == .all)
    }

    @Test("parse(from:) defaults to .all when --mode is the last argument with no value")
    func defaultsToAllWhenFlagHasNoValue() {
        #expect(ServerMode.parse(from: ["MCPTestServerCLI", "--mode"]) == .all)
    }

    @Test(".echo registers only the echo tool")
    func echoModeRegistersOnlyEchoTool() async throws {
        let server = ScriptedServer(name: "mode-test")
        await ServerMode.echo.registerTools(on: server)

        #expect(try await registeredToolNames(on: server) == ["echo"])
    }

    @Test(".filesystem registers only the filesystem tools")
    func filesystemModeRegistersOnlyFilesystemTools() async throws {
        let server = ScriptedServer(name: "mode-test")
        await ServerMode.filesystem.registerTools(on: server)

        #expect(Set(try await registeredToolNames(on: server)) == Set(["list_files", "read_file", "write_file"]))
    }

    @Test(".all registers both the echo tool and the filesystem tools")
    func allModeRegistersEverything() async throws {
        let server = ScriptedServer(name: "mode-test")
        await ServerMode.all.registerTools(on: server)

        #expect(
            Set(try await registeredToolNames(on: server))
                == Set(["echo", "list_files", "read_file", "write_file"]))
    }
}
