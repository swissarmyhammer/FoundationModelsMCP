import struct Foundation.Data
import Logging
import MCP
import MCPTestServer

/// A `Transport` wrapper whose ``connect()`` always builds a brand-new
/// (client transport, ``ScriptedServer``) pair via `makePair` and delegates
/// to it — simulating a transport that respawns/redials on every connect
/// attempt, the way a real stdio (subprocess) or HTTP (session) transport
/// would on a genuine reconnect.
///
/// This is deliberately different from ``FlakyConnectTransport``: reusing
/// the very same `MCP.Server`/`MCP.Client` pair across a reconnect doesn't
/// work against a *real* SDK server, since `Server`'s `Initialize` handler
/// rejects a second `initialize` on an already-initialized session
/// (`MCPError.invalidRequest("Server is already initialized")` — see
/// `Server.swift`'s `checkInitialized()`/`Initialize` method handler). A
/// genuine reconnect is a new session from the server's perspective, so
/// this double models that directly: every ``connect()`` call gets its own
/// fresh, never-initialized ``ScriptedServer``.
///
/// ``disconnect()`` severs the *current* pair's connection — a test calls
/// it directly (bypassing ``MCPServer``/`MCP.Client` entirely) to simulate
/// "a scripted transport drop": a call already in flight through the dead
/// transport fails immediately (no hang, since the underlying
/// `InMemoryTransport.send(_:)` throws once disconnected), and the next
/// ``connect()`` — ``MCPServer``'s own auto-reconnect — swaps in a fresh
/// pair.
///
/// Like ``FlakyConnectTransport``, `receive()`'s non-`async` requirement
/// means the active pair's receive stream must be cached during
/// ``connect()`` rather than fetched lazily inside ``receive()`` itself.
actor RespawningTransport: Transport {
    private let makePair: @Sendable () async throws -> (client: any Transport, server: ScriptedServer)
    private var current: (any Transport)?
    private var currentReceiveStream: AsyncThrowingStream<Data, Swift.Error>?

    /// The active pair's `ScriptedServer`, retained only so it isn't
    /// deallocated out from under its own in-flight handlers — never read
    /// back, since callers only ever interact with the server through
    /// `current`'s wire protocol.
    private var currentServer: ScriptedServer?

    nonisolated let logger: Logger

    /// Creates a respawning transport.
    ///
    /// - Parameters:
    ///   - logger: The logger to report transport-related events to.
    ///     Defaults to a no-op logger, matching every other transport
    ///     double in this fixture set.
    ///   - makePair: Builds and starts a fresh (client transport,
    ///     `ScriptedServer`) pair, called once per ``connect()`` call
    ///     (including reconnects).
    init(
        logger: Logger? = nil,
        makePair: @escaping @Sendable () async throws -> (client: any Transport, server: ScriptedServer)
    ) {
        self.makePair = makePair
        self.logger =
            logger
            ?? Logger(
                label: "mcp.transport.respawning",
                factory: { _ in SwiftLogNoOpLogHandler() }
            )
    }

    /// Builds a fresh pair via `makePair`, connects to it, and caches its
    /// receive stream — every call, including reconnects, discards
    /// whatever pair was active before.
    ///
    /// - Throws: Whatever `makePair` or the fresh client transport's
    ///   `connect()` throws.
    func connect() async throws {
        let (client, server) = try await makePair()
        try await client.connect()
        current = client
        currentServer = server
        currentReceiveStream = await client.receive()
    }

    /// Severs the currently active pair's connection.
    ///
    /// Called directly by a test (not routed through `MCP.Client`) to
    /// simulate a scripted transport drop; also the ordinary `Transport`
    /// disconnect path when a caller disconnects the owning `MCP.Client`.
    func disconnect() async {
        await current?.disconnect()
    }

    /// Delegates to the currently active pair's `send(_:)`.
    ///
    /// - Parameter data: The raw bytes to send.
    /// - Throws: `MCPError.internalError` if no pair has connected yet;
    ///   otherwise whatever the active pair's `send(_:)` throws (including
    ///   a "not connected" error once ``disconnect()`` has severed it).
    func send(_ data: Data) async throws {
        guard let current else {
            throw MCPError.internalError("RespawningTransport not connected")
        }
        try await current.send(data)
    }

    /// Returns the active pair's receive stream, cached by the most recent
    /// ``connect()``.
    ///
    /// - Returns: The cached stream, or an already-finished empty stream if
    ///   called before any ``connect()``.
    func receive() -> AsyncThrowingStream<Data, Swift.Error> {
        guard let currentReceiveStream else {
            return AsyncThrowingStream { $0.finish() }
        }
        return currentReceiveStream
    }
}
