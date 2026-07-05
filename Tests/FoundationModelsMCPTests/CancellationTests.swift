import Foundation
import Testing

@testable import FoundationModelsMCP
import MCP
import MCPTestServer

/// Coverage for ``MCPServer``'s protocol-level cancellation, per-call
/// timeout, and progress surfacing — the M5/Lifecycle "Cancellation,
/// progress, health" policy in `plan.md`.
///
/// Three concerns, three groups of tests:
/// - **Wire-level cancellation**: cancelling the Swift `Task` running
///   ``MCPServer/call(toolNamed:arguments:timeout:)`` must send a protocol
///   `notifications/cancelled` — the swift-sdk does not do this
///   automatically on `Task` cancellation (see `docs/swift-sdk-notes.md`),
///   so ``MCPServer`` sends it explicitly via
///   `MCP.Client.cancelRequest(_:reason:)`.
/// - **Per-call timeout**: a call with no progress times out at the
///   configured bound; the same call with periodic progress does not. Both
///   use a real clock with small real durations rather than ``ManualClock``:
///   ``MCPServer/call(toolNamed:arguments:timeout:)``'s timeout-enforcement
///   loop deliberately measures real wall-clock time
///   (`MCPServer/resultOrTimeout(toolName:context:progressToken:timeout:)`),
///   never the injectable `clock` used elsewhere (backoff, coalescing) —
///   because ``ManualClock/sleep(until:tolerance:)`` never actually
///   suspends (see ``CallDeadline``'s doc comment), so it would make the
///   timeout side of the race always "win" instantly against a call that's
///   genuinely in flight, breaking any test that happens to inject a
///   ``ManualClock`` for an unrelated reason. The pure "did a reset happen"
///   arithmetic behind the loop is covered separately, with no concurrency
///   or clock at all, by the ``CallDeadline`` tests below.
/// - **Progress surfacing**: every scripted `notifications/progress` update
///   for an in-flight call is observable by the host via
///   ``MCPServer/progressUpdates``.
@Suite("Cancellation")
struct CancellationTests {

    /// Builds a fresh `MCP.Client` for a test, named after the test itself
    /// only for readability in transport-level logs.
    private func makeClient() -> Client {
        Client(name: "CancellationTestClient", version: "1.0")
    }

    /// Records every ``CallProgress`` update observed from a server's
    /// ``MCPServer/progressUpdates`` stream, in receipt order — the same
    /// "record and poll with a bounded timeout" shape as
    /// ``LiveCatalogTests``'s `CatalogSnapshotRecorder`.
    private actor ProgressRecorder {
        private(set) var updates: [CallProgress] = []

        func append(_ update: CallProgress) {
            updates.append(update)
        }

        /// Polls until at least the specified count of updates have been
        /// recorded, or until the timeout elapses.
        ///
        /// - Parameters:
        ///   - count: The minimum number of updates to wait for.
        ///   - timeout: The maximum time to wait.
        /// - Returns: ``updates`` at the moment `count` was reached, or at
        ///   the moment `timeout` elapsed, whichever came first.
        func wait(forCount count: Int, timeout: Duration) async -> [CallProgress] {
            let deadline = ContinuousClock.now + timeout
            while updates.count < count && ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(5))
            }
            return updates
        }
    }

    /// Registers a tool that never sends progress and never returns within
    /// any test-relevant timeframe — the "no progress at all" fixture for
    /// the per-call timeout tests, distinct from
    /// ``ScriptedServer/addProgressReportingTool(named:totalSteps:stepDelay:)``,
    /// which always emits progress once a caller supplies a progress token
    /// (which ``MCPServer/call(toolNamed:arguments:timeout:)`` always does).
    private func addHangingTool(named name: String, to scripted: ScriptedServer) async {
        await scripted.addTool(
            ScriptedTool(
                definition: MCP.Tool(
                    name: name, description: "Never responds.", inputSchema: JSONSchemaBuilder.emptySchema),
                handler: { _ in
                    try await Task.sleep(for: .seconds(60))
                    return CallTool.Result(content: [.text(text: "done", annotations: nil, _meta: nil)])
                }
            ))
    }

    // MARK: - Wire-level cancellation

    @Test("cancelling the Swift Task around call() sends a notifications/cancelled the scripted server records")
    func swiftTaskCancellationSendsCancelledNotification() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let scripted = ScriptedServer()
        await scripted.addProgressReportingTool(named: "slow", totalSteps: 50, stepDelay: .milliseconds(20))
        try await scripted.start(transport: serverTransport)

        let server = MCPServer(client: makeClient())
        try await server.connect(transport: clientTransport)

        let callTask = Task {
            await server.call(toolNamed: "slow", arguments: nil)
        }

        // Give the call time to actually reach the server before cancelling
        // it, so there's a genuine in-flight request to cancel.
        try await Task.sleep(for: .milliseconds(60))
        callTask.cancel()
        let result = await callTask.value

        let recorded = await scripted.waitForRecordedNotifications(count: 1, timeout: .seconds(2))
        #expect(recorded.count == 1)
        #expect(recorded.first?.method == CancelledNotification.name)
        #expect(result.contains("Error"))
    }

    // MARK: - Per-call timeout

    @Test("a call with no progress times out at the configured bound")
    func callWithNoProgressTimesOut() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let scripted = ScriptedServer()
        await addHangingTool(named: "hangs", to: scripted)
        try await scripted.start(transport: serverTransport)

        let server = MCPServer(client: makeClient())
        try await server.connect(transport: clientTransport)

        let result = await server.call(toolNamed: "hangs", arguments: nil, timeout: .milliseconds(30))

        #expect(result.contains("Error"))
        #expect(result.contains("timed out"))
    }

    @Test("a call with periodic scripted progress does not time out despite exceeding a single timeout window")
    func callWithPeriodicProgressDoesNotTimeOut() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let scripted = ScriptedServer()
        await scripted.addProgressReportingTool(named: "slow", totalSteps: 6, stepDelay: .milliseconds(15))
        try await scripted.start(transport: serverTransport)

        let server = MCPServer(client: makeClient())
        try await server.connect(transport: clientTransport)

        // Total tool duration (~90ms across 6 steps) exceeds the 30ms
        // timeout, but progress arrives every 15ms — well within the
        // timeout window — so the call must complete successfully instead
        // of timing out.
        let result = await server.call(toolNamed: "slow", arguments: nil, timeout: .milliseconds(30))

        #expect(result == "done")
    }

    // MARK: - Progress surfaced to the host

    @Test("the host observes each scripted progress event via progressUpdates")
    func hostObservesEachScriptedProgressEvent() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let scripted = ScriptedServer()
        await scripted.addProgressReportingTool(named: "slow", totalSteps: 4, stepDelay: .milliseconds(10))
        try await scripted.start(transport: serverTransport)

        let server = MCPServer(client: makeClient())
        try await server.connect(transport: clientTransport)

        let recorder = ProgressRecorder()
        let stream = await server.progressUpdates
        let recordingTask = Task {
            for await update in stream {
                await recorder.append(update)
            }
        }
        defer { recordingTask.cancel() }

        let result = await server.call(toolNamed: "slow", arguments: nil)
        #expect(result == "done")

        let updates = await recorder.wait(forCount: 4, timeout: .seconds(2))
        #expect(updates.count == 4)
        #expect(updates.map(\.progress) == [1, 2, 3, 4])
        #expect(updates.allSatisfy { $0.toolName == "slow" })
        #expect(updates.allSatisfy { $0.total == 4 })
    }

    // MARK: - CallDeadline: pure reset/expiry logic, no concurrency

    @Test("a fresh CallDeadline starts with resetCount 0")
    func freshCallDeadlineHasZeroResetCount() {
        let deadline = CallDeadline(timeout: .seconds(5))
        #expect(deadline.resetCount == 0)
        #expect(deadline.timeout == .seconds(5))
    }

    @Test("resetForProgress increments resetCount on every call")
    func resetForProgressIncrementsResetCount() {
        var deadline = CallDeadline(timeout: .seconds(5))
        deadline.resetForProgress()
        #expect(deadline.resetCount == 1)
        deadline.resetForProgress()
        deadline.resetForProgress()
        #expect(deadline.resetCount == 3)
    }
}
