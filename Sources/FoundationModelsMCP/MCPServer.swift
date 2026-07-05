import FoundationModels
import Logging
import MCP
import Synchronization

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
/// ``MCPServer/init(client:name:elicitationCoordinator:clock:defaultCallTimeout:logger:)`` for how the name is chosen.
public struct ServerIdentity: Sendable, Hashable {
    /// The stable name identifying this server connection.
    public let name: String
}

/// Configuration for ``MCPServer``'s connect-retry and auto-reconnect
/// backoff — see ``MCPServer/connect(transport:backoffPolicy:)`` and
/// ``MCPServer/call(toolNamed:arguments:timeout:)``.
///
/// Per `plan.md`'s Lifecycle policy: a failed/timed-out connect attempt is
/// retried with exponential backoff — ``baseDelay`` after the first
/// failure, doubling after every failure thereafter, capped at
/// ``maxDelay`` — up to ``maxAttempts`` total attempts, each bounded by
/// ``connectTimeout``; the caller hard-fails only once every attempt has
/// been exhausted. Every ``MCPServer`` auto-reconnects with the same
/// policy it last connected with — it's connection hygiene, not a mode.
public struct BackoffPolicy: Sendable, Equatable {
    /// The maximum wall-clock time a single connect attempt (handshake plus
    /// full paginated discovery) may take before it is abandoned in favor
    /// of the next retry. Defaults to 10 seconds.
    public var connectTimeout: Duration

    /// The delay before the second attempt; every attempt after that
    /// doubles the previous delay, capped at ``maxDelay`` — see
    /// ``MCPServer/connect(transport:backoffPolicy:)`` for the exact
    /// schedule. Defaults to 250 milliseconds.
    public var baseDelay: Duration

    /// The maximum delay between attempts, regardless of how many attempts
    /// have already failed. Defaults to 30 seconds.
    public var maxDelay: Duration

    /// The maximum number of connect attempts before hard-failing with
    /// ``MCPServerError/backoffExhausted(serverName:attempts:lastError:)``.
    /// Defaults to 5.
    public var maxAttempts: Int

    /// Creates a backoff policy.
    ///
    /// - Parameters:
    ///   - connectTimeout: The per-attempt timeout. Defaults to 10 seconds.
    ///   - baseDelay: The delay before the second attempt. Defaults to 250
    ///     milliseconds.
    ///   - maxDelay: The delay cap. Defaults to 30 seconds.
    ///   - maxAttempts: The maximum number of attempts. Defaults to 5.
    public init(
        connectTimeout: Duration = .seconds(10),
        baseDelay: Duration = .milliseconds(250),
        maxDelay: Duration = .seconds(30),
        maxAttempts: Int = 5
    ) {
        self.connectTimeout = connectTimeout
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.maxAttempts = maxAttempts
    }

    /// The default policy: a 10-second per-attempt timeout with a 250
    /// millisecond initial backoff.
    ///
    /// Backoff doubles after each failure up to a 30-second cap, with 5
    /// attempts maximum.
    public static let `default` = BackoffPolicy()
}

/// Errors thrown by ``MCPServer``'s own operations, distinct from whatever
/// the wrapped `MCP.Client` or its transport throws.
public enum MCPServerError: Error, Sendable, Equatable {
    /// A caller asked for discovered tools before ``MCPServer/state`` reached
    /// ``MCPServerState/ready``, carrying the actual state at the time of the
    /// call for diagnostics.
    case notReady(MCPServerState)

    /// Every attempt in a ``MCPServer/connect(transport:backoffPolicy:)``
    /// call failed — carries the server's identity (its established
    /// ``ServerIdentity/name`` if one exists, otherwise a best-effort
    /// display name), how many attempts were made, and a human-readable
    /// description of the last underlying failure.
    case backoffExhausted(serverName: String, attempts: Int, lastError: String)

    /// One single-attempt ``MCPServer/connect(transport:)`` call, within
    /// ``MCPServer/connect(transport:backoffPolicy:)``'s retry loop,
    /// exceeded its ``BackoffPolicy/connectTimeout``.
    case connectAttemptTimedOut

    /// A ``MCPServer/call(toolNamed:arguments:timeout:)`` exceeded its
    /// per-call timeout with no `notifications/progress` for it arriving in
    /// time to reset the deadline — carries the tool's name for
    /// diagnostics.
    case callTimedOut(toolName: String)
}

/// One `notifications/progress` update ``MCPServer`` surfaces to the host on
/// ``MCPServer/progressUpdates``, enriched with the name of the tool the
/// progress belongs to.
///
/// The wire notification itself only carries the opaque `ProgressToken`
/// ``MCPServer/call(toolNamed:arguments:timeout:)`` generated for the call —
/// this type pairs that update with the tool name the host actually cares
/// about, since ``MCPServer`` alone knows which call a token belongs to.
public struct CallProgress: Sendable, Equatable {
    /// The name of the tool this progress update belongs to.
    public let toolName: String

    /// The current progress value, per `notifications/progress`. Should
    /// increase monotonically as the call proceeds.
    public let progress: Double

    /// The total expected progress value, if the server provided one.
    public let total: Double?

    /// A human-readable message describing the current progress, if the
    /// server provided one.
    public let message: String?
}

/// Bookkeeping ``MCPServer`` tracks for one in-flight
/// ``MCPServer/call(toolNamed:arguments:timeout:)``, keyed by its generated
/// `ProgressToken` in ``MCPServer/activeCalls``.
///
/// - SeeAlso: ``CallDeadline`` for the resettable-timeout arithmetic
///   ``deadline`` wraps.
private struct ActiveCall {
    /// The name of the tool this call invoked — the wire
    /// `notifications/progress` only carries the opaque `ProgressToken`,
    /// not the tool name ``CallProgress`` reports to the host.
    let toolName: String

    /// This call's resettable timeout deadline, reset by every
    /// `notifications/progress` for it (see
    /// ``MCPServer/handleProgressNotification(parameters:)``).
    var deadline: CallDeadline
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
    /// The structured-logging metadata key naming the server a log message
    /// concerns — every ``logger`` call in this type keys
    /// ``identityNameForDiagnostics`` under this constant, so the key name
    /// stays consistent (and changeable in one place) across every call
    /// site instead of being repeated as a string literal.
    private static let serverMetadataKey = "server"

    /// The structured-logging metadata key naming the error a log message
    /// concerns — every ``logger`` call in this type that logs a caught
    /// error keys its `String(describing:)` under this constant, so the key
    /// name stays consistent (and changeable in one place) across every call
    /// site instead of being repeated as a string literal.
    private static let errorMetadataKey = "error"

    /// The wrapped swift-sdk client this actor owns for its whole lifetime.
    private let client: MCP.Client

    /// The host-supplied server name, if the caller provided one at
    /// ``init(client:name:)`` — takes precedence over deriving ``identity``
    /// from the server's self-reported name.
    private let hostSuppliedName: String?

    /// The host-owned coordinator server-initiated `elicitation/create`
    /// requests are routed to, or `nil` (the default) to never declare the
    /// elicitation client capability and never register a handler for it at
    /// all — a server that tries to elicit against a connection configured
    /// this way gets the SDK's own capability-declaration error, exactly as
    /// if this actor didn't exist.
    ///
    /// - SeeAlso: ``ElicitationCoordinator``, and `docs/swift-sdk-notes.md`'s
    ///   "Elicitation surface" section.
    private let elicitationCoordinator: (any ElicitationCoordinator)?

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

    /// The tools discovered by the most recent successful
    /// ``connect(transport:)`` call.
    ///
    /// Stored in `tools/list` page order.
    private var discoveredTools: [MCPTool] = []

    /// Incremented by every `emitCatalogSnapshot()` call — the per-server
    /// generation number ``catalog``'s snapshot exposes as
    /// ``ToolCatalog/epoch``. Starts at `0` (before any successful connect)
    /// and is never reset for the life of this actor.
    private var catalogEpoch = 0

    /// The stream of versioned ``ToolCatalog`` snapshots this server emits.
    ///
    /// See `emitCatalogSnapshot()` for every point that yields to it: a
    /// successful connect/reconnect, a failed reconnect, a mid-call
    /// transport fault, and a coalesced `tools/list_changed` re-list (see
    /// `coalesceAndRelist()`).
    ///
    /// Every emission is a complete, self-contained snapshot a consumer can
    /// start from with no prior state — never a delta — per `plan.md`'s
    /// Dynamic discovery decision. No emission occurs before the first
    /// successful connect, since ``identity`` (required to construct a
    /// ``ToolCatalog``) has not yet been established.
    ///
    /// - Important: Backed by a single continuation, like any `AsyncStream`:
    ///   only one concurrent consumer should iterate this stream at a time —
    ///   a second concurrent iterator would only ever see whichever
    ///   snapshots the first one hasn't already consumed, never a copy of
    ///   every snapshot.
    public let catalogUpdates: AsyncStream<ToolCatalog>

    /// The continuation `emitCatalogSnapshot()` yields new snapshots to —
    /// paired with ``catalogUpdates`` once, at construction time.
    private let catalogContinuation: AsyncStream<ToolCatalog>.Continuation

    /// The stream of ``CallProgress`` updates this server surfaces to the
    /// host, one per inbound `notifications/progress` for any currently
    /// in-flight ``call(toolNamed:arguments:timeout:)``.
    ///
    /// - Important: Backed by a single continuation, like ``catalogUpdates``:
    ///   only one concurrent consumer should iterate this stream at a time.
    public let progressUpdates: AsyncStream<CallProgress>

    /// The continuation `handleProgressNotification(parameters:)` yields new
    /// updates to — paired with ``progressUpdates`` once, at construction
    /// time.
    private let progressContinuation: AsyncStream<CallProgress>.Continuation

    /// The default timeout ``call(toolNamed:arguments:timeout:)`` uses when
    /// its own `timeout` parameter is `nil` — the host-configurable default
    /// per `plan.md`'s Lifecycle policy.
    private let defaultCallTimeout: Duration

    /// Bookkeeping for every ``call(toolNamed:arguments:timeout:)`` current
    /// in flight, keyed by the `ProgressToken` that call generated —
    /// looked up by `handleProgressNotification(parameters:)` to reset the right
    /// call's timeout deadline and to attribute a ``CallProgress`` update to
    /// its tool name.
    private var activeCalls: [ProgressToken: ActiveCall] = [:]

    /// Whether ``registerProgressHandler()`` has already run for this actor
    /// — guards against re-registering on every reconnect, the same reason
    /// ``hasRegisteredToolListChangedHandler`` does for
    /// ``registerToolListChangedHandler()``.
    private var hasRegisteredProgressHandler = false

    /// Whether ``registerToolListChangedHandler()`` has already run for this
    /// actor — guards against re-registering on every reconnect, since
    /// `MCP.Client.onNotification(_:handler:)` appends a new handler to its
    /// list rather than replacing it (unlike `withMethodHandler`, whose
    /// per-method single-handler map is genuinely idempotent to re-register
    /// on every attempt).
    private var hasRegisteredToolListChangedHandler = false

    /// The generation `coalesceAndRelist()` polls to detect whether
    /// another `tools/list_changed` notification arrived during its most
    /// recent coalescing window — advanced by every call to
    /// ``handleToolListChangedNotification()``, never reset.
    private var toolListChangedGeneration = 0

    /// Whether a `coalesceAndRelist()` task is already watching the
    /// current burst for quiet — guards
    /// ``handleToolListChangedNotification()`` against starting a second,
    /// redundant watcher while one is already running.
    private var isCoalescingToolListChanged = false

    /// The task ``handleToolListChangedNotification()`` starts to run
    /// `coalesceAndRelist()`, or `nil` when no coalescing watcher is
    /// currently running.
    ///
    /// Stored rather than left as a bare, unstored `Task { }` so this actor
    /// holds a structured handle to its own background work instead of
    /// leaking an unstructured task — cleared back to `nil` by
    /// `coalesceAndRelist()` itself once it finishes. Nothing currently
    /// needs to cancel it early, since ``isCoalescingToolListChanged``
    /// already guards against starting a second one while it runs.
    private var coalescingTask: Task<Void, Never>?

    /// How long a burst of `tools/list_changed` notifications must go quiet
    /// before `coalesceAndRelist()` performs the actual re-list — measured
    /// on `clock`, so a virtual clock in tests exercises the full
    /// coalescing window with no real delay.
    private static let toolListChangedCoalesceWindow: Duration = .milliseconds(50)

    /// The clock ``connect(transport:backoffPolicy:)`` sleeps on between
    /// retry attempts — injectable so tests can substitute a virtual clock
    /// (e.g. a manual/fake clock) instead of waiting out a real backoff
    /// schedule.
    private let clock: any Clock<Duration>

    /// Structured logger this actor reports every retry, reconnect, and
    /// mid-call fault to.
    private let logger: Logger

    /// The transport passed to the most recent ``connect(transport:)``
    /// call (successful or not), retained so a later mid-call transport
    /// fault (see ``call(toolNamed:arguments:timeout:)``) can auto-reconnect
    /// without the caller supplying a transport again.
    ///
    /// - Important: Auto-reconnect re-invokes `connect()` on this **very
    ///   same transport instance** — `MCPServer` never constructs a new
    ///   one (see the type-level doc). A transport that just wraps an
    ///   already-severed connection (a dead socket, a closed pipe to a
    ///   crashed subprocess) will simply fail `connect()` again, safely
    ///   but uselessly; healing a real connection this way requires the
    ///   caller's own `Transport` implementation to redial/respawn inside
    ///   its `connect()` method (the way `RespawningTransport` does in
    ///   this package's own tests), not something `MCPServer` provides for
    ///   free.
    private var lastTransport: (any Transport)?

    /// Incremented at the start of every attempt ``applyConnect(transport:generation:)``
    /// makes (whether from ``connect(transport:)`` directly or from
    /// `performConnectAttempt(transport:timeout:)`'s backoff retry loop),
    /// and captured by that attempt as the generation it must still match
    /// before mutating ``state``/``identity``/`discoveredTools` — see
    /// `performConnectAttempt(transport:timeout:)` for why an abandoned,
    /// still-running attempt can otherwise resolve long after the retry
    /// loop has moved on.
    private var connectGeneration = 0

    /// The backoff policy ``connect(transport:backoffPolicy:)`` was last
    /// called with, reused by ``call(toolNamed:arguments:timeout:)`` when
    /// auto-reconnecting after a mid-call fault — "auto-reconnect with the
    /// same policy" per `plan.md`'s Lifecycle policy. A server that never
    /// calls the backoff-retrying ``connect(transport:backoffPolicy:)``
    /// (only the single-attempt ``connect(transport:)``) auto-reconnects
    /// with ``BackoffPolicy/default``.
    private var activeBackoffPolicy: BackoffPolicy = .default

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
    ///   - elicitationCoordinator: The host-owned coordinator server-initiated
    ///     `elicitation/create` requests are routed to. Passing `nil` (the
    ///     default) means this connection never declares the elicitation
    ///     client capability and never registers a handler for it.
    ///   - clock: The clock ``connect(transport:backoffPolicy:)`` sleeps on
    ///     between retries, and `coalesceAndRelist()` sleeps on for its
    ///     coalescing window. Defaults to a real `ContinuousClock`; tests
    ///     substitute a virtual clock to exercise a full backoff schedule or
    ///     coalescing window without any real delay.
    ///
    ///     Never used by ``call(toolNamed:arguments:timeout:)``'s own
    ///     timeout-enforcement loop, which always measures real wall-clock
    ///     time (`Task.sleep(for:)`) instead — the same reason
    ///     `performConnectAttempt(transport:timeout:)`'s per-attempt
    ///     timeout does: a virtual clock that never actually suspends (like
    ///     `ManualClock` in this package's own tests) would make the
    ///     timeout side of that race always "win" instantly against a call
    ///     that's actually in flight, for every test that happens to inject
    ///     one for an unrelated reason (e.g. exercising backoff). See
    ///     `Tests/FoundationModelsMCPTests/CancellationTests.swift`.
    ///   - defaultCallTimeout: The default per-call timeout
    ///     ``call(toolNamed:arguments:timeout:)`` uses when its own
    ///     `timeout` parameter is `nil`. Defaults to 30 seconds.
    ///   - logger: The structured logger every retry, reconnect, and
    ///     mid-call fault is reported to. Defaults to a logger labeled
    ///     `"com.foundationmodelsmcp.mcpserver"`.
    public init(
        client: MCP.Client,
        name: String? = nil,
        elicitationCoordinator: (any ElicitationCoordinator)? = nil,
        clock: any Clock<Duration> = ContinuousClock(),
        defaultCallTimeout: Duration = .seconds(30),
        logger: Logger = Logger(label: "com.foundationmodelsmcp.mcpserver")
    ) {
        self.client = client
        self.hostSuppliedName = name
        self.elicitationCoordinator = elicitationCoordinator
        self.clock = clock
        self.defaultCallTimeout = defaultCallTimeout
        self.logger = logger

        var catalogContinuation: AsyncStream<ToolCatalog>.Continuation!
        self.catalogUpdates = AsyncStream { continuation in
            catalogContinuation = continuation
        }
        self.catalogContinuation = catalogContinuation

        var progressContinuation: AsyncStream<CallProgress>.Continuation!
        self.progressUpdates = AsyncStream { continuation in
            progressContinuation = continuation
        }
        self.progressContinuation = progressContinuation
    }

    /// Connects `client` to `transport`, then discovers every tool the
    /// server serves via `tools/list`, paginating to exhaustion.
    ///
    /// Resets ``state`` to ``MCPServerState/connecting`` at the start of
    /// every attempt — including a reconnect on a fresh transport after a
    /// previous ``MCPServerState/faulted(_:)`` or after an explicit
    /// ``disconnect()`` — and advances it to ``MCPServerState/ready`` only
    /// once both the handshake and full discovery succeed. ``identity`` is
    /// established (see ``init(client:name:elicitationCoordinator:clock:defaultCallTimeout:logger:)``) only once this call fully
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
        // `MCP.Client.connect(transport:)` never cancels a previous call's
        // still-running message-handling task before starting a new one —
        // calling it again on an already-connected client (a reconnect)
        // without disconnecting first leaves two tasks racing to consume
        // the same transport receive stream, which crashes
        // ("attempt to await next() on more than one task"). `disconnect()`
        // is a safe no-op before any connection has ever been made.
        await client.disconnect()
        connectGeneration += 1
        try await applyConnect(transport: transport, generation: connectGeneration)
    }

    /// Disconnects the wrapped client without altering ``identity``.
    ///
    /// - Note: ``state`` is left as ``MCPServerState/ready`` (or whatever it
    ///   was); a subsequent ``connect(transport:)`` is what drives the next
    ///   state transition, not this call.
    public func disconnect() async {
        await client.disconnect()
    }

    /// Connects with automatic retry using exponential backoff up to the
    /// maximum number of attempts.
    ///
    /// Attempts ``connect(transport:)`` up to `backoffPolicy.maxAttempts`
    /// times, each bounded by `backoffPolicy.connectTimeout`, sleeping on
    /// `clock` for an exponentially increasing delay (see
    /// ``BackoffPolicy``) between failed attempts. Hard-fails only once
    /// every attempt is exhausted.
    ///
    /// Records `backoffPolicy` as `activeBackoffPolicy` up front, so a
    /// later mid-call transport fault (see ``call(toolNamed:arguments:timeout:)``)
    /// auto-reconnects using this same policy — "auto-reconnect with the
    /// same policy" per `plan.md`'s Lifecycle policy. Every retry, and the
    /// final exhaustion if it happens, is logged.
    ///
    /// - Parameters:
    ///   - transport: The transport to connect over, constructed and owned
    ///     by the caller; forwarded to ``connect(transport:)`` on every
    ///     attempt, which retains it as `lastTransport`.
    ///   - backoffPolicy: The retry policy governing the per-attempt
    ///     timeout, delay schedule, and maximum attempts.
    /// - Throws: ``MCPServerError/backoffExhausted(serverName:attempts:lastError:)``
    ///   once every attempt has failed — never the raw underlying error of
    ///   the last attempt directly.
    public func connect(transport: any Transport, backoffPolicy: BackoffPolicy) async throws {
        activeBackoffPolicy = backoffPolicy
        var lastError: any Error = MCPServerError.notReady(.connecting)

        for attempt in 1...backoffPolicy.maxAttempts {
            do {
                try await performConnectAttempt(transport: transport, timeout: backoffPolicy.connectTimeout)
                logger.info(
                    "MCPServer connected",
                    metadata: [Self.serverMetadataKey: "\(identityNameForDiagnostics)", "attempt": "\(attempt)"])
                return
            } catch {
                lastError = error
                logger.warning(
                    "MCPServer connect attempt failed",
                    metadata: [
                        Self.serverMetadataKey: "\(identityNameForDiagnostics)",
                        "attempt": "\(attempt)",
                        "maxAttempts": "\(backoffPolicy.maxAttempts)",
                        Self.errorMetadataKey: "\(error)",
                    ])
                guard attempt < backoffPolicy.maxAttempts else { break }
                let delay = Self.backoffDelay(afterAttempt: attempt, policy: backoffPolicy)
                logger.info(
                    "MCPServer backing off before next connect retry",
                    metadata: [Self.serverMetadataKey: "\(identityNameForDiagnostics)", "delay": "\(delay)"])
                try await clock.sleep(for: delay)
            }
        }

        // The final attempt may still be running in the background (it lost
        // the `performConnectAttempt(transport:timeout:)` race against its
        // own `connectTimeout` rather than having actually finished) — bump
        // ``connectGeneration`` here too, not just on a *newer* connect call,
        // so that attempt's eventual, arbitrarily-late resolution is discarded
        // by ``applyConnect(transport:generation:)`` instead of mutating
        // ``state``/``identity``/`discoveredTools` after the caller has
        // already received and acted on ``MCPServerError/backoffExhausted(serverName:attempts:lastError:)``.
        connectGeneration += 1

        let exhausted = MCPServerError.backoffExhausted(
            serverName: identityNameForDiagnostics,
            attempts: backoffPolicy.maxAttempts,
            lastError: String(describing: lastError)
        )
        logger.error(
            "MCPServer connect backoff exhausted",
            metadata: [Self.serverMetadataKey: "\(identityNameForDiagnostics)", "attempts": "\(backoffPolicy.maxAttempts)"])
        throw exhausted
    }

    /// Calls a tool and renders the result for the model.
    ///
    /// Attaches a fresh `ProgressToken` to the call's `_meta` so incoming
    /// `notifications/progress` for it can be routed to ``progressUpdates``
    /// and reset its timeout (see `handleProgressNotification(parameters:)`), races
    /// the call's own response against a resettable `timeout` (defaulting to
    /// `defaultCallTimeout`), and cooperates with Swift `Task`
    /// cancellation: cancelling the `Task` this call runs in sends a
    /// protocol-level `notifications/cancelled` for it, via
    /// `MCP.Client.cancelRequest(_:reason:)` — the swift-sdk does not do
    /// this automatically on `Task` cancellation (see
    /// `docs/swift-sdk-notes.md`), so this method sends it explicitly
    /// instead of leaving orphaned work running on the server.
    ///
    /// Maps a mid-call transport fault to an `isError`-style rendered result
    /// (via ``ToolContentRenderer``) instead of throwing or hanging, and
    /// auto-reconnects with `activeBackoffPolicy` as a side effect — so the
    /// model can react to *this* call's failure while the connection heals
    /// for the next one. A timeout or a cancelled `Task` also render their
    /// own `isError`-style result but, unlike a transport fault, never touch
    /// ``state`` or trigger a reconnect — the connection itself is fine in
    /// both cases, only this one call was aborted.
    ///
    /// Never throws: every failure mode becomes rendered `isError` content,
    /// exactly like a server-reported `isError` result already is (see
    /// `MCPTool/call(arguments:)`).
    ///
    /// - Parameters:
    ///   - name: The name of the tool to call.
    ///   - arguments: Arguments to use for the tool call.
    ///   - timeout: The maximum time this call may run before it is treated
    ///     as timed out, reset by every `notifications/progress` received
    ///     for it. Defaults to `defaultCallTimeout`.
    /// - Returns: The rendered `tools/call` result on success, or a rendered
    ///   `isError` result describing a transport fault, a timeout, or a
    ///   Swift `Task` cancellation.
    public func call(
        toolNamed name: String, arguments: [String: Value]? = nil, timeout: Duration? = nil
    ) async -> String {
        let progressToken = ProgressToken.unique()
        let effectiveTimeout = timeout ?? defaultCallTimeout
        // Registered before the request is even sent, not after, so a
        // same-actor-turn progress notification arriving on an
        // ultra-low-latency transport can never be dropped for lacking a
        // matching ``activeCalls`` entry yet.
        activeCalls[progressToken] = ActiveCall(toolName: name, deadline: CallDeadline(timeout: effectiveTimeout))
        defer { activeCalls[progressToken] = nil }

        do {
            let context: RequestContext<CallTool.Result> = try await client.callTool(
                name: name, arguments: arguments, meta: Metadata(progressToken: progressToken))
            let result = try await withTaskCancellationHandler {
                try await resultOrTimeout(
                    toolName: name, context: context, progressToken: progressToken, timeout: effectiveTimeout)
            } onCancel: {
                // `withTaskCancellationHandler`'s onCancel must be
                // synchronous, so sending the cancellation notification (an
                // async call on the `client` actor) requires its own
                // unstructured `Task` — one of the few deliberate exceptions
                // to this file's "no unmanaged Task {}" convention (see also
                // `performConnectAttempt(transport:timeout:)`'s un-joined
                // connect-race `Task`s), since there is no other way to
                // bridge a synchronous cancellation hook to async work.
                Task { await self.cancelPendingCall(requestID: context.requestID, reason: "Swift task cancelled") }
            }
            return ToolContentRenderer.render(result: result)
        } catch is CancellationError {
            return ToolContentRenderer.render(result: Self.cancelledResult(toolName: name))
        } catch MCPServerError.callTimedOut(let timedOutToolName) {
            logger.warning(
                "MCPServer call timed out",
                metadata: [
                    Self.serverMetadataKey: "\(identityNameForDiagnostics)", "tool": "\(timedOutToolName)",
                ])
            return ToolContentRenderer.render(result: Self.timedOutResult(toolName: timedOutToolName))
        } catch {
            logger.warning(
                "MCPServer mid-call transport fault",
                metadata: [Self.serverMetadataKey: "\(identityNameForDiagnostics)", "tool": "\(name)", Self.errorMetadataKey: "\(error)"])
            state = .faulted(String(describing: error))
            emitCatalogSnapshot()
            await reconnectAfterFault()
            return ToolContentRenderer.render(result: Self.faultResult(for: error))
        }
    }

    /// Whichever of a ``call(toolNamed:arguments:timeout:)``'s own response
    /// or its resettable timeout resolves first.
    private enum CallOutcome: Sendable {
        case result(CallTool.Result)
        case timedOut
    }

    /// Races `context`'s response against its resettable timeout, returning
    /// the response if it wins or throwing
    /// ``MCPServerError/callTimedOut(toolName:)`` if the timeout wins.
    ///
    /// The timeout side loops sleeping in real-wall-clock full-`timeout`
    /// increments (`Task.sleep(for:)` — deliberately never `clock`; see
    /// `clock`'s own doc comment for why), comparing ``ActiveCall/deadline``'s
    /// ``CallDeadline/resetCount`` before and after each sleep to detect
    /// whether `handleProgressNotification(parameters:)` reset the deadline while
    /// it slept — see ``CallDeadline`` for why that comparison, not a
    /// literal clock-instant deadline, is what makes this loop's logic
    /// unit-testable in isolation. If the timeout wins, explicitly cancels
    /// `context`'s still-pending request first (via
    /// ``cancelPendingCall(requestID:reason:)``) so its response-awaiting
    /// child task actually finishes instead of leaving this method's
    /// `withThrowingTaskGroup` waiting on an orphaned task forever.
    ///
    /// - Parameters:
    ///   - toolName: The tool's name, for
    ///     ``MCPServerError/callTimedOut(toolName:)``.
    ///   - context: The in-flight request context to await.
    ///   - progressToken: The token this call registered under in
    ///     ``activeCalls``.
    ///   - timeout: The full timeout duration to sleep in, between resets.
    /// - Returns: The tool's `CallTool.Result` if it completes before timing
    ///   out.
    /// - Throws: ``MCPServerError/callTimedOut(toolName:)`` if the timeout
    ///   wins; whatever `context`'s underlying request throws otherwise
    ///   (including `CancellationError` if the caller's own Swift `Task` was
    ///   cancelled).
    private func resultOrTimeout(
        toolName: String, context: RequestContext<CallTool.Result>, progressToken: ProgressToken, timeout: Duration
    ) async throws -> CallTool.Result {
        try await withThrowingTaskGroup(of: CallOutcome.self) { group in
            group.addTask {
                .result(try await context.value)
            }
            group.addTask {
                try await self.watchForTimeout(progressToken: progressToken, timeout: timeout)
            }
            defer { group.cancelAll() }
            guard let outcome = try await group.next() else {
                throw MCPServerError.callTimedOut(toolName: toolName)
            }
            switch outcome {
            case .result(let result):
                return result
            case .timedOut:
                await cancelPendingCall(requestID: context.requestID, reason: "Call exceeded its per-call timeout")
                throw MCPServerError.callTimedOut(toolName: toolName)
            }
        }
    }

    /// Sleeps in real-wall-clock `timeout` increments until a full interval
    /// elapses with no `handleProgressNotification(parameters:)` reset, returning
    /// ``CallOutcome/timedOut`` once that happens.
    ///
    /// Pulled out of ``resultOrTimeout(toolName:context:progressToken:timeout:)``'s
    /// `withThrowingTaskGroup` task into its own actor method so that task's
    /// body — and this loop's reset-detecting `guard` — don't nest four
    /// levels deep (`withThrowingTaskGroup` > `addTask` > `while` > `guard`).
    ///
    /// - Parameters:
    ///   - progressToken: The token this call registered under in
    ///     ``activeCalls``.
    ///   - timeout: The full timeout duration to sleep in, between resets.
    /// - Returns: Always ``CallOutcome/timedOut``, once a full `timeout`
    ///   interval elapses with no reset.
    /// - Throws: `CancellationError` if the calling `Task` is cancelled while
    ///   suspended in `Task.sleep(for:)`.
    private func watchForTimeout(progressToken: ProgressToken, timeout: Duration) async throws -> CallOutcome {
        while true {
            let observedResetCount = activeCalls[progressToken]?.deadline.resetCount ?? 0
            try await Task.sleep(for: timeout)
            let currentResetCount = activeCalls[progressToken]?.deadline.resetCount ?? 0
            guard currentResetCount == observedResetCount else { continue }
            return .timedOut
        }
    }

    /// Sends a `notifications/cancelled` for `requestID` and unblocks its
    /// pending continuation with `CancellationError`, via
    /// `MCP.Client.cancelRequest(_:reason:)` — the shared plumbing behind
    /// both ``call(toolNamed:arguments:timeout:)``'s Swift-task-cancellation
    /// path and its timeout-expiry path (see ``resultOrTimeout(toolName:context:progressToken:timeout:)``).
    ///
    /// - Parameters:
    ///   - requestID: The in-flight request's id.
    ///   - reason: A human-readable reason included in the cancellation
    ///     notification, for the server's diagnostics.
    private func cancelPendingCall(requestID: ID, reason: String) async {
        do {
            try await client.cancelRequest(requestID, reason: reason)
        } catch {
            logger.warning(
                "MCPServer failed to send a cancellation notification",
                metadata: [Self.serverMetadataKey: "\(identityNameForDiagnostics)", Self.errorMetadataKey: "\(error)"])
        }
    }

    /// Restores the server state to ready after a mid-call transport fault.
    ///
    /// Uses `lastTransport` and `activeBackoffPolicy` — the
    /// "auto-reconnect" half of ``call(toolNamed:arguments:timeout:)``.
    ///
    /// Never throws: both the "no prior transport" case and a
    /// backoff-exhausted reconnect are logged and swallowed, leaving
    /// ``state`` as whatever the failed attempt(s) left it.
    private func reconnectAfterFault() async {
        guard let lastTransport else {
            logger.error(
                "MCPServer cannot auto-reconnect after a mid-call fault: no prior transport recorded",
                metadata: [Self.serverMetadataKey: "\(identityNameForDiagnostics)"])
            return
        }
        do {
            try await connect(transport: lastTransport, backoffPolicy: activeBackoffPolicy)
            logger.info(
                "MCPServer auto-reconnected after mid-call fault",
                metadata: [Self.serverMetadataKey: "\(identityNameForDiagnostics)"])
        } catch {
            logger.error(
                "MCPServer auto-reconnect after mid-call fault failed",
                metadata: [Self.serverMetadataKey: "\(identityNameForDiagnostics)", Self.errorMetadataKey: "\(error)"])
        }
    }

    /// Builds an `isError` `CallTool.Result` carrying `text` as its sole
    /// content — the shared shape behind every error result this actor
    /// renders (``faultResult(for:)``, ``timedOutResult(toolName:)``,
    /// ``cancelledResult(toolName:)``, ``notAvailableResult(for:)``), which
    /// otherwise differ only in the message text.
    ///
    /// - Parameter text: The human-readable error description.
    /// - Returns: A `CallTool.Result` with `isError` set, for
    ///   ``ToolContentRenderer`` to render.
    private static func errorResult(text: String) -> CallTool.Result {
        CallTool.Result(
            content: [.text(text: text, annotations: nil, _meta: nil)],
            isError: true
        )
    }

    /// Returns the rendered error result for mid-call transport faults.
    ///
    /// This is what ``call(toolNamed:arguments:timeout:)`` returns in place
    /// of throwing when a mid-call transport fault occurs.
    ///
    /// - Parameter error: The underlying transport error the call caught.
    /// - Returns: A `CallTool.Result` describing the fault, with `isError`
    ///   set, for ``ToolContentRenderer`` to render.
    private static func faultResult(for error: any Error) -> CallTool.Result {
        errorResult(text: "Transport fault: \(error)")
    }

    /// Returns the rendered error result for a call that exceeded its
    /// per-call timeout.
    ///
    /// This is what ``call(toolNamed:arguments:timeout:)`` returns in place
    /// of throwing when its ``resultOrTimeout(toolName:context:progressToken:timeout:)``
    /// race is won by the timeout.
    ///
    /// - Parameter toolName: The name of the tool that timed out.
    /// - Returns: A `CallTool.Result` describing the timeout, with
    ///   `isError` set, for ``ToolContentRenderer`` to render.
    private static func timedOutResult(toolName: String) -> CallTool.Result {
        errorResult(text: "Tool \"\(toolName)\" timed out.")
    }

    /// Returns the rendered error result for a call whose Swift `Task` was
    /// cancelled.
    ///
    /// This is what ``call(toolNamed:arguments:timeout:)`` returns in place
    /// of throwing when the caller's own `Task` is cancelled mid-call.
    ///
    /// - Parameter toolName: The name of the tool the cancelled call
    ///   invoked.
    /// - Returns: A `CallTool.Result` describing the cancellation, with
    ///   `isError` set, for ``ToolContentRenderer`` to render.
    private static func cancelledResult(toolName: String) -> CallTool.Result {
        errorResult(text: "Tool \"\(toolName)\" call was cancelled.")
    }

    /// Attempts a single connection bounded by the specified real
    /// wall-clock timeout.
    ///
    /// Measured against real wall-clock time — never `clock` (see
    /// ``BackoffPolicy/connectTimeout``'s doc for why a per-attempt timeout
    /// is a real-time bound regardless of which clock paces the backoff
    /// delay between attempts).
    ///
    /// Deliberately **not** a `withThrowingTaskGroup` race between the
    /// connect attempt and a `Task.sleep(for:)`: a throwing task group
    /// implicitly awaits every child — including ones already
    /// `cancelAll()`-cancelled — before the group itself returns, and
    /// cancellation is purely cooperative. `MCP.Client.connect(transport:)`
    /// never checks `Task.isCancelled` itself, so a `Transport.connect()`
    /// that never returns (a wedged subprocess spawn or stalled handshake)
    /// would make a group-based race block just as long as an un-raced
    /// call would — defeating the timeout entirely. Instead, the connect
    /// attempt runs as a fully independent, un-joined `Task`, and this
    /// function returns as soon as whichever of the two — the attempt or
    /// the timeout — resumes ``SingleResume`` first; the loser keeps
    /// running in the background and its eventual result is simply
    /// resumed-and-discarded by ``SingleResume``.
    ///
    /// A late-arriving, abandoned attempt that eventually *does* finish
    /// still runs through ``applyConnect(transport:generation:)``, whose
    /// own generation check discards the result rather than clobbering
    /// ``state``/``identity``/`discoveredTools` set by a newer attempt
    /// (or by ``connect(transport:backoffPolicy:)`` having already given
    /// up and thrown ``MCPServerError/backoffExhausted(serverName:attempts:lastError:)``).
    ///
    /// - Parameters:
    ///   - transport: The transport to connect over.
    ///   - timeout: The maximum real wall-clock time this attempt may take
    ///     before it is abandoned in favor of the next backoff retry.
    /// - Throws: Whatever ``connect(transport:)`` throws, or
    ///   ``MCPServerError/connectAttemptTimedOut`` if `timeout` elapses
    ///   first.
    private func performConnectAttempt(transport: any Transport, timeout: Duration) async throws {
        await client.disconnect()
        connectGeneration += 1
        let generation = connectGeneration

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let resume = SingleResume(continuation)

            Task {
                do {
                    try await self.applyConnect(transport: transport, generation: generation)
                    resume.resume(with: .success(()))
                } catch {
                    resume.resume(with: .failure(error))
                }
            }

            Task {
                try? await Task.sleep(for: timeout)
                resume.resume(with: .failure(MCPServerError.connectAttemptTimedOut))
            }
        }
    }

    /// Performs the actual connection work shared by both retry-based and
    /// single-attempt connections.
    ///
    /// The shared body behind both ``connect(transport:)`` and
    /// `performConnectAttempt(transport:timeout:)`, mutating
    /// ``state``/``identity``/`discoveredTools` only if `generation`
    /// still matches ``connectGeneration`` by the time this call would
    /// apply its result.
    ///
    /// That guard matters only for a `performConnectAttempt(transport:timeout:)`
    /// caller: a fresh, non-racing ``connect(transport:)`` call always
    /// passes its own just-incremented generation, so the guard is always
    /// satisfied there. For an *abandoned* attempt that lost the race
    /// against ``BackoffPolicy/connectTimeout`` and finishes later, a newer
    /// attempt (or the retry loop giving up entirely) has by then moved
    /// ``connectGeneration`` on, so the stale result is logged and
    /// discarded instead of overwriting newer state.
    ///
    /// - Parameters:
    ///   - transport: The transport to connect over.
    ///   - generation: The ``connectGeneration`` this attempt was launched
    ///     under.
    /// - Throws: Whatever `MCP.Client.connect(transport:)` or
    ///   `MCP.Client.listTools(cursor:)` throws, or whatever
    ///   `MCPTool.init(tool:client:)` throws for a malformed `inputSchema`
    ///   encountered during discovery — even when `generation` turns out to
    ///   be stale, so `performConnectAttempt(transport:timeout:)`'s
    ///   detached `Task` still observes failure vs. success correctly.
    private func applyConnect(transport: any Transport, generation: Int) async throws {
        guard generation == connectGeneration else {
            logStaleGenerationDiscard(message: "MCPServer skipping a connect attempt already superseded by a newer one")
            return
        }
        lastTransport = transport
        state = .connecting
        if let elicitationCoordinator {
            await declareElicitationCapabilityAndRegisterHandler(coordinator: elicitationCoordinator)
        }
        if !hasRegisteredToolListChangedHandler {
            hasRegisteredToolListChangedHandler = true
            await registerToolListChangedHandler()
        }
        if !hasRegisteredProgressHandler {
            hasRegisteredProgressHandler = true
            await registerProgressHandler()
        }
        do {
            let initializeResult = try await client.connect(transport: transport)
            let tools = try await discoverAllTools()
            guard generation == connectGeneration else {
                logStaleGenerationDiscard(message: "MCPServer discarding a stale connect success — a newer attempt has since started")
                return
            }
            if identity == nil {
                identity = ServerIdentity(
                    name: hostSuppliedName ?? initializeResult.serverInfo.name)
            }
            discoveredTools = tools
            state = .ready
            emitCatalogSnapshot()
        } catch {
            guard generation == connectGeneration else {
                logStaleGenerationDiscard(
                    message: "MCPServer discarding a stale connect failure — a newer attempt has since started", error: error)
                throw error
            }
            state = .faulted(String(describing: error))
            emitCatalogSnapshot()
            throw error
        }
    }

    /// Logs that a connect attempt was discarded because a newer attempt
    /// has since superseded it.
    ///
    /// Centralizes the logging shared by ``applyConnect(transport:generation:)``'s
    /// three "stale generation" guards, which otherwise differ only in
    /// `message` and whether an `error` is being discarded — the caller
    /// still decides whether to `return` or `throw` afterward.
    ///
    /// - Parameters:
    ///   - message: The log message describing which stale attempt this is.
    ///   - error: The error being discarded, if any, included in the log
    ///     metadata alongside `message`.
    private func logStaleGenerationDiscard(message: Logger.Message, error: (any Error)? = nil) {
        var metadata: Logger.Metadata = [Self.serverMetadataKey: "\(identityNameForDiagnostics)"]
        if let error {
            metadata[Self.errorMetadataKey] = "\(error)"
        }
        logger.warning(message, metadata: metadata)
    }

    /// Computes the exponential backoff delay for the next retry attempt.
    ///
    /// - Parameters:
    ///   - attempt: The 1-based attempt number that just failed.
    ///   - policy: The backoff policy supplying ``BackoffPolicy/baseDelay``
    ///     and ``BackoffPolicy/maxDelay``.
    /// - Returns: `baseDelay * 2^(attempt - 1)`, capped at `maxDelay` — so
    ///   the delay after the 1st failure is `baseDelay`, after the 2nd is
    ///   `baseDelay * 2`, after the 3rd is `baseDelay * 4`, and so on.
    private static func backoffDelay(afterAttempt attempt: Int, policy: BackoffPolicy) -> Duration {
        var delay = policy.baseDelay
        for _ in 1..<attempt {
            delay = delay * 2.0
        }
        return min(delay, policy.maxDelay)
    }

    /// A best-effort display name for log messages and
    /// ``MCPServerError/backoffExhausted(serverName:attempts:lastError:)``,
    /// usable even before ``identity`` is established.
    ///
    /// Prefers the host-supplied name (stable from construction), then the
    /// already-established ``identity`` (relevant when a reconnect's
    /// backoff is exhausted after a prior successful connect), falling back
    /// to a fixed placeholder when neither is available.
    private var identityNameForDiagnostics: String {
        hostSuppliedName ?? identity?.name ?? "<unidentified MCPServer>"
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

    /// The discovered tools as `FoundationModels.Tool` values for use in a
    /// session.
    ///
    /// Type-erased from ``mcpTools()`` for direct use in a
    /// `LanguageModelSession`.
    ///
    /// - Returns: One `any FoundationModels.Tool` per discovered tool.
    /// - Throws: Whatever ``mcpTools()`` throws.
    public func foundationModelsTools() throws -> [any FoundationModels.Tool] {
        try mcpTools().map { $0 as any FoundationModels.Tool }
    }

    /// Resolves a tool name against the current catalog, returning nil if
    /// not found.
    ///
    /// Resolves `name` against the **current** catalog — i.e.
    /// `discoveredTools` as of this call, not whatever catalog snapshot a
    /// caller last observed from ``catalogUpdates``.
    ///
    /// Unlike ``mcpTools()``, never throws ``MCPServerError/notReady(_:)``:
    /// a tool absent from the current catalog — whether because ``state``
    /// has never reached ``MCPServerState/ready`` or because a coalesced
    /// `tools/list_changed` re-list (see `coalesceAndRelist()`) removed it
    /// — simply resolves to `nil`, for ``toolNoLongerAvailableResult(named:)``
    /// to describe to a caller that cached an earlier reference.
    ///
    /// - Parameter name: The tool name to resolve.
    /// - Returns: The matching ``MCPTool`` from `discoveredTools`, or `nil`
    ///   if no currently-discovered tool has that name.
    public func tool(named name: String) -> MCPTool? {
        discoveredTools.first { $0.name == name }
    }

    /// The current catalog snapshot with this server's identity, epoch,
    /// state, and all discovered tools.
    ///
    /// Combines ``identity``, `catalogEpoch`, ``state``, and every
    /// currently-discovered tool converted to a ``ToolDescriptor``.
    ///
    /// Unlike ``mcpTools()``, whose ``MCPServerError/notReady(_:)`` guard is
    /// keyed on ``state`` being exactly ``MCPServerState/ready``, this
    /// property's guard is keyed on ``identity`` having ever been
    /// established — so a snapshot taken while ``state`` is
    /// ``MCPServerState/faulted(_:)`` after a prior successful connect still
    /// succeeds, reporting the last-known tools alongside the current
    /// (faulted) state, exactly as `plan.md`'s Dynamic discovery decision
    /// calls for.
    ///
    /// - Throws: ``MCPServerError/notReady(_:)`` if ``identity`` has never
    ///   been established — i.e. no ``connect(transport:)`` call has ever
    ///   fully succeeded.
    public var catalog: ToolCatalog {
        get throws {
            guard let identity else {
                throw MCPServerError.notReady(state)
            }
            return makeCatalogSnapshot(epoch: catalogEpoch, identity: identity)
        }
    }

    /// Builds a ``ToolCatalog`` snapshot from `discoveredTools` and
    /// ``state`` as they stand right now — the shared construction behind
    /// both ``catalog`` and `emitCatalogSnapshot()`.
    ///
    /// - Parameters:
    ///   - epoch: The snapshot's generation number.
    ///   - identity: The server's established stable identity.
    /// - Returns: The constructed snapshot.
    private func makeCatalogSnapshot(epoch: Int, identity: ServerIdentity) -> ToolCatalog {
        ToolCatalog(
            identity: identity,
            epoch: epoch,
            state: state,
            tools: discoveredTools.map(ToolDescriptor.init(mcpTool:))
        )
    }

    /// Increments the epoch and emits a new catalog snapshot when the
    /// server identity is established.
    ///
    /// Yields a new ``ToolCatalog`` snapshot on ``catalogUpdates`` with the
    /// incremented `catalogEpoch`, if ``identity`` has been established —
    /// a no-op before the first successful connect, since there is nothing
    /// yet to snapshot.
    ///
    /// The single emission point behind every ``catalogUpdates`` update: a
    /// successful connect/reconnect and a failed reconnect (both in
    /// ``applyConnect(transport:generation:)``), a mid-call transport fault
    /// (``call(toolNamed:arguments:timeout:)``), and a coalesced `tools/list_changed`
    /// re-list (`relistOnce()`) all funnel through this one method, so
    /// `catalogEpoch` only ever advances alongside an actual emission.
    private func emitCatalogSnapshot() {
        guard let identity else { return }
        catalogEpoch += 1
        catalogContinuation.yield(makeCatalogSnapshot(epoch: catalogEpoch, identity: identity))
    }

    /// Returns the rendered error result text for when a
    /// previously-resolved tool is no longer available.
    ///
    /// A caller should use this once a previously-resolved tool is no
    /// longer present in the current catalog — e.g. removed by a coalesced
    /// `tools/list_changed` re-list (`relistOnce()`) since the caller
    /// last resolved it via ``tool(named:)``.
    ///
    /// - Parameter name: The name of the tool that is no longer available.
    /// - Returns: Rendered `isError` content, via ``ToolContentRenderer``,
    ///   describing `name` as no longer available.
    public static func toolNoLongerAvailableResult(named name: String) -> String {
        ToolContentRenderer.render(result: notAvailableResult(for: name))
    }

    /// The `CallTool.Result` behind ``toolNoLongerAvailableResult(named:)``.
    ///
    /// - Parameter name: The name of the tool that is no longer available.
    /// - Returns: A `CallTool.Result` with `isError` set, describing `name`
    ///   as no longer available.
    private static func notAvailableResult(for name: String) -> CallTool.Result {
        errorResult(text: "Tool \"\(name)\" is no longer available.")
    }

    /// Fetches all tool pages from the server via paginated `tools/list`.
    ///
    /// Follows `nextCursor` until the server returns none, mapping each
    /// `MCP.Tool` into an ``MCPTool``. A one-page read silently truncates
    /// whenever the server paginates its `tools/list` response; this loop
    /// is what stands between callers and that truncation.
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

    // MARK: - Progress: notifications/progress routed to in-flight calls

    /// Registers the notification handler for `notifications/progress`.
    ///
    /// Routes every inbound progress notification to
    /// `handleProgressNotification(parameters:)` — called exactly once per
    /// ``MCPServer`` (see ``hasRegisteredProgressHandler``), never on every
    /// reconnect, mirroring ``registerToolListChangedHandler()``.
    private func registerProgressHandler() async {
        await client.onNotification(ProgressNotification.self) { [weak self] message in
            guard let self else { return }
            await self.handleProgressNotification(parameters: message.params)
        }
    }

    /// Resets the matching in-flight call's timeout deadline and republishes
    /// the update on ``progressUpdates``.
    ///
    /// A no-op if `parameters.progressToken` does not match any call this
    /// server currently tracks in ``activeCalls`` — e.g. the notification
    /// arrived after the call already finished or timed out.
    ///
    /// - Parameter parameters: The inbound `notifications/progress`
    ///   payload.
    private func handleProgressNotification(parameters: ProgressNotification.Parameters) {
        guard var activeCall = activeCalls[parameters.progressToken] else { return }
        activeCall.deadline.resetForProgress()
        activeCalls[parameters.progressToken] = activeCall
        progressContinuation.yield(
            CallProgress(
                toolName: activeCall.toolName,
                progress: parameters.progress,
                total: parameters.total,
                message: parameters.message))
    }

    // MARK: - Live catalog: coalesced tools/list_changed re-list

    /// Registers the notification handler for tool list changes.
    ///
    /// Routes every inbound `notifications/tools/list_changed` notification
    /// to ``handleToolListChangedNotification()`` — called exactly once per
    /// ``MCPServer`` (see ``hasRegisteredToolListChangedHandler``), never on
    /// every reconnect.
    private func registerToolListChangedHandler() async {
        await client.onNotification(ToolListChangedNotification.self) { [weak self] _ in
            guard let self else { return }
            await self.handleToolListChangedNotification()
        }
    }

    /// Called once per inbound `notifications/tools/list_changed`
    /// notification: advances ``toolListChangedGeneration`` and, if no
    /// `coalesceAndRelist()` watcher is already running, starts one.
    ///
    /// A burst of notifications arriving back to back only ever starts one
    /// watcher — every additional notification in the burst just advances
    /// ``toolListChangedGeneration``, which the already-running watcher
    /// observes on its next poll — so an arbitrarily large burst still
    /// produces exactly one re-list once it goes quiet.
    private func handleToolListChangedNotification() {
        toolListChangedGeneration += 1
        guard !isCoalescingToolListChanged else { return }
        isCoalescingToolListChanged = true
        coalescingTask = Task { await self.coalesceAndRelist() }
    }

    /// Coalesces rapid tool list change notifications into a single
    /// re-list.
    ///
    /// Waits out ``toolListChangedCoalesceWindow`` once, then re-runs
    /// paginated `tools/list` discovery (`relistOnce()`) repeatedly until a
    /// full discovery round trip completes with no further notification
    /// arriving during it, then emits exactly one new ``catalogUpdates``
    /// snapshot — the coalescing behavior
    /// ``handleToolListChangedNotification()`` documents.
    ///
    /// The initial sleep catches a burst that arrives before this task even
    /// starts running; the repeat-until-stable loop afterward catches
    /// stragglers that arrive *during* a `tools/list` round trip — itself a
    /// real cross-actor, cross-transport exchange (unlike a clock sleep,
    /// never a zero-latency operation), so it naturally gives a concurrently
    /// arriving notification genuine scheduling room to be observed by
    /// ``handleToolListChangedNotification()`` before this loop re-checks
    /// ``toolListChangedGeneration``. Together, the two catch a burst
    /// regardless of whether it arrives all at once up front or trickles in
    /// while a re-list is already underway.
    private func coalesceAndRelist() async {
        try? await clock.sleep(for: Self.toolListChangedCoalesceWindow)
        var observedGeneration: Int
        var lastRelistSucceeded = false
        repeat {
            observedGeneration = toolListChangedGeneration
            lastRelistSucceeded = await relistOnce()
        } while observedGeneration != toolListChangedGeneration
        isCoalescingToolListChanged = false
        coalescingTask = nil
        if lastRelistSucceeded {
            emitCatalogSnapshot()
        }
    }

    /// Re-runs tool discovery once and updates the discovered tools if
    /// successful.
    ///
    /// On success, replaces `discoveredTools` — the single discovery round
    /// trip `coalesceAndRelist()` repeats until stable, emitting at most
    /// one ``catalogUpdates`` snapshot itself once the whole burst has
    /// settled.
    ///
    /// A discovery failure is logged and otherwise swallowed, leaving
    /// `discoveredTools` and `catalogEpoch` exactly as they were: unlike
    /// a failed ``connect(transport:)``, a transient `tools/list` failure
    /// mid-burst does not itself change ``state`` or fault the connection.
    ///
    /// - Returns: `true` if discovery succeeded and `discoveredTools` was
    ///   replaced; `false` if it failed and `discoveredTools` was left
    ///   unchanged.
    private func relistOnce() async -> Bool {
        do {
            discoveredTools = try await discoverAllTools()
            return true
        } catch {
            logger.warning(
                "MCPServer failed to re-list tools after tools/list_changed",
                metadata: [Self.serverMetadataKey: "\(identityNameForDiagnostics)", Self.errorMetadataKey: "\(error)"])
            return false
        }
    }

    // MARK: - Elicitation

    /// Declares the elicitation capability and registers the request
    /// handler.
    ///
    /// Declares the elicitation client capability on ``client`` and
    /// registers the handler that routes every `elicitation/create` request
    /// to `coordinator` — the two "wire the actor" duties `plan.md`'s
    /// "Elicitation: user input, in both directions" section assigns to
    /// ``MCPServer``.
    ///
    /// `client.capabilities` is an actor-isolated stored property with no
    /// public setter — `MCP.Client` only ever reads it once, at the
    /// `initialize` handshake inside `connect(transport:)`, and the pinned
    /// swift-sdk exposes no API to mutate it from outside afterward (see
    /// `docs/swift-sdk-notes.md`'s "Elicitation surface" section). Per that
    /// note, `withElicitationHandler(_:)` is documented as *the* declaration
    /// mechanism this SDK version provides: registering it is the whole of
    /// what an external caller can do to opt a connection into elicitation.
    /// A host that also needs the capability reflected verbatim in the
    /// `initialize` request must construct its `MCP.Client` with
    /// `capabilities: .init(elicitation: .init(form: .init(), url: .init()))`
    /// up front, before handing it to ``MCPServer/init(client:name:elicitationCoordinator:clock:logger:)``.
    ///
    /// Safe to call again on every reconnect attempt: `withMethodHandler`
    /// simply re-registers the same handler.
    ///
    /// - Parameter coordinator: The coordinator every routed request is sent
    ///   to.
    private func declareElicitationCapabilityAndRegisterHandler(
        coordinator: any ElicitationCoordinator
    ) async {
        await client.withElicitationHandler { parameters in
            await Self.answerElicitation(parameters: parameters, coordinator: coordinator)
        }
    }

    /// Routes a server-initiated elicitation request to the coordinator.
    ///
    /// Enforces the no-secrets-in-form-mode rule (see
    /// `Elicitation.RequestSchema.requiresURLModeRouting` and
    /// ``ElicitationRouting``), and converts the coordinator's
    /// ``ElicitationResponse`` back into the `CreateElicitation.Result` the
    /// server expects.
    ///
    /// - Parameters:
    ///   - parameters: The request exactly as the server sent it — either
    ///     form-mode (`message` + `requestedSchema`) or URL-mode (`message`
    ///     + a genuine `url`).
    ///   - coordinator: The coordinator to route to.
    /// - Returns: The `CreateElicitation.Result` reporting the user's
    ///   action.
    private static func answerElicitation(
        parameters: CreateElicitation.Parameters,
        coordinator: any ElicitationCoordinator
    ) async -> CreateElicitation.Result {
        let response: ElicitationResponse
        switch parameters {
        case .form(let form):
            response = await ElicitationRouting.route(
                message: form.message, requestedSchema: form.requestedSchema, coordinator: coordinator)
        case .url(let url):
            response = await coordinator.elicit(message: url.message, url: url.url)
        }
        return Self.makeElicitationResult(from: response)
    }

    /// Converts an ``ElicitationResponse`` into the `CreateElicitation.Result`
    /// the server expects.
    ///
    /// - Parameter response: The coordinator's response.
    /// - Returns: The equivalent `CreateElicitation.Result`.
    private static func makeElicitationResult(from response: ElicitationResponse) -> CreateElicitation.Result {
        switch response {
        case .accept(let content):
            return CreateElicitation.Result(action: .accept, content: content)
        case .decline:
            return CreateElicitation.Result(action: .decline)
        case .cancel:
            return CreateElicitation.Result(action: .cancel)
        }
    }
}

/// Serializes the single resumption of a shared `CheckedContinuation`
/// between two racing tasks.
///
/// The two tasks are
/// ``MCPServer/performConnectAttempt(transport:timeout:)``'s connect
/// attempt and its timeout, both independent and un-joined, racing to
/// finish first.
///
/// `CheckedContinuation.resume(with:)` traps if called more than once;
/// this guards that with a `Mutex` so whichever task finishes first "wins"
/// and the other's later resume attempt is silently dropped, without a
/// data race over which one gets there first.
private final class SingleResume<Value: Sendable>: Sendable {
    private let continuation: Mutex<CheckedContinuation<Value, any Error>?>

    /// Wraps `continuation` for exactly one resumption.
    ///
    /// - Parameter continuation: The continuation to resume at most once.
    init(_ continuation: CheckedContinuation<Value, any Error>) {
        self.continuation = Mutex(continuation)
    }

    /// Resumes the wrapped continuation with the result, or silently
    /// ignores a duplicate resumption attempt.
    ///
    /// - Parameter result: The result (or error) to resume with.
    func resume(with result: Result<Value, any Error>) {
        let winner = continuation.withLock { stored -> CheckedContinuation<Value, any Error>? in
            defer { stored = nil }
            return stored
        }
        winner?.resume(with: result)
    }
}
