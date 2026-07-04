import Foundation
import Testing

@testable import FoundationModelsMCP
import MCP
import MCPTestServer

/// Coverage for ``MCPServer``'s server-initiated elicitation routing:
/// declaring the elicitation client capability, registering
/// `client.withElicitationHandler`, and routing each `elicitation/create`
/// request to a host-provided ``ElicitationCoordinator`` — including the
/// no-secrets-in-form-mode enforcement that routes a sensitive-marked or
/// `format: "url"` `requestedSchema` to the coordinator's URL-mode path
/// instead of its form-mode path.
///
/// Exercised against a real `MCP.Client`/``ScriptedServer`` pair over
/// `InMemoryTransport`, using
/// ``ScriptedServer/addElicitingTool(named:message:requestedSchema:)`` — the
/// same fixture family `MCPServerDiscoveryTests`/`ResilienceTests` use for
/// discovery/resilience coverage.
@Suite("ElicitationServer")
struct ElicitationServerTests {

    /// Builds a fresh `MCP.Client` for one test, named after the test itself
    /// only for readability in transport-level logs.
    private func makeClient() -> Client {
        Client(name: "ElicitationServerTestClient", version: "1.0")
    }

    /// A flat-primitive `requestedSchema` with one ordinary, non-sensitive
    /// string field — the baseline schema every accept/decline/cancel test
    /// shares.
    private static let ordinarySchema = Elicitation.RequestSchema(
        properties: ["favoriteColor": .object(["type": .string("string")])]
    )

    /// Connects a fresh ``MCPServer`` wrapping `coordinator` to a
    /// ``ScriptedServer`` that elicits mid-call via
    /// ``ScriptedServer/addElicitingTool(named:message:requestedSchema:)``,
    /// then calls the eliciting tool — the shared setup behind every test in
    /// this suite.
    ///
    /// - Parameters:
    ///   - message: The elicitation prompt the scripted tool sends.
    ///   - requestedSchema: The schema the scripted tool requests.
    ///   - coordinator: The coordinator the connected ``MCPServer`` routes
    ///     to.
    /// - Returns: The rendered `tools/call` result.
    private func callElicitingTool(
        message: String,
        requestedSchema: Elicitation.RequestSchema,
        coordinator: RecordingElicitationCoordinator
    ) async throws -> String {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let scripted = ScriptedServer()
        await scripted.addElicitingTool(
            named: "ask", message: message, requestedSchema: requestedSchema)
        try await scripted.start(transport: serverTransport)

        let server = MCPServer(client: makeClient(), elicitationCoordinator: coordinator)
        try await server.connect(transport: clientTransport)

        return await server.call(toolNamed: "ask")
    }

    // MARK: - accept / decline / cancel round-trip

    @Test("An eliciting tool call receives the coordinator's accept content")
    func acceptRoundTrips() async throws {
        let coordinator = RecordingElicitationCoordinator(
            responding: .accept(content: ["favoriteColor": .string("teal")]))

        let rendered = try await callElicitingTool(
            message: "What's your favorite color?",
            requestedSchema: Self.ordinarySchema,
            coordinator: coordinator)

        #expect(rendered.contains("elicitation accept"))
        let formCalls = await coordinator.formCalls
        #expect(
            formCalls == [
                .init(message: "What's your favorite color?", requestedSchema: Self.ordinarySchema)
            ])
        #expect(await coordinator.urlCalls.isEmpty)
    }

    @Test("An eliciting tool call receives the coordinator's decline")
    func declineRoundTrips() async throws {
        let coordinator = RecordingElicitationCoordinator(responding: .decline)

        let rendered = try await callElicitingTool(
            message: "What's your favorite color?",
            requestedSchema: Self.ordinarySchema,
            coordinator: coordinator)

        #expect(rendered.contains("elicitation decline"))
    }

    @Test("An eliciting tool call receives the coordinator's cancel")
    func cancelRoundTrips() async throws {
        let coordinator = RecordingElicitationCoordinator(responding: .cancel)

        let rendered = try await callElicitingTool(
            message: "What's your favorite color?",
            requestedSchema: Self.ordinarySchema,
            coordinator: coordinator)

        #expect(rendered.contains("elicitation cancel"))
    }

    // MARK: - URL-mode routing (no-secrets enforcement)

    @Test("A requestedSchema with a secret-marked field routes to the coordinator's URL-mode path, never form mode")
    func secretMarkedFieldRoutesToURLMode() async throws {
        let sensitiveSchema = Elicitation.RequestSchema(
            properties: [
                "apiKey": .object(["type": .string("string"), "secret": .bool(true)])
            ]
        )
        let coordinator = RecordingElicitationCoordinator(
            responding: .accept(content: ["apiKey": .string("secret-value")]))

        _ = try await callElicitingTool(
            message: "Please provide your API key",
            requestedSchema: sensitiveSchema,
            coordinator: coordinator)

        #expect(await coordinator.formCalls.isEmpty)
        #expect(
            await coordinator.urlCalls == [
                .init(message: "Please provide your API key", url: nil)
            ])
    }

    @Test("A requestedSchema with a format: url field routes to the coordinator's URL-mode path, never form mode")
    func urlFormatFieldRoutesToURLMode() async throws {
        let urlFormatSchema = Elicitation.RequestSchema(
            properties: [
                "callbackURL": .object(["type": .string("string"), "format": .string("url")])
            ]
        )
        let coordinator = RecordingElicitationCoordinator(
            responding: .accept(content: ["callbackURL": .string("https://example.com")]))

        _ = try await callElicitingTool(
            message: "Provide your callback URL",
            requestedSchema: urlFormatSchema,
            coordinator: coordinator)

        #expect(await coordinator.formCalls.isEmpty)
        #expect(
            await coordinator.urlCalls == [
                .init(message: "Provide your callback URL", url: nil)
            ])
    }
}
