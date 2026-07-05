import MCP
import MCPTestServer
import Testing

import FoundationModelsMCP

/// A stub consumer of the M8 catalog surface, standing in for
/// `swissarmyhammer/FoundationModelsMultitool` (see `plan.md` → "Scaling to
/// many tools: out of scope — see FoundationModelsMultitool" and → M8).
///
/// Deliberately **not** `@testable import FoundationModelsMCP`: every other
/// suite in this test target imports the library under test to reach
/// internal fixtures, but this one exercises exactly the surface a real
/// external package sees — ``MCPServer/catalog``, ``MCPServer/catalogUpdates``,
/// ``ToolCatalog``/``ToolDescriptor``/``ServerIdentity``,
/// ``ToolCatalog/diff(from:)``, ``MCPServer/tool(named:)``, and
/// ``MCPServer/toolNoLongerAvailableResult(named:)`` — proving the frozen
/// contract genuinely compiles and behaves correctly from outside the
/// module, with no privileged access.
///
/// Drives one ``ScriptedServer`` through the exact sequence `plan.md`'s M8
/// milestone calls for: add a tool, remove a tool, then re-declare a
/// same-named tool with a different `inputSchema` — asserting the resulting
/// epochs, fingerprint changes, ``ToolCatalog/diff(from:)`` classification,
/// and the structured not-found behavior for call-time resolution of a tool
/// that vanished.
@Suite("StubConsumer")
struct StubConsumerTests {

    /// Builds a fresh `MCP.Client` for this suite's scenario test.
    private func makeClient() -> Client {
        Client(name: "StubConsumerTestClient", version: "1.0")
    }

    /// Records every ``ToolCatalog`` snapshot observed from
    /// ``MCPServer/catalogUpdates``, in emission order.
    ///
    /// A file-local re-implementation of the same "record and poll with a
    /// bounded timeout" shape ``LiveCatalogTests``'s own
    /// `CatalogSnapshotRecorder` uses — duplicated rather than shared because
    /// that one is `private` to `LiveCatalogTests` itself, and this suite
    /// otherwise has no dependency on that file.
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

    /// Creates a background task that appends every snapshot from `server`'s
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

    /// Builds a re-declared "beta" tool: same name as
    /// ``ScriptedServer/echoTool(named:description:)``'s default, but a
    /// structurally different `inputSchema` — a new required `urgent`
    /// boolean property in place of the original `text` string — scripting
    /// "the server re-declared this same-named tool with a different
    /// schema."
    ///
    /// - Returns: The replacement ``ScriptedTool``, still named `"beta"`.
    private func reschemadBetaTool() -> ScriptedTool {
        let schema = JSONSchemaBuilder.object(
            properties: ["urgent": JSONSchemaBuilder.string(description: "Urgency flag.")],
            required: ["urgent"]
        )
        let definition = MCP.Tool(
            name: "beta",
            description: "Echoes an urgency flag back verbatim.",
            inputSchema: schema
        )
        let handler: @Sendable (CallTool.Parameters) async throws -> CallTool.Result = { params in
            let urgent = params.arguments?["urgent"]?.boolValue ?? false
            return CallTool.Result(content: [.text(text: "urgent: \(urgent)", annotations: nil, _meta: nil)])
        }
        return ScriptedTool(definition: definition, handler: handler)
    }

    @Test(
        "stub consumer observes exact epochs, fingerprints, diffs, and not-found behavior across add, remove, and same-name schema change"
    )
    func observesAddRemoveSchemaChangeSequence() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let scripted = ScriptedServer(name: "stub-consumer-server")
        await scripted.addEchoTool(named: "alpha")
        try await scripted.start(transport: serverTransport)

        let clock = ManualClock()
        let server = MCPServer(client: makeClient(), clock: clock)
        try await server.connect(transport: clientTransport)

        let (recorder, task) = await recordCatalogUpdates(from: server)
        defer { task.cancel() }

        // Initial connect: epoch 1, only "alpha" present.
        let afterConnect = await recorder.wait(forCount: 1, timeout: .seconds(2))
        #expect(afterConnect.count == 1)
        #expect(afterConnect[0].epoch == 1)
        #expect(Set(afterConnect[0].tools.map(\.name)) == Set(["alpha"]))

        // Step 1 — add: a new "beta" tool joins the catalog.
        await scripted.addTool(ScriptedServer.echoTool(named: "beta"))
        try await scripted.emitToolListChangedBurst(count: 3)
        let afterAdd = await recorder.wait(forCount: 2, timeout: .seconds(2))
        #expect(afterAdd.count == 2)
        #expect(afterAdd[1].epoch == 2)

        let addDiff = afterAdd[1].diff(from: afterAdd[0])
        #expect(addDiff.added.map(\.name) == ["beta"])
        #expect(addDiff.removed.isEmpty)
        #expect(addDiff.changed.isEmpty)

        // Step 2 — remove: "alpha" leaves the catalog.
        await scripted.removeTool(named: "alpha")
        try await scripted.emitToolListChangedBurst(count: 3)
        let afterRemove = await recorder.wait(forCount: 3, timeout: .seconds(2))
        #expect(afterRemove.count == 3)
        #expect(afterRemove[2].epoch == 3)

        let removeDiff = afterRemove[2].diff(from: afterRemove[1])
        #expect(removeDiff.removed.map(\.name) == ["alpha"])
        #expect(removeDiff.added.isEmpty)
        #expect(removeDiff.changed.isEmpty)

        // Step 3 — same-name schema change: "beta" is re-declared with a
        // different inputSchema, same name.
        let betaBeforeReschema = try #require(afterRemove[2].tools.first { $0.name == "beta" })

        await scripted.replaceTool(reschemadBetaTool())
        try await scripted.emitToolListChangedBurst(count: 3)
        let afterReschema = await recorder.wait(forCount: 4, timeout: .seconds(2))
        #expect(afterReschema.count == 4)
        #expect(afterReschema[3].epoch == 4)

        let reschemaDiff = afterReschema[3].diff(from: afterReschema[2])
        #expect(reschemaDiff.changed.map(\.after.name) == ["beta"])
        #expect(reschemaDiff.added.isEmpty)
        #expect(reschemaDiff.removed.isEmpty)

        let changedBeta = try #require(reschemaDiff.changed.first)
        #expect(changedBeta.before.name == "beta")
        #expect(changedBeta.after.name == "beta")
        #expect(changedBeta.before.fingerprint == betaBeforeReschema.fingerprint)
        #expect(changedBeta.before.fingerprint != changedBeta.after.fingerprint)

        // Structured not-found behavior: "alpha" was removed, so call-time
        // resolution against the current catalog now yields nil, and the
        // rendered not-available result names it explicitly.
        let resolvedAlpha = await server.tool(named: "alpha")
        #expect(resolvedAlpha == nil)

        let notAvailableText = MCPServer.toolNoLongerAvailableResult(named: "alpha")
        #expect(notAvailableText.contains("alpha"))
        #expect(notAvailableText.contains("no longer available"))
        #expect(notAvailableText.contains("Error"))

        // "beta" is still resolvable — it changed schema, it wasn't removed.
        let resolvedBeta = await server.tool(named: "beta")
        #expect(resolvedBeta?.name == "beta")

        // The final catalog snapshot is self-contained: a consumer starting
        // fresh from it alone sees exactly "beta", with no prior state.
        #expect(Set(afterReschema[3].tools.map(\.name)) == Set(["beta"]))
    }
}
