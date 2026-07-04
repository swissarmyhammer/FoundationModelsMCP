import Foundation
import Testing

import MCP
import MCPTestServer

/// Self-tests proving ``ScriptedServer``'s scripting actually works — one
/// test per scenario 3 through 10 from the fixture's task, each driving the
/// scenario from an ordinary `MCP.Client` connected over an in-memory
/// transport pair and observing the scripted behavior.
///
/// Scenarios 1 (echo tool) and 2 (filesystem-style multi-tool mode) aren't
/// covered here — the task only requires self-tests for scenarios 3–10 — but
/// ``ScriptedServer/echoTool(named:description:)`` is reused below as a
/// convenient way to generate distinct fixture tools for the pagination test.
@Suite("ScriptedServerSelf")
struct ScriptedServerSelfTests {

    /// A minimal, actor-isolated counter used to await an expected number of
    /// client-observed notifications without a fixed sleep — the server's
    /// notification delivery and the client's message-handling loop run on
    /// separate tasks, so tests poll for the expected count instead of
    /// racing a guessed delay.
    private actor NotificationCounter {
        private(set) var count = 0

        func increment() {
            count += 1
        }

        /// Polls until `count` reaches `target` or `timeout` elapses.
        ///
        /// - Parameters:
        ///   - target: The count to wait for.
        ///   - timeout: The maximum time to wait.
        /// - Returns: `count` at the moment `target` was reached, or at the
        ///   moment `timeout` elapsed, whichever came first.
        func wait(forCount target: Int, timeout: Duration) async -> Int {
            let deadline = ContinuousClock.now + timeout
            while count < target && ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(5))
            }
            return count
        }
    }

    /// Records every `notifications/progress` payload a client observes, in
    /// receipt order, for the progress-cadence self-test.
    private actor ProgressRecorder {
        private(set) var updates: [ProgressNotification.Parameters] = []

        func record(_ update: ProgressNotification.Parameters) {
            updates.append(update)
        }
    }

    /// Polls `condition` until it returns `true` or `timeout` elapses.
    ///
    /// Used wherever a test needs to observe an effect that's delivered
    /// asynchronously (a scheduled mutation landing, a notification
    /// arriving) — a bounded poll is robust to scheduling variance under
    /// load, unlike a fixed `Task.sleep` guess.
    ///
    /// - Parameters:
    ///   - timeout: The maximum time to wait.
    ///   - condition: Checked repeatedly until it returns `true`.
    private func poll(timeout: Duration, until condition: () async -> Bool) async {
        let deadline = ContinuousClock.now + timeout
        while await !condition() && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    // MARK: - Scenario 3: tools/list pagination

    @Test("tools/list pagination returns exactly the expected number of pages")
    func toolsListPaginationPageCount() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let scripted = ScriptedServer(toolsPageSize: 2)
        for index in 0..<5 {
            await scripted.addTool(ScriptedServer.echoTool(named: "tool-\(index)"))
        }
        try await scripted.start(transport: serverTransport)

        let client = Client(name: "ScriptedServerSelfTestClient", version: "1.0")
        _ = try await client.connect(transport: clientTransport)

        var collectedNames: [String] = []
        var cursor: String?
        var pageCount = 0
        repeat {
            let page = try await client.listTools(cursor: cursor)
            collectedNames.append(contentsOf: page.tools.map(\.name))
            cursor = page.nextCursor
            pageCount += 1
        } while cursor != nil

        #expect(pageCount == 3)
        #expect(collectedNames.count == 5)
    }

    // MARK: - Scenario 4: tools/list_changed bursts

    @Test("emitToolListChangedBurst sends exactly the scripted number of notifications")
    func toolListChangedBurstEmission() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let scripted = ScriptedServer()
        try await scripted.start(transport: serverTransport)

        let client = Client(name: "ScriptedServerSelfTestClient", version: "1.0")
        _ = try await client.connect(transport: clientTransport)

        let counter = NotificationCounter()
        await client.onNotification(ToolListChangedNotification.self) { _ in
            await counter.increment()
        }

        try await scripted.emitToolListChangedBurst(count: 7)

        let observed = await counter.wait(forCount: 7, timeout: .seconds(2))
        #expect(observed == 7)
    }

    // MARK: - Scenario 5: add/remove/re-schema on command or timer

    @Test("tools can be added, removed, re-schema'd on command, and added on a timer")
    func toolMutationOnCommandAndTimer() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let scripted = ScriptedServer()
        await scripted.addTool(ScriptedServer.echoTool(named: "alpha"))
        try await scripted.start(transport: serverTransport)

        let client = Client(name: "ScriptedServerSelfTestClient", version: "1.0")
        _ = try await client.connect(transport: clientTransport)

        var page = try await client.listTools()
        #expect(page.tools.map(\.name) == ["alpha"])

        await scripted.addTool(ScriptedServer.echoTool(named: "beta"))
        page = try await client.listTools()
        #expect(Set(page.tools.map(\.name)) == ["alpha", "beta"])

        await scripted.removeTool(named: "alpha")
        page = try await client.listTools()
        #expect(page.tools.map(\.name) == ["beta"])

        let reschemaed = MCP.Tool(
            name: "beta",
            description: "updated description",
            inputSchema: JSONSchemaBuilder.object(properties: [:])
        )
        await scripted.replaceTool(
            ScriptedTool(definition: reschemaed, handler: { params in
                CallTool.Result(content: [.text(text: "beta", annotations: nil, _meta: nil)])
            })
        )
        page = try await client.listTools()
        #expect(page.tools.first?.description == "updated description")

        await scripted.scheduleMutation(after: .milliseconds(20)) { server in
            await server.addTool(ScriptedServer.echoTool(named: "gamma"))
        }
        await poll(timeout: .seconds(2)) {
            (try? await client.listTools().tools.map(\.name).contains("gamma")) ?? false
        }
        page = try await client.listTools()
        #expect(page.tools.map(\.name).contains("gamma"))
    }

    // MARK: - Scenario 6: fail-N-times-then-succeed connects

    @Test("FlakyConnectTransport fails the scripted number of connect attempts, then succeeds")
    func connectFailureCountdown() async throws {
        let (clientTransport, _) = await InMemoryTransport.createConnectedPair()
        let flaky = FlakyConnectTransport(wrapping: clientTransport, failingConnectAttempts: 2)

        await #expect(throws: MCPError.self) {
            try await flaky.connect()
        }
        await #expect(throws: MCPError.self) {
            try await flaky.connect()
        }
        try await flaky.connect()

        let attempts = await flaky.connectAttempts
        #expect(attempts == 3)
    }

    // MARK: - Scenario 7: transport drop mid-call

    @Test("dropping the transport mid-call leaves the in-flight call unanswered")
    func transportDropMidCall() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let scripted = ScriptedServer()
        await scripted.addTransportDroppingTool(named: "drop")
        try await scripted.start(transport: serverTransport)

        let client = Client(name: "ScriptedServerSelfTestClient", version: "1.0")
        _ = try await client.connect(transport: clientTransport)

        let callTask = Task {
            try await client.callTool(name: "drop")
        }

        // Give the call time to reach the server and trigger the drop.
        try await Task.sleep(for: .milliseconds(150))

        // Disconnecting resolves any request still genuinely pending with a
        // "Client disconnected" error. If the drop hadn't actually prevented
        // a response, `callTask` would already hold a successful result and
        // this `#expect(throws:)` would fail.
        await client.disconnect()

        await #expect(throws: (any Error).self) {
            _ = try await callTask.value
        }
    }

    // MARK: - Scenario 8: elicit mid-call

    @Test("a tool that elicits mid-call round-trips the client's scripted response")
    func elicitRoundTrip() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let scripted = ScriptedServer()
        await scripted.addElicitingTool(
            named: "ask",
            message: "What is the answer?",
            requestedSchema: Elicitation.RequestSchema(
                properties: ["answer": .object(["type": .string("string")])],
                required: ["answer"]
            )
        )
        try await scripted.start(transport: serverTransport)

        let client = Client(
            name: "ScriptedServerSelfTestClient",
            version: "1.0",
            capabilities: Client.Capabilities(elicitation: .init())
        )
        _ = try await client.connect(transport: clientTransport)

        await client.withElicitationHandler { params in
            guard case .form(let formParams) = params else {
                return CreateElicitation.Result(action: .decline)
            }
            #expect(formParams.message == "What is the answer?")
            return CreateElicitation.Result(action: .accept, content: ["answer": .string("42")])
        }

        let context = try await client.send(CallTool.request(.init(name: "ask")))
        let result = try await context.value

        #expect(result.content.contains { content in
            if case .text(let text, _, _) = content {
                return text.contains("accept")
            }
            return false
        })
        #expect(result.structuredContent?.objectValue?["answer"]?.stringValue == "42")
    }

    // MARK: - Scenario 9: periodic progress notifications

    @Test("a long call reports progress at the scripted cadence")
    func progressCadence() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let scripted = ScriptedServer()
        await scripted.addProgressReportingTool(
            named: "slow", totalSteps: 4, stepDelay: .milliseconds(10))
        try await scripted.start(transport: serverTransport)

        let client = Client(name: "ScriptedServerSelfTestClient", version: "1.0")
        _ = try await client.connect(transport: clientTransport)

        let recorder = ProgressRecorder()
        await client.onNotification(ProgressNotification.self) { message in
            await recorder.record(message.params)
        }

        let meta = Metadata(progressToken: .string("progress-token"))
        _ = try await client.callTool(name: "slow", arguments: nil, meta: meta)

        // The tool's response only guarantees the server has sent the last
        // progress notification, not that the client's message loop has
        // processed it yet — poll for the expected count instead of racing
        // a fixed delay.
        await poll(timeout: .seconds(2)) {
            await recorder.updates.count >= 4
        }

        let updates = await recorder.updates
        #expect(updates.count == 4)
        #expect(updates.map(\.progress) == [1, 2, 3, 4])
        #expect(updates.allSatisfy { $0.total == 4 })
    }

    // MARK: - Scenario 10: recording inbound notifications (cancelled)

    @Test("a cancelled notification is recorded for test assertion")
    func cancelledNotificationRecording() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let scripted = ScriptedServer()
        await scripted.addProgressReportingTool(
            named: "slow", totalSteps: 20, stepDelay: .milliseconds(20))
        try await scripted.start(transport: serverTransport)

        let client = Client(name: "ScriptedServerSelfTestClient", version: "1.0")
        _ = try await client.connect(transport: clientTransport)

        let context = try await client.send(CallTool.request(.init(name: "slow")))
        try await Task.sleep(for: .milliseconds(50))
        try await client.cancelRequest(context.requestID, reason: "self-test cancel")

        let recorded = await scripted.waitForRecordedNotifications(count: 1, timeout: .seconds(2))
        #expect(recorded.count == 1)
        #expect(recorded.first?.method == CancelledNotification.name)
        #expect(recorded.first?.reason == "self-test cancel")
    }
}
