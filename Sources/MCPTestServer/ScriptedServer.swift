import Foundation
import MCP

/// A fully scriptable `MCP.Server` test double: register/mutate tools at
/// runtime, paginate `tools/list`, emit `notifications/tools/list_changed`
/// (including rapid bursts), script elicitation and progress mid-call, drop
/// the transport mid-call, and record inbound notifications (especially
/// `notifications/cancelled`) for test assertion.
///
/// `MCP.Server` is a concrete `actor` from the swift-sdk with a fixed
/// `withMethodHandler`/`onNotification` registration surface — it has no
/// built-in concept of "scripted scenarios." `ScriptedServer` wraps one
/// `Server` instance, owns the single `tools/list`/`tools/call` dispatch
/// pair backed by a mutable tool registry (``addTool(_:)``,
/// ``removeTool(named:)``, ``replaceTool(_:)``), and layers
/// scenario-specific factories on top of that registry —
/// ``addEchoTool(named:description:)``, filesystem tools (see
/// `FilesystemToolKit.swift`), ``addProgressReportingTool(named:totalSteps:stepDelay:)``,
/// ``addElicitingTool(named:message:requestedSchema:)``, and
/// ``addTransportDroppingTool(named:)`` — so tests can drive each scenario
/// from ordinary async test code against a real `MCP.Client`.
///
/// Test-fixture only: this target depends on the `MCP` swift-sdk product but
/// is never a dependency of the `FoundationModelsMCP` library target — see
/// `Tests/FoundationModelsMCPTests/PackageDependencyTests.swift`, which
/// asserts that from `Package.swift`'s source.
public actor ScriptedServer {
    /// The error message thrown when a method handler's weak `self` capture
    /// has already been deallocated — shared so every such guard reports the
    /// same wording.
    private static let deallocatedErrorMessage = "ScriptedServer deallocated"

    /// Runs `body` with the resolved, non-optional instance from a
    /// `[weak self]` capture, throwing ``deallocatedErrorMessage`` first if
    /// the server has already been deallocated — shared by every
    /// handler/tool-handler closure below that captures `self` weakly to
    /// avoid a retain cycle with the wrapped `MCP.Server`.
    ///
    /// (Swift only permits the `guard let self else { ... }`/`if let self`
    /// self-shadowing sugar as an optional-binding condition, not as a plain
    /// `let self = ...` assignment, so the resolved instance is threaded
    /// through as an ordinary parameter instead of rebound to `self`.)
    ///
    /// - Parameters:
    ///   - weakSelf: The closure's captured `self`, already an optional
    ///     courtesy of `[weak self]`.
    ///   - body: Runs with the resolved, non-optional server instance.
    /// - Returns: Whatever `body` returns.
    /// - Throws: `MCPError.internalError(deallocatedErrorMessage)` if
    ///   `weakSelf` is `nil`; otherwise whatever `body` throws.
    private static func withResolvedSelf<T>(
        _ weakSelf: ScriptedServer?,
        _ body: (ScriptedServer) async throws -> T
    ) async throws -> T {
        guard let weakSelf else {
            throw MCPError.internalError(deallocatedErrorMessage)
        }
        return try await body(weakSelf)
    }

    /// The wrapped swift-sdk server that actually speaks the MCP protocol.
    private let server: MCP.Server

    /// The transport the server was started with, retained so
    /// ``dropTransport()`` can sever the connection on command.
    private var transport: (any Transport)?

    /// The current tool registry, in registration order — the order
    /// `tools/list` pagination walks.
    private var tools: [ScriptedTool] = []

    /// The maximum number of tools returned per `tools/list` page, or `nil`
    /// to return every tool in a single page (no pagination).
    private let toolsPageSize: Int?

    /// Every inbound notification this server has observed, in receipt
    /// order. See ``RecordedNotification`` for what's captured today.
    public private(set) var recordedNotifications: [RecordedNotification] = []

    /// Creates a scripted server around a fresh `MCP.Server`.
    ///
    /// - Parameters:
    ///   - name: The MCP server name reported at `initialize`.
    ///   - version: The MCP server version reported at `initialize`.
    ///   - toolsPageSize: Maximum tools per `tools/list` page. `nil` (the
    ///     default) returns every registered tool in a single page.
    ///   - capabilities: The server capabilities to advertise. Defaults to
    ///     declaring `tools(listChanged: true)`, since
    ///     ``emitToolListChanged()`` and ``emitToolListChangedBurst(count:)``
    ///     exist to exercise it.
    public init(
        name: String = "ScriptedServer",
        version: String = "1.0.0",
        toolsPageSize: Int? = nil,
        capabilities: MCP.Server.Capabilities = .init(tools: .init(listChanged: true))
    ) {
        self.toolsPageSize = toolsPageSize
        self.server = MCP.Server(name: name, version: version, capabilities: capabilities)
    }

    // MARK: - Lifecycle

    /// Registers the `tools/list`, `tools/call`, and cancellation-recording
    /// handlers, then starts the wrapped server on `transport`.
    ///
    /// - Parameter transport: The transport to serve on — an
    ///   `InMemoryTransport` for in-process tests, or a `StdioTransport` when
    ///   spawned as a subprocess.
    /// - Throws: Whatever `MCP.Server.start(transport:)` throws.
    public func start(transport: any Transport) async throws {
        self.transport = transport
        await registerHandlers()
        try await server.start(transport: transport)
    }

    /// Blocks until the wrapped server's message loop finishes.
    ///
    /// Used by the `MCPTestServerCLI` executable wrapper to keep the process
    /// alive for the lifetime of a stdio connection.
    public func waitUntilCompleted() async {
        await server.waitUntilCompleted()
    }

    /// Forcibly disconnects the transport the server was started with,
    /// simulating a transport drop — on command from a test, or mid-call
    /// from within a tool handler (see ``addTransportDroppingTool(named:)``).
    ///
    /// Scenario 7, "transport drop mid-call on command."
    public func dropTransport() async {
        await transport?.disconnect()
    }

    private func registerHandlers() async {
        await server.withMethodHandler(ListTools.self) { [weak self] params in
            try await Self.withResolvedSelf(self) { instance in
                await instance.listToolsPage(cursor: params.cursor)
            }
        }

        await server.withMethodHandler(CallTool.self) { [weak self] params in
            try await Self.withResolvedSelf(self) { instance in
                try await instance.dispatchCallTool(params)
            }
        }

        await server.onNotification(CancelledNotification.self) { [weak self] message in
            guard let self else { return }
            await self.recordNotification(
                method: CancelledNotification.name,
                requestId: message.params.requestId,
                reason: message.params.reason
            )
        }
    }

    // MARK: - Tool registry (scenarios 1, 2, 5)

    /// Adds one tool to the registry, appended after any existing tools.
    ///
    /// If a tool with the same name is already registered, it is left in
    /// place and `tool` is appended as a duplicate entry; use
    /// ``replaceTool(_:)`` to update an existing tool's definition in place.
    ///
    /// - Parameter tool: The tool definition and handler to register.
    public func addTool(_ tool: ScriptedTool) {
        tools.append(tool)
    }

    /// Removes every registered tool with the given name.
    ///
    /// - Parameter name: The tool name to remove.
    public func removeTool(named name: String) {
        tools.removeAll { $0.definition.name == name }
    }

    /// Replaces the tool named `tool.definition.name` in place, or appends
    /// `tool` if no tool with that name is registered yet — the primitive
    /// behind "re-schema a tool on command."
    ///
    /// - Parameter tool: The replacement definition and handler.
    public func replaceTool(_ tool: ScriptedTool) {
        if let index = tools.firstIndex(where: { $0.definition.name == tool.definition.name }) {
            tools[index] = tool
        } else {
            tools.append(tool)
        }
    }

    /// Schedules a mutation (``addTool(_:)``, ``removeTool(named:)``,
    /// ``replaceTool(_:)``, or any combination) to run after `delay` — the
    /// "on a timer" half of scenario 5.
    ///
    /// - Parameters:
    ///   - delay: How long to wait before running `mutation`.
    ///   - mutation: The mutation to apply, given the live server instance.
    public func scheduleMutation(
        after delay: Duration,
        _ mutation: @escaping @Sendable (ScriptedServer) async -> Void
    ) {
        Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self else { return }
            await mutation(self)
        }
    }

    private func listToolsPage(cursor: String?) -> ListTools.Result {
        let startIndex = cursor.flatMap(Int.init) ?? 0
        guard startIndex >= 0, startIndex <= tools.count else {
            return ListTools.Result(tools: [])
        }
        guard let pageSize = toolsPageSize else {
            return ListTools.Result(tools: tools.map(\.definition))
        }
        let endIndex = min(startIndex + pageSize, tools.count)
        let page = tools[startIndex..<endIndex].map(\.definition)
        let nextCursor = endIndex < tools.count ? String(endIndex) : nil
        return ListTools.Result(tools: page, nextCursor: nextCursor)
    }

    private func dispatchCallTool(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let tool = tools.first(where: { $0.definition.name == params.name }) else {
            throw MCPError.invalidParams("Unknown tool: \(params.name)")
        }
        return try await tool.handler(params)
    }

    // MARK: - tools/list_changed (scenario 4)

    /// Sends one `notifications/tools/list_changed` notification.
    ///
    /// - Throws: Whatever `MCP.Server.notify(_:)` throws.
    public func emitToolListChanged() async throws {
        try await server.notify(ToolListChangedNotification.message())
    }

    /// Sends `count` `notifications/tools/list_changed` notifications back
    /// to back, with no delay between them — scripting a "rapid burst."
    ///
    /// - Parameter count: How many notifications to send.
    /// - Throws: Whatever the first failing ``emitToolListChanged()`` call
    ///   throws; the burst stops at that point.
    public func emitToolListChangedBurst(count: Int) async throws {
        for _ in 0..<count {
            try await emitToolListChanged()
        }
    }

    // MARK: - Progress (scenario 9)

    /// Registers a tool that reports `totalSteps` progress notifications,
    /// `stepDelay` apart, before returning — scripting "periodic
    /// `notifications/progress` during a long call."
    ///
    /// Only emits progress when the caller opted in via a `progressToken` in
    /// the call's `_meta`, matching the spec's opt-in contract; otherwise it
    /// just waits out the same total duration before returning.
    ///
    /// - Parameters:
    ///   - name: The tool's name.
    ///   - totalSteps: How many progress notifications to send.
    ///   - stepDelay: How long to wait between each notification.
    public func addProgressReportingTool(
        named name: String,
        totalSteps: Int,
        stepDelay: Duration
    ) {
        let definition = MCP.Tool(
            name: name,
            description: "Reports progress over \(totalSteps) steps before completing.",
            inputSchema: JSONSchemaBuilder.emptySchema
        )
        let handler: @Sendable (CallTool.Parameters) async throws -> CallTool.Result = {
            [weak self] params in
            try await Self.withResolvedSelf(self) { instance in
                if let token = params._meta?.progressToken {
                    for step in 1...totalSteps {
                        try await instance.server.notify(
                            ProgressNotification.message(
                                .init(
                                    progressToken: token, progress: Double(step),
                                    total: Double(totalSteps))))
                        try await Task.sleep(for: stepDelay)
                    }
                } else {
                    try await Task.sleep(for: stepDelay * totalSteps)
                }
                return CallTool.Result(content: [.text(text: "done", annotations: nil, _meta: nil)])
            }
        }
        addTool(ScriptedTool(definition: definition, handler: handler))
    }

    // MARK: - Elicitation (scenario 8)

    /// Registers a tool that elicits user input mid-call via
    /// `elicitation/create`, then reflects the elicitation result back in
    /// its own `tools/call` result — scripting a full elicit round-trip.
    ///
    /// - Parameters:
    ///   - name: The tool's name.
    ///   - message: The message shown to the user in the elicitation prompt.
    ///   - requestedSchema: The schema describing the elicited response.
    public func addElicitingTool(
        named name: String,
        message: String,
        requestedSchema: Elicitation.RequestSchema
    ) {
        let definition = MCP.Tool(
            name: name,
            description: "Elicits user input mid-call and echoes it back.",
            inputSchema: JSONSchemaBuilder.emptySchema
        )
        let handler: @Sendable (CallTool.Parameters) async throws -> CallTool.Result = {
            [weak self] _ in
            try await Self.withResolvedSelf(self) { instance in
                let result = try await instance.server.requestElicitation(
                    message: message, requestedSchema: requestedSchema)
                let structuredContent: Value? = result.content.map(Value.object)
                return CallTool.Result(
                    content: [
                        .text(
                            text: "elicitation \(result.action.rawValue)", annotations: nil,
                            _meta: nil)
                    ],
                    structuredContent: structuredContent
                )
            }
        }
        addTool(ScriptedTool(definition: definition, handler: handler))
    }

    // MARK: - Transport drop mid-call (scenario 7)

    /// Registers a tool that drops the transport connection as its first
    /// action, then never produces a `tools/call` response — scripting
    /// "transport drop mid-call" as something a client-visible tool call can
    /// trigger, not just something a test drives directly via
    /// ``dropTransport()``.
    ///
    /// - Parameter name: The tool's name.
    public func addTransportDroppingTool(named name: String) {
        let definition = MCP.Tool(
            name: name,
            description: "Drops the transport connection mid-call.",
            inputSchema: JSONSchemaBuilder.emptySchema
        )
        let handler: @Sendable (CallTool.Parameters) async throws -> CallTool.Result = {
            [weak self] _ in
            try await Self.withResolvedSelf(self) { instance in
                await instance.dropTransport()
                throw MCPError.connectionClosed
            }
        }
        addTool(ScriptedTool(definition: definition, handler: handler))
    }

    // MARK: - Recorded notifications (scenario 10)

    /// Appends one recorded notification.
    ///
    /// Not a trivial single-call-site wrapper despite the one-line body:
    /// `recordedNotifications` is a mutable actor-isolated stored property,
    /// and Swift only permits mutating actor-isolated state from inside an
    /// isolated method — a `[weak self]` notification closure (running
    /// off-actor) cannot append to it directly, even with `await`, the way
    /// it can read-then-call-async-method-on an actor-isolated `let` (see
    /// ``addProgressReportingTool(named:totalSteps:stepDelay:)``'s inlined
    /// `server.notify(...)` call). This method is the required isolation
    /// boundary, not an optional abstraction.
    ///
    /// - Parameters:
    ///   - method: The JSON-RPC notification method.
    ///   - requestId: The cancelled request's id, if the notification
    ///     carried one.
    ///   - reason: The human-readable cancellation reason, if the
    ///     notification carried one.
    private func recordNotification(method: String, requestId: ID?, reason: String?) {
        recordedNotifications.append(
            RecordedNotification(method: method, requestId: requestId, reason: reason))
    }

    /// Polls ``recordedNotifications`` until at least `count` have arrived,
    /// or `timeout` elapses.
    ///
    /// Notification recording is driven by the wrapped server's own
    /// message-handling task, so there's no synchronous signal a test can
    /// await directly — polling with a bounded timeout is the simplest
    /// correct way to observe it without an artificial fixed sleep.
    ///
    /// - Parameters:
    ///   - count: The minimum number of recorded notifications to wait for.
    ///   - timeout: The maximum time to wait.
    /// - Returns: ``recordedNotifications`` at the moment `count` was
    ///   reached, or at the moment `timeout` elapsed, whichever came first.
    public func waitForRecordedNotifications(
        count: Int, timeout: Duration
    ) async -> [RecordedNotification] {
        let deadline = ContinuousClock.now + timeout
        while recordedNotifications.count < count && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return recordedNotifications
    }
}

/// One inbound notification ``ScriptedServer`` observed from a connected
/// client, recorded for test assertion.
///
/// Only `notifications/cancelled` is wired up to append here today — that's
/// the one inbound notification the fixture's acceptance criteria calls out
/// by name, and the only one a scripted test double realistically needs to
/// observe right now. The shape generalizes cleanly: recording another
/// notification method later is a one-line `onNotification` registration
/// appending the same struct, not a redesign.
public struct RecordedNotification: Sendable, Equatable {
    /// The JSON-RPC notification method, e.g. `"notifications/cancelled"`.
    public let method: String
    /// The cancelled request's id, if the notification carried one.
    public let requestId: ID?
    /// The human-readable cancellation reason, if the notification carried
    /// one.
    public let reason: String?
}
