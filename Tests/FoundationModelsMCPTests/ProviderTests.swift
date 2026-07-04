import Foundation
import Testing

@testable import FoundationModelsMCP
import FoundationModels
import MCP
import MCPTestServer

/// Coverage for ``MCPToolProvider`` and the ``resolveSessionTools(from:)``
/// function it's built around: flattening providers into one session tool
/// list, blocking on an ``MCPServer``'s readiness, and disambiguating
/// cross-provider tool-name collisions deterministically.
///
/// Every assertion here is against ``resolveSessionTools(from:)``'s return
/// value directly — never against a constructed `LanguageModelSession`,
/// which exposes no way to introspect its own tool list. The
/// `LanguageModelSession(mcp:)` convenience is a thin wrapper over that same
/// function (see its own doc), so its one test here only proves it compiles
/// and constructs without throwing; the actual tool-resolution behavior is
/// asserted exhaustively against ``resolveSessionTools(from:)`` itself.
@Suite("Provider")
struct ProviderTests {

    // MARK: - Fixtures

    /// Builds a fresh `MCP.Client` named `name`, for readability in
    /// transport-level logs.
    ///
    /// - Parameter name: The client's display name.
    /// - Returns: A client with default (non-strict) configuration.
    private func makeClient(named name: String) -> Client {
        Client(name: name, version: "1.0")
    }

    /// Builds and connects an ``MCPServer`` backed by a fresh ``ScriptedServer``
    /// that reports `name` at `initialize` (and therefore establishes it as
    /// the server's ``ServerIdentity/name``), serving one echo-style tool per
    /// name in `toolNames`.
    ///
    /// - Parameters:
    ///   - name: The scripted server's self-reported name.
    ///   - toolNames: The names of the echo-style tools to register.
    /// - Returns: An ``MCPServer`` already connected and ``MCPServerState/ready``.
    /// - Throws: Whatever `ScriptedServer.start(transport:)` or
    ///   `MCPServer.connect(transport:)` throws.
    private func makeReadyServer(named name: String, toolNames: [String]) async throws -> MCPServer {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let scripted = ScriptedServer(name: name)
        for toolName in toolNames {
            await scripted.addTool(ScriptedServer.echoTool(named: toolName))
        }
        try await scripted.start(transport: serverTransport)

        let server = MCPServer(client: makeClient(named: "\(name)Client"))
        try await server.connect(transport: clientTransport)
        return server
    }

    /// Builds a standalone ``MCPTool`` backed by a `MockClient`, with no
    /// associated ``MCPServer``.
    ///
    /// - Parameter name: The tool's name.
    /// - Returns: The constructed tool.
    /// - Throws: Whatever `MCPTool.init(tool:client:)` throws.
    private func makeStandaloneTool(named name: String) throws -> MCPTool {
        let sourceTool = MCP.Tool(
            name: name,
            description: "A standalone tool.",
            inputSchema: .object(["type": .string("object")])
        )
        return try MCPTool(tool: sourceTool, client: MockClient())
    }

    // MARK: - Conformances

    @Test("MCPTool.sessionTools() returns itself as the sole session tool")
    func mcpToolSessionToolsReturnsItself() async throws {
        let tool = try makeStandaloneTool(named: "standalone")

        let tools = try await tool.sessionTools()

        #expect(tools.count == 1)
        #expect(tools[0].name == "standalone")
    }

    // MARK: - Flattening

    @Test("resolveSessionTools(from:) flattens a standalone MCPTool and an MCPServer's tools into one list")
    func flattensAcrossProviderKinds() async throws {
        let tool = try makeStandaloneTool(named: "standalone")
        let server = try await makeReadyServer(named: "fs", toolNames: ["read", "write"])

        let tools = try await resolveSessionTools(from: [tool, server])

        #expect(Set(tools.map(\.name)) == Set(["standalone", "read", "write"]))
    }

    // MARK: - Readiness blocking

    @Test("resolveSessionTools(from:) blocks until a still-connecting MCPServer becomes ready")
    func blocksUntilServerReady() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let scripted = ScriptedServer(name: "delayed")
        await scripted.addTool(ScriptedServer.echoTool(named: "search"))
        try await scripted.start(transport: serverTransport)

        let server = MCPServer(client: makeClient(named: "delayedClient"))
        #expect(await server.state == .connecting)

        // Scripts a delayed connect: resolveSessionTools(from:) is called
        // immediately, while the server is still .connecting, and this task
        // only connects it after a delay comfortably longer than
        // MCPServer's internal readiness poll interval.
        Task {
            do {
                try await Task.sleep(for: .milliseconds(150))
                try await server.connect(transport: clientTransport)
            } catch {
                Issue.record("Unexpected error scheduling the delayed connect: \(error)")
            }
        }

        let start = ContinuousClock.now
        let tools = try await resolveSessionTools(from: [server])
        let elapsed = ContinuousClock.now - start

        #expect(elapsed >= .milliseconds(100))
        #expect(tools.map(\.name) == ["search"])
    }

    @Test("resolveSessionTools(from:) throws MCPServerError.notReady when a provided MCPServer's connection is faulted")
    func throwsWhenServerConnectionIsFaulted() async throws {
        let (clientTransport, _) = await InMemoryTransport.createConnectedPair()
        let flaky = FlakyConnectTransport(wrapping: clientTransport, failingConnectAttempts: 1)

        let server = MCPServer(client: makeClient(named: "flakyClient"))

        // The single-attempt connect(transport:) (not the backoff-retrying
        // overload) throws directly on the scripted failure, leaving state
        // .faulted — matching MCPServerDiscoveryTests'
        // stateBecomesFaultedOnConnectFailure.
        await #expect(throws: (any Error).self) {
            try await server.connect(transport: flaky)
        }
        guard case .faulted = await server.state else {
            Issue.record("Expected .faulted state after the scripted connect failure")
            return
        }

        do {
            _ = try await resolveSessionTools(from: [server])
            Issue.record("Expected resolveSessionTools(from:) to throw for a faulted server")
        } catch let MCPServerError.notReady(state) {
            guard case .faulted = state else {
                Issue.record("Expected MCPServerError.notReady to carry .faulted state, got \(state)")
                return
            }
        } catch {
            Issue.record("Expected MCPServerError.notReady, got \(error)")
        }
    }

    // MARK: - Collision determinism

    @Test("resolveSessionTools(from:) disambiguates a cross-server tool-name collision deterministically")
    func disambiguatesCrossServerCollisionDeterministically() async throws {
        let serverA = try await makeReadyServer(named: "weather", toolNames: ["search"])
        let serverB = try await makeReadyServer(named: "docs", toolNames: ["search"])

        let firstRun = try await resolveSessionTools(from: [serverA, serverB]).map(\.name).sorted()
        let secondRun = try await resolveSessionTools(from: [serverA, serverB]).map(\.name).sorted()

        #expect(firstRun == ["docs_search", "weather_search"])
        #expect(firstRun == secondRun)
    }

    @Test("a renamed tool obtained via collision resolution remains fully functional when called")
    func renamedToolRemainsFunctionalWhenCalled() async throws {
        // Built inline (rather than via ``makeReadyServer(named:toolNames:)``)
        // so `scriptedA`/`scriptedB` stay in scope for the entire test:
        // ScriptedServer's handlers capture `[weak self]`, so once the actual
        // `call(arguments:)` below reaches the transport, the scripted server
        // backing it must still be alive to answer, not just at connect time.
        let (clientTransportA, serverTransportA) = await InMemoryTransport.createConnectedPair()
        let scriptedA = ScriptedServer(name: "weather")
        await scriptedA.addTool(ScriptedServer.echoTool(named: "search"))
        try await scriptedA.start(transport: serverTransportA)
        let serverA = MCPServer(client: makeClient(named: "weatherClient"))
        try await serverA.connect(transport: clientTransportA)

        let (clientTransportB, serverTransportB) = await InMemoryTransport.createConnectedPair()
        let scriptedB = ScriptedServer(name: "docs")
        await scriptedB.addTool(ScriptedServer.echoTool(named: "search"))
        try await scriptedB.start(transport: serverTransportB)
        let serverB = MCPServer(client: makeClient(named: "docsClient"))
        try await serverB.connect(transport: clientTransportB)

        let tools = try await resolveSessionTools(from: [serverA, serverB])

        guard let renamedTool = tools.first(where: { $0.name == "weather_search" }) as? MCPTool else {
            Issue.record("Expected a renamed \"weather_search\" MCPTool among the resolved tools")
            return
        }

        // renamed(to:) only changes `name`; `call(arguments:)` must still
        // forward to the same underlying MCP tool ("search" on serverA's
        // echo server) and render its result exactly as it would have before
        // disambiguation.
        let output = try await renamedTool.call(arguments: GeneratedContent(properties: ["text": "still works"]))

        #expect(output == "still works")
    }

    @Test("resolveSessionTools(from:) leaves non-colliding tool names unchanged")
    func leavesNonCollidingNamesUnchanged() async throws {
        let serverA = try await makeReadyServer(named: "weather", toolNames: ["forecast"])
        let serverB = try await makeReadyServer(named: "docs", toolNames: ["search"])

        let tools = try await resolveSessionTools(from: [serverA, serverB])

        #expect(Set(tools.map(\.name)) == Set(["forecast", "search"]))
    }

    // MARK: - LanguageModelSession(mcp:) convenience

    @Test("LanguageModelSession(mcp:) constructs from a provider list without throwing")
    func convenienceInitConstructsFromProviders() async throws {
        let server = try await makeReadyServer(named: "fs", toolNames: ["read"])

        _ = try await LanguageModelSession(mcp: server, instructions: "test session")
    }
}
