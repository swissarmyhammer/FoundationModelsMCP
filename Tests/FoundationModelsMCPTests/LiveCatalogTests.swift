import Foundation
import Testing

@testable import FoundationModelsMCP
import MCP
import MCPTestServer

/// Coverage for the dynamic half of ``MCPServer``'s catalog: the
/// ``MCPServer/catalogUpdates`` stream, coalescing a burst of
/// `tools/list_changed` notifications into a single re-list, an implicit
/// re-list on reconnect, and ``MCPServer/tool(named:)`` resolving against
/// the current catalog.
///
/// Every test drives its own ``ManualClock`` instead of a real
/// `ContinuousClock`, so the coalescing window in
/// ``MCPServer/coalesceAndRelist()`` is exercised with no real sleeps —
/// mirroring ``ResilienceTests``'s own convention.
@Suite("LiveCatalog")
struct LiveCatalogTests {

    /// Builds a fresh `MCP.Client` for one test, named after the test itself
    /// only for readability in transport-level logs.
    private func makeClient() -> Client {
        Client(name: "LiveCatalogTestClient", version: "1.0")
    }

    /// Collects every ``ToolCatalog`` snapshot observed from an
    /// ``MCPServer/catalogUpdates`` stream, in emission order — the same
    /// "record and poll with a bounded timeout" shape as
    /// ``ScriptedServerSelfTests``'s own `NotificationCounter`/`ProgressRecorder`.
    private actor CatalogSnapshotRecorder {
        private(set) var snapshots: [ToolCatalog] = []

        func append(_ snapshot: ToolCatalog) {
            snapshots.append(snapshot)
        }

        /// Polls until at least `count` snapshots have been recorded, or
        /// `timeout` elapses.
        ///
        /// - Parameters:
        ///   - count: The minimum number of snapshots to wait for.
        ///   - timeout: The maximum time to wait.
        /// - Returns: ``snapshots`` at the moment `count` was reached, or at
        ///   the moment `timeout` elapsed, whichever came first.
        func wait(forCount count: Int, timeout: Duration) async -> [ToolCatalog] {
            let deadline = ContinuousClock.now + timeout
            while snapshots.count < count && ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(5))
            }
            return snapshots
        }
    }

    /// Starts a background task that appends every snapshot from `server`'s
    /// ``MCPServer/catalogUpdates`` to a fresh ``CatalogSnapshotRecorder``.
    ///
    /// - Parameter server: The server to subscribe to.
    /// - Returns: The recorder, and the collecting task (cancel it once the
    ///   test no longer needs to observe further emissions).
    private func recordCatalogUpdates(from server: MCPServer) async -> (
        recorder: CatalogSnapshotRecorder, task: Task<Void, Never>
    ) {
        let recorder = CatalogSnapshotRecorder()
        let stream = await server.catalogUpdates
        let task = Task {
            for await snapshot in stream {
                await recorder.append(snapshot)
            }
        }
        return (recorder, task)
    }

    // MARK: - Coalescing

    @Test("5 rapid scripted tools/list_changed notifications produce exactly 1 re-list and 1 new snapshot")
    func coalescesRapidBurstIntoOneRelist() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let scripted = ScriptedServer()
        await scripted.addEchoTool(named: "echo")
        try await scripted.start(transport: serverTransport)

        let clock = ManualClock()
        let server = MCPServer(client: makeClient(), clock: clock)
        try await server.connect(transport: clientTransport)

        let (recorder, task) = await recordCatalogUpdates(from: server)
        defer { task.cancel() }

        // Wait for the initial connect's own snapshot (epoch 1) before
        // triggering the burst, so the assertions below only count
        // snapshots produced by the burst itself.
        let afterConnect = await recorder.wait(forCount: 1, timeout: .seconds(2))
        #expect(afterConnect.count == 1)
        #expect(afterConnect[0].epoch == 1)

        // Mutate the scripted server's tool set so the eventual re-list is
        // observably different from the initial discovery.
        await scripted.addTool(ScriptedServer.echoTool(named: "search"))

        try await scripted.emitToolListChangedBurst(count: 5)

        let afterBurst = await recorder.wait(forCount: 2, timeout: .seconds(2))
        // A short additional bounded wait proves no *further* emissions
        // arrive — i.e. the burst really did coalesce into one re-list,
        // not five.
        try await Task.sleep(for: .milliseconds(200))
        let finalSnapshots = await recorder.snapshots

        #expect(afterBurst.count == 2)
        #expect(finalSnapshots.count == 2)
        #expect(finalSnapshots[1].epoch == 2)
        #expect(Set(finalSnapshots[1].tools.map(\.name)) == Set(["echo", "search"]))
    }

    // MARK: - Epoch monotonicity

    @Test("epochs strictly increase across a connect, a coalesced re-list, and a reconnect, and every snapshot is complete")
    func epochsStrictlyIncreaseAcrossEmissions() async throws {
        let (clientTransport1, serverTransport1) = await InMemoryTransport.createConnectedPair()
        let firstScripted = ScriptedServer(name: "live-catalog-server")
        await firstScripted.addEchoTool(named: "echo")
        try await firstScripted.start(transport: serverTransport1)

        let clock = ManualClock()
        let server = MCPServer(client: makeClient(), clock: clock)
        try await server.connect(transport: clientTransport1)

        let (recorder, task) = await recordCatalogUpdates(from: server)
        defer { task.cancel() }

        _ = await recorder.wait(forCount: 1, timeout: .seconds(2))

        // A coalesced re-list.
        await firstScripted.addTool(ScriptedServer.echoTool(named: "search"))
        try await firstScripted.emitToolListChangedBurst(count: 3)
        _ = await recorder.wait(forCount: 2, timeout: .seconds(2))

        // A reconnect to a differently-tooled server, same MCPServer actor —
        // an implicit re-list ("the returning server may differ").
        let (clientTransport2, serverTransport2) = await InMemoryTransport.createConnectedPair()
        let secondScripted = ScriptedServer(name: "live-catalog-server")
        await secondScripted.addEchoTool(named: "echo")
        await secondScripted.addTool(ScriptedServer.echoTool(named: "search"))
        await secondScripted.addTool(ScriptedServer.echoTool(named: "archive"))
        try await secondScripted.start(transport: serverTransport2)

        try await server.connect(transport: clientTransport2)
        let afterReconnect = await recorder.wait(forCount: 3, timeout: .seconds(2))

        #expect(afterReconnect.count == 3)
        let epochs = afterReconnect.map(\.epoch)
        #expect(epochs == epochs.sorted())
        #expect(Set(epochs).count == epochs.count)

        // Every snapshot is complete/idempotent: a consumer can read the
        // full current tool set from any one snapshot alone.
        #expect(Set(afterReconnect[0].tools.map(\.name)) == Set(["echo"]))
        #expect(Set(afterReconnect[1].tools.map(\.name)) == Set(["echo", "search"]))
        #expect(Set(afterReconnect[2].tools.map(\.name)) == Set(["echo", "search", "archive"]))
    }

    // MARK: - Reconnect implies re-list

    @Test("reconnecting to a server with a different tool set emits a new snapshot reflecting the returning server's tools")
    func reconnectEmitsSnapshotReflectingReturningServer() async throws {
        let (clientTransport1, serverTransport1) = await InMemoryTransport.createConnectedPair()
        let firstScripted = ScriptedServer(name: "live-catalog-server")
        await firstScripted.addEchoTool(named: "echo")
        try await firstScripted.start(transport: serverTransport1)

        let server = MCPServer(client: makeClient())
        try await server.connect(transport: clientTransport1)

        let (recorder, task) = await recordCatalogUpdates(from: server)
        defer { task.cancel() }
        let beforeReconnect = await recorder.wait(forCount: 1, timeout: .seconds(2))
        #expect(beforeReconnect[0].epoch == 1)

        await server.disconnect()

        let (clientTransport2, serverTransport2) = await InMemoryTransport.createConnectedPair()
        let secondScripted = ScriptedServer(name: "live-catalog-server")
        await secondScripted.addEchoTool(named: "echo")
        await secondScripted.addTool(ScriptedServer.echoTool(named: "search"))
        try await secondScripted.start(transport: serverTransport2)

        try await server.connect(transport: clientTransport2)

        let afterReconnect = await recorder.wait(forCount: 2, timeout: .seconds(2))
        #expect(afterReconnect.count == 2)
        #expect(afterReconnect[1].epoch > afterReconnect[0].epoch)
        #expect(Set(afterReconnect[1].tools.map(\.name)) == Set(["echo", "search"]))

        // Identity stays stable across the reconnect even though the tool
        // set changed — the returning server is still "the same server"
        // per ``ServerIdentity``'s own contract.
        #expect(afterReconnect[0].identity == afterReconnect[1].identity)
    }

    // MARK: - Readiness-state changes

    @Test("a reconnect attempt that fails after a prior successful connect emits a snapshot with state == .faulted")
    func failedReconnectEmitsFaultedSnapshot() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let scripted = ScriptedServer()
        await scripted.addEchoTool(named: "echo")
        try await scripted.start(transport: serverTransport)

        let server = MCPServer(client: makeClient())
        try await server.connect(transport: clientTransport)

        let (recorder, task) = await recordCatalogUpdates(from: server)
        defer { task.cancel() }
        let beforeReconnect = await recorder.wait(forCount: 1, timeout: .seconds(2))
        #expect(beforeReconnect.count == 1)
        #expect(beforeReconnect[0].epoch == 1)
        #expect(beforeReconnect[0].state == .ready)

        let flaky = FlakyConnectTransport(wrapping: clientTransport, failingConnectAttempts: 1)
        await #expect(throws: (any Error).self) {
            try await server.connect(transport: flaky)
        }

        let afterFailedReconnect = await recorder.wait(forCount: 2, timeout: .seconds(2))
        #expect(afterFailedReconnect.count == 2)
        #expect(afterFailedReconnect[1].epoch > afterFailedReconnect[0].epoch)
        guard case .faulted = afterFailedReconnect[1].state else {
            Issue.record("Expected the second snapshot's state to be .faulted after the failed reconnect")
            return
        }
    }

    @Test("a mid-call transport fault emits a faulted snapshot, then a ready snapshot once auto-reconnect heals it")
    func midCallFaultEmitsFaultedThenReadySnapshots() async throws {
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

        let (recorder, task) = await recordCatalogUpdates(from: server)
        defer { task.cancel() }
        let beforeFault = await recorder.wait(forCount: 1, timeout: .seconds(2))
        #expect(beforeFault.count == 1)
        #expect(beforeFault[0].epoch == 1)
        #expect(beforeFault[0].state == .ready)

        // Sever the live connection directly, bypassing MCPServer/MCP.Client
        // entirely — the same scripted-transport-drop technique
        // ``ResilienceTests`` uses.
        await respawning.disconnect()
        let result = await server.call(toolNamed: "echo", arguments: ["text": "hello"])
        #expect(result.contains("Error"))

        let afterFaultAndReconnect = await recorder.wait(forCount: 3, timeout: .seconds(2))
        #expect(afterFaultAndReconnect.count == 3)

        guard case .faulted = afterFaultAndReconnect[1].state else {
            Issue.record("Expected the second snapshot's state to be .faulted (the mid-call fault)")
            return
        }
        #expect(afterFaultAndReconnect[2].state == .ready)

        let epochs = afterFaultAndReconnect.map(\.epoch)
        #expect(epochs == epochs.sorted())
        #expect(Set(epochs).count == epochs.count)
    }

    // MARK: - tool(named:) resolution

    @Test("tool(named:) returns nil once a tool is removed and re-listed, and the not-available helper renders it")
    func toolResolutionReturnsNilAfterScriptedRemoval() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let scripted = ScriptedServer()
        await scripted.addEchoTool(named: "echo")
        try await scripted.start(transport: serverTransport)

        let clock = ManualClock()
        let server = MCPServer(client: makeClient(), clock: clock)
        try await server.connect(transport: clientTransport)

        let (recorder, task) = await recordCatalogUpdates(from: server)
        defer { task.cancel() }
        _ = await recorder.wait(forCount: 1, timeout: .seconds(2))

        let resolvedBeforeRemoval = await server.tool(named: "echo")
        #expect(resolvedBeforeRemoval?.name == "echo")

        await scripted.removeTool(named: "echo")
        try await scripted.emitToolListChangedBurst(count: 5)
        _ = await recorder.wait(forCount: 2, timeout: .seconds(2))

        let resolvedAfterRemoval = await server.tool(named: "echo")
        #expect(resolvedAfterRemoval == nil)

        let notAvailableText = MCPServer.toolNoLongerAvailableResult(named: "echo")
        #expect(notAvailableText.contains("echo"))
        #expect(notAvailableText.contains("no longer available"))
        #expect(notAvailableText.contains("Error"))
    }
}
