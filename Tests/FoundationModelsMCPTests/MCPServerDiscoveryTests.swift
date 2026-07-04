import Foundation
import Testing

@testable import FoundationModelsMCP
import FoundationModels
import MCP
import MCPTestServer

/// Coverage for ``MCPServer``: paginated `tools/list` discovery completeness,
/// the `connecting`/`ready`/`faulted` readiness state machine, and
/// ``ServerIdentity`` stability across a reconnect.
///
/// Exercised against a real `MCP.Client` connected to a ``ScriptedServer``
/// over `InMemoryTransport` — unlike ``MCPTool``'s tests against
/// ``MockClient``, ``MCPServer`` wraps `MCP.Client` directly (it owns the
/// client's whole connection lifecycle, not just `tools/call` forwarding),
/// so only a real client/server pair can drive its `tools/list` pagination
/// and `initialize` handshake.
@Suite("MCPServerDiscovery")
struct MCPServerDiscoveryTests {

    /// Builds a fresh `MCP.Client` for one test, named after the test itself
    /// only for readability in transport-level logs.
    ///
    /// - Returns: A client with default (non-strict) configuration, matching
    ///   every other real-client test in this suite family.
    private func makeClient() -> Client {
        Client(name: "MCPServerDiscoveryTestClient", version: "1.0")
    }

    // MARK: - Paginated discovery completeness

    @Test("connect(transport:) discovers every tool across a 3-page scripted tools/list, without truncation")
    func discoversAllToolsAcrossPagination() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let scripted = ScriptedServer(toolsPageSize: 2)
        let expectedNames = (0..<5).map { "tool-\($0)" }
        for name in expectedNames {
            await scripted.addTool(ScriptedServer.echoTool(named: name))
        }
        try await scripted.start(transport: serverTransport)

        let server = MCPServer(client: makeClient())
        try await server.connect(transport: clientTransport)

        let tools = try await server.mcpTools()
        #expect(tools.count == 5)
        #expect(Set(tools.map(\.name)) == Set(expectedNames))
    }

    @Test("foundationModelsTools() vends the same discovered tools, type-erased to FoundationModels.Tool")
    func foundationModelsToolsVendsDiscoveredTools() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let scripted = ScriptedServer(toolsPageSize: 2)
        let expectedNames = (0..<5).map { "tool-\($0)" }
        for name in expectedNames {
            await scripted.addTool(ScriptedServer.echoTool(named: name))
        }
        try await scripted.start(transport: serverTransport)

        let server = MCPServer(client: makeClient())
        try await server.connect(transport: clientTransport)

        let tools = try await server.foundationModelsTools()
        #expect(tools.count == 5)
        #expect(Set(tools.map(\.name)) == Set(expectedNames))
    }

    // MARK: - Readiness state machine

    @Test("state starts at connecting and transitions to ready after a successful connect")
    func stateTransitionsToReadyOnSuccess() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let scripted = ScriptedServer()
        await scripted.addEchoTool()
        try await scripted.start(transport: serverTransport)

        let server = MCPServer(client: makeClient())
        #expect(await server.state == .connecting)

        try await server.connect(transport: clientTransport)
        #expect(await server.state == .ready)
    }

    @Test("state becomes faulted when the scripted transport fails to connect")
    func stateBecomesFaultedOnConnectFailure() async throws {
        let (clientTransport, _) = await InMemoryTransport.createConnectedPair()
        let flaky = FlakyConnectTransport(wrapping: clientTransport, failingConnectAttempts: 1)

        let server = MCPServer(client: makeClient())

        await #expect(throws: (any Error).self) {
            try await server.connect(transport: flaky)
        }

        guard case .faulted = await server.state else {
            Issue.record("Expected .faulted state after a scripted connect failure")
            return
        }
    }

    @Test("mcpTools() throws before the first successful connect completes")
    func mcpToolsThrowsBeforeReady() async throws {
        let server = MCPServer(client: makeClient())

        await #expect(throws: MCPServerError.self) {
            _ = try await server.mcpTools()
        }
    }

    @Test("identity stays nil when discovery fails after a successful handshake, matching state == .faulted")
    func identityRemainsNilWhenDiscoveryFailsAfterSuccessfulHandshake() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let scripted = ScriptedServer()
        // An inputSchema referencing a $defs entry that was never declared —
        // SchemaConverter.emit(_:) throws GenerationSchema.SchemaError for
        // this (an unresolved $ref), so MCPTool.init(tool:client:) throws
        // mid-pagination, after the initialize handshake already succeeded.
        let malformedInputSchema: Value = [
            "type": "object",
            "properties": [
                "value": ["$ref": "#/$defs/Missing"]
            ],
            "required": ["value"],
        ]
        await scripted.addTool(
            ScriptedTool(
                definition: MCP.Tool(
                    name: "malformed",
                    description: "A tool with an inputSchema referencing an undeclared $defs entry.",
                    inputSchema: malformedInputSchema
                ),
                handler: { _ in CallTool.Result(content: []) }
            )
        )
        try await scripted.start(transport: serverTransport)

        let server = MCPServer(client: makeClient())

        await #expect(throws: (any Error).self) {
            try await server.connect(transport: clientTransport)
        }

        guard case .faulted = await server.state else {
            Issue.record("Expected .faulted state after a discovery-phase failure")
            return
        }
        #expect(await server.identity == nil)
    }

    // MARK: - ServerIdentity stability

    @Test(
        "identity is derived once on first connect and stays stable across a reconnect, even if the server's reported name later changes"
    )
    func identityStableAcrossReconnect() async throws {
        let (clientTransport1, serverTransport1) = await InMemoryTransport.createConnectedPair()
        let firstServer = ScriptedServer(name: "primary-server")
        await firstServer.addEchoTool()
        try await firstServer.start(transport: serverTransport1)

        let server = MCPServer(client: makeClient())
        try await server.connect(transport: clientTransport1)
        let firstIdentity = await server.identity

        await server.disconnect()

        let (clientTransport2, serverTransport2) = await InMemoryTransport.createConnectedPair()
        let secondServer = ScriptedServer(name: "renamed-server")
        await secondServer.addEchoTool()
        try await secondServer.start(transport: serverTransport2)

        try await server.connect(transport: clientTransport2)
        let secondIdentity = await server.identity

        #expect(firstIdentity != nil)
        #expect(firstIdentity == secondIdentity)
        #expect(firstIdentity?.name == "primary-server")
    }
}
