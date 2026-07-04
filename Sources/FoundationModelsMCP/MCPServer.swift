import FoundationModels
import MCP

/// The readiness of an ``MCPServer``'s connection to its underlying MCP
/// server.
///
/// There is no separate "disconnected" or "idle" case: a freshly-constructed
/// ``MCPServer`` starts ``connecting`` (it exists to become connected), and
/// ``MCPServer/connect(transport:)`` resets to ``connecting`` at the start of
/// every attempt, including a reconnect after ``faulted(_:)`` or after an
/// explicit ``MCPServer/disconnect()``.
public enum MCPServerState: Sendable, Equatable {
    /// The `initialize` handshake and/or paginated `tools/list` discovery has
    /// not yet completed successfully.
    case connecting

    /// `initialize` succeeded and every `tools/list` page was fetched to
    /// exhaustion — ``MCPServer/mcpTools()`` and
    /// ``MCPServer/foundationModelsTools()`` are safe to call.
    case ready

    /// The most recent connection attempt failed — either the transport
    /// handshake or paginated discovery — carrying a human-readable
    /// description of the failure for diagnostics.
    ///
    /// Holds a `String` rather than the originating `Error` because
    /// arbitrary `Error` values are neither `Sendable` nor `Equatable`, and
    /// this state must be both to cross actor boundaries and to be asserted
    /// on directly in tests.
    case faulted(String)
}

/// A stable identifier for one MCP server connection, established once and
/// unaffected by later reconnects.
///
/// A server's self-reported `Server.Info.name` is not guaranteed to stay
/// constant across reconnects (the host might point the same logical
/// connection at a differently-configured or upgraded server instance), but
/// callers that key state by server identity — routing tables, tool caches,
/// UI labels — need that key to stay put across a reconnect. See
/// ``MCPServer/init(client:name:)`` for how the name is chosen.
public struct ServerIdentity: Sendable, Hashable {
    /// The stable name identifying this server connection.
    public let name: String
}

/// Errors thrown by ``MCPServer``'s own operations, distinct from whatever
/// the wrapped `MCP.Client` or its transport throws.
public enum MCPServerError: Error, Sendable, Equatable {
    /// A caller asked for discovered tools before ``MCPServer/state`` reached
    /// ``MCPServerState/ready``, carrying the actual state at the time of the
    /// call for diagnostics.
    case notReady(MCPServerState)
}

/// Owns one `MCP.Client` connection to a single MCP server: the async
/// `connect(transport:)` handshake, paginated `tools/list` discovery to
/// exhaustion, a `connecting`/`ready`/`faulted` readiness state machine, and
/// a stable ``ServerIdentity`` that survives reconnects.
///
/// `MCP.Client` is a concrete `actor` from the swift-sdk with its own
/// connection and request/response internals; `MCPServer` wraps it directly
/// — rather than through the narrower ``MCPToolCalling`` seam ``MCPTool``
/// depends on — because this actor owns the client's whole lifecycle
/// (connecting, discovering, reconnecting), not just forwarding individual
/// `tools/call` invocations the way `MCPTool` does. The caller remains
/// responsible for constructing the `Transport` (in-memory, stdio, HTTP, …)
/// passed to ``connect(transport:)``; `MCPServer` never constructs a
/// transport itself.
public actor MCPServer {
    /// The wrapped swift-sdk client this actor owns for its whole lifetime.
    private let client: MCP.Client

    /// The host-supplied server name, if the caller provided one at
    /// ``init(client:name:)`` — takes precedence over deriving ``identity``
    /// from the server's self-reported name.
    private let hostSuppliedName: String?

    /// The current readiness state.
    ///
    /// - SeeAlso: ``MCPServerState``
    public private(set) var state: MCPServerState = .connecting

    /// This server's stable identity, established once the first
    /// ``connect(transport:)`` call fully succeeds — handshake *and*
    /// discovery — and never recomputed afterward. `nil` until then, and
    /// still `nil` after a call that fails partway through (e.g. the
    /// handshake succeeds but discovery throws), so ``identity`` and
    /// ``state`` never disagree about whether a connection ever truly
    /// succeeded.
    public private(set) var identity: ServerIdentity?

    /// Every tool discovered by the most recent successful
    /// ``connect(transport:)``, in `tools/list` page order.
    private var discoveredTools: [MCPTool] = []

    /// Creates an actor that wraps `client` for its whole lifetime.
    ///
    /// - Parameters:
    ///   - client: The `MCP.Client` this actor owns. The caller constructs
    ///     it (with whatever `Client.Info`/`Capabilities` it needs) but must
    ///     not call `connect(transport:)` on it directly — that's
    ///     ``connect(transport:)``'s job.
    ///   - name: A host-supplied name to use as ``identity``, taking
    ///     precedence over the server's self-reported `Server.Info.name` at
    ///     `initialize`. Pass `nil` (the default) to derive ``identity``
    ///     from the server instead.
    public init(client: MCP.Client, name: String? = nil) {
        self.client = client
        self.hostSuppliedName = name
    }

    /// Connects `client` to `transport`, then discovers every tool the
    /// server serves via `tools/list`, paginating to exhaustion.
    ///
    /// Resets ``state`` to ``MCPServerState/connecting`` at the start of
    /// every attempt — including a reconnect on a fresh transport after a
    /// previous ``MCPServerState/faulted(_:)`` or after an explicit
    /// ``disconnect()`` — and advances it to ``MCPServerState/ready`` only
    /// once both the handshake and full discovery succeed. ``identity`` is
    /// established (see ``init(client:name:)``) only once this call fully
    /// succeeds, on the first such call, and is never recomputed by any
    /// later call. On any failure — whether the handshake itself or
    /// discovery afterward — ``state`` becomes ``MCPServerState/faulted(_:)``,
    /// ``identity`` is left exactly as it was (still `nil` if this was the
    /// first attempt), and the error is rethrown.
    ///
    /// - Parameter transport: The transport to connect over, constructed and
    ///   owned by the caller.
    /// - Throws: Whatever `MCP.Client.connect(transport:)` or
    ///   `MCP.Client.listTools(cursor:)` throws, or whatever
    ///   `MCPTool.init(tool:client:)` throws for a malformed `inputSchema`
    ///   encountered during discovery.
    public func connect(transport: any Transport) async throws {
        state = .connecting
        do {
            let initializeResult = try await client.connect(transport: transport)
            let tools = try await discoverAllTools()
            if identity == nil {
                identity = ServerIdentity(
                    name: hostSuppliedName ?? initializeResult.serverInfo.name)
            }
            discoveredTools = tools
            state = .ready
        } catch {
            state = .faulted(String(describing: error))
            throw error
        }
    }

    /// Disconnects the wrapped client without altering ``identity``.
    ///
    /// - Note: ``state`` is left as ``MCPServerState/ready`` (or whatever it
    ///   was); a subsequent ``connect(transport:)`` is what drives the next
    ///   state transition, not this call.
    public func disconnect() async {
        await client.disconnect()
    }

    /// The tools discovered by the most recent successful
    /// ``connect(transport:)``.
    ///
    /// - Returns: One ``MCPTool`` per tool the server declared, in
    ///   `tools/list` page order.
    /// - Throws: ``MCPServerError/notReady(_:)`` if ``state`` is not
    ///   ``MCPServerState/ready``.
    public func mcpTools() throws -> [MCPTool] {
        guard case .ready = state else {
            throw MCPServerError.notReady(state)
        }
        return discoveredTools
    }

    /// The same tools as ``mcpTools()``, type-erased to
    /// `FoundationModels.Tool` for direct use in a `LanguageModelSession`.
    ///
    /// - Returns: One `any FoundationModels.Tool` per discovered tool.
    /// - Throws: Whatever ``mcpTools()`` throws.
    public func foundationModelsTools() throws -> [any FoundationModels.Tool] {
        try mcpTools().map { $0 as any FoundationModels.Tool }
    }

    /// Fetches every `tools/list` page, following `nextCursor` until the
    /// server returns none, and maps each `MCP.Tool` into an ``MCPTool``.
    ///
    /// A one-page read silently truncates whenever the server paginates its
    /// `tools/list` response; this loop is what stands between callers and
    /// that truncation.
    ///
    /// - Returns: One ``MCPTool`` per tool across every page, in page order.
    /// - Throws: Whatever `MCP.Client.listTools(cursor:)` throws, or
    ///   whatever ``MCPTool/init(tool:client:)`` throws for a malformed
    ///   `inputSchema`.
    private func discoverAllTools() async throws -> [MCPTool] {
        var allTools: [MCP.Tool] = []
        var cursor: String?
        repeat {
            let page = try await client.listTools(cursor: cursor)
            allTools.append(contentsOf: page.tools)
            cursor = page.nextCursor
        } while cursor != nil
        return try allTools.map { try MCPTool(tool: $0, client: client) }
    }
}
