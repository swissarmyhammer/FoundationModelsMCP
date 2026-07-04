import Foundation
import Testing

@testable import FoundationModelsMCP
import MCP
import MCPTestServer

/// Coverage for ``MCPServer``'s connection resilience: backoff-retried
/// connect, exhaustion, mid-call fault → `isError` mapping, and
/// auto-reconnect back to ``MCPServerState/ready``.
///
/// Every test drives its own ``ManualClock`` instead of a real
/// `ContinuousClock`, so a full multi-attempt exponential-backoff schedule
/// is exercised with no real sleeps.
@Suite("Resilience")
struct ResilienceTests {

    /// Builds a fresh `MCP.Client` for one test, named after the test itself
    /// only for readability in transport-level logs.
    private func makeClient() -> Client {
        Client(name: "ResilienceTestClient", version: "1.0")
    }

    // MARK: - Backoff schedule

    @Test("connect(transport:backoffPolicy:) succeeds on attempt 3 with the expected exponential backoff schedule")
    func connectSucceedsOnThirdAttemptWithExpectedSchedule() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let scripted = ScriptedServer()
        await scripted.addEchoTool()
        try await scripted.start(transport: serverTransport)

        let flaky = FlakyConnectTransport(wrapping: clientTransport, failingConnectAttempts: 2)
        let clock = ManualClock()
        let policy = BackoffPolicy(
            connectTimeout: .seconds(10), baseDelay: .milliseconds(100), maxDelay: .seconds(10),
            maxAttempts: 5)

        let server = MCPServer(client: makeClient(), clock: clock)
        try await server.connect(transport: flaky, backoffPolicy: policy)

        #expect(await server.state == .ready)
        #expect(await flaky.connectAttempts == 3)
        #expect(clock.recordedSleeps == [.milliseconds(100), .milliseconds(200)])
    }

    // MARK: - Exhaustion

    @Test("connect(transport:backoffPolicy:) throws a typed error naming the server identity once backoff is exhausted")
    func connectThrowsTypedErrorNamingServerIdentityWhenExhausted() async throws {
        let (clientTransport, _) = await InMemoryTransport.createConnectedPair()
        let flaky = FlakyConnectTransport(wrapping: clientTransport, failingConnectAttempts: 10)
        let clock = ManualClock()
        let policy = BackoffPolicy(
            connectTimeout: .seconds(10), baseDelay: .milliseconds(10), maxDelay: .seconds(1),
            maxAttempts: 3)

        let server = MCPServer(client: makeClient(), name: "my-flaky-server", clock: clock)

        do {
            try await server.connect(transport: flaky, backoffPolicy: policy)
            Issue.record("Expected connect(transport:backoffPolicy:) to throw")
        } catch let MCPServerError.backoffExhausted(serverName, attempts, _) {
            #expect(serverName == "my-flaky-server")
            #expect(attempts == 3)
        } catch {
            Issue.record("Expected MCPServerError.backoffExhausted, got \(error)")
        }

        guard case .faulted = await server.state else {
            Issue.record("Expected .faulted state after exhausted backoff")
            return
        }
    }

    // MARK: - Per-attempt timeout bounds real wall-clock time

    @Test("connect(transport:backoffPolicy:)'s per-attempt timeout bounds real wall-clock time even when the underlying transport.connect() never returns")
    func connectAttemptTimeoutBoundsRealWallClockTimeEvenWhenTransportHangs() async throws {
        let hanging = HangingTransport()
        let clock = ManualClock()
        let policy = BackoffPolicy(
            connectTimeout: .milliseconds(50), baseDelay: .milliseconds(1), maxDelay: .milliseconds(1),
            maxAttempts: 1)
        let server = MCPServer(client: makeClient(), clock: clock)

        let start = ContinuousClock.now
        await #expect(throws: MCPServerError.self) {
            try await server.connect(transport: hanging, backoffPolicy: policy)
        }
        let elapsed = ContinuousClock.now - start

        // The hanging transport's own connect() never returns (it sleeps
        // for 60 real seconds), so this proves the retry loop actually
        // returned promptly on the 50ms connectTimeout rather than blocking
        // on the abandoned attempt.
        #expect(elapsed < .seconds(5))
    }

    @Test("a connect attempt that finally resolves after backoff has already been exhausted does not clobber state")
    func lateResolvingAttemptAfterExhaustionIsDiscarded() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let scripted = ScriptedServer()
        await scripted.addEchoTool()
        try await scripted.start(transport: serverTransport)

        let gated = GatedConnectTransport(wrapping: clientTransport)
        let clock = ManualClock()
        let policy = BackoffPolicy(
            connectTimeout: .milliseconds(30), baseDelay: .milliseconds(1), maxDelay: .milliseconds(1),
            maxAttempts: 1)
        let server = MCPServer(client: makeClient(), clock: clock)

        // The gate stays closed past connectTimeout, so this attempt times
        // out and backoff is exhausted while the orphaned attempt is still
        // blocked in the background — still .connecting, since it never
        // reached either of applyConnect's own success/failure branches.
        await #expect(throws: MCPServerError.self) {
            try await server.connect(transport: gated, backoffPolicy: policy)
        }
        guard case .connecting = await server.state else {
            Issue.record("Expected .connecting state: the orphaned attempt is still blocked on the gate")
            return
        }

        // Now let the orphaned attempt actually succeed. There's no signal
        // to poll for here (the whole point is that nothing should
        // change), so this waits a short, fixed, bounded real interval to
        // give the detached background attempt a chance to run and apply
        // (or, correctly, discard) its result before asserting.
        await gated.release()
        try await Task.sleep(for: .milliseconds(200))

        // The late success must have been discarded: identity was never
        // established and state never advanced to .ready.
        #expect(await server.identity == nil)
        #expect(await server.state != .ready)
    }

    // MARK: - Mid-call fault → isError, then auto-reconnect

    @Test("call(toolNamed:arguments:) renders a mid-call transport fault as an isError-style result and auto-reconnects to ready")
    func callDuringFaultReturnsErrorResultAndReconnectsToReady() async throws {
        let respawning = RespawningTransport {
            let (client, server) = await InMemoryTransport.createConnectedPair()
            let scripted = ScriptedServer()
            await scripted.addEchoTool()
            try await scripted.start(transport: server)
            return (client, scripted)
        }
        let clock = ManualClock()
        let server = MCPServer(client: makeClient(), clock: clock)
        try await server.connect(transport: respawning, backoffPolicy: .default)
        #expect(await server.state == .ready)

        // Simulate a scripted transport drop: sever the live connection
        // directly, bypassing MCPServer/MCP.Client entirely.
        await respawning.disconnect()

        let result = await server.call(toolNamed: "echo", arguments: ["text": "hello"])

        #expect(result.contains("Error"))
        #expect(await server.state == .ready)

        // The connection healed via auto-reconnect: a normal call
        // afterward, through the freshly-respawned session, succeeds
        // cleanly.
        let followUp = await server.call(toolNamed: "echo", arguments: ["text": "hello again"])
        #expect(followUp == "hello again")
    }

    @Test("call(toolNamed:arguments:) renders a normal successful result without touching state")
    func callSucceedsAndRendersNormally() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let scripted = ScriptedServer()
        await scripted.addEchoTool()
        try await scripted.start(transport: serverTransport)

        let server = MCPServer(client: makeClient())
        try await server.connect(transport: clientTransport)

        let result = await server.call(toolNamed: "echo", arguments: ["text": "hi there"])

        #expect(result == "hi there")
        #expect(await server.state == .ready)
    }
}
