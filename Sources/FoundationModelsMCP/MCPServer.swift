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
/// ``MCPServer/init(client:name:)`` for how the name is chosen.
public struct ServerIdentity: Sendable, Hashable {
    /// The stable name identifying this server connection.
    public let name: String
}

/// Configuration for ``MCPServer``'s connect-retry and auto-reconnect
/// backoff — see ``MCPServer/connect(transport:backoffPolicy:)`` and
/// ``MCPServer/call(toolNamed:arguments:)``.
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

    /// The default policy: a 10-second per-attempt timeout, a 250
    /// millisecond initial backoff doubling up to a 30-second cap, and 5
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

    /// Every tool discovered by the most recent successful
    /// ``connect(transport:)``, in `tools/list` page order.
    private var discoveredTools: [MCPTool] = []

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
    /// fault (see ``call(toolNamed:arguments:)``) can auto-reconnect
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
    /// ``performConnectAttempt(transport:timeout:)``'s backoff retry loop),
    /// and captured by that attempt as the generation it must still match
    /// before mutating ``state``/``identity``/``discoveredTools`` — see
    /// ``performConnectAttempt(transport:timeout:)`` for why an abandoned,
    /// still-running attempt can otherwise resolve long after the retry
    /// loop has moved on.
    private var connectGeneration = 0

    /// The backoff policy ``connect(transport:backoffPolicy:)`` was last
    /// called with, reused by ``call(toolNamed:arguments:)`` when
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
    ///     between retries. Defaults to a real `ContinuousClock`; tests
    ///     substitute a virtual clock to exercise a full backoff schedule
    ///     without any real delay.
    ///   - logger: The structured logger every retry, reconnect, and
    ///     mid-call fault is reported to. Defaults to a logger labeled
    ///     `"com.foundationmodelsmcp.mcpserver"`.
    public init(
        client: MCP.Client,
        name: String? = nil,
        elicitationCoordinator: (any ElicitationCoordinator)? = nil,
        clock: any Clock<Duration> = ContinuousClock(),
        logger: Logger = Logger(label: "com.foundationmodelsmcp.mcpserver")
    ) {
        self.client = client
        self.hostSuppliedName = name
        self.elicitationCoordinator = elicitationCoordinator
        self.clock = clock
        self.logger = logger
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

    /// Connects with automatic retry: attempts ``connect(transport:)`` up to
    /// `backoffPolicy.maxAttempts` times, each bounded by
    /// `backoffPolicy.connectTimeout`, sleeping on ``clock`` for an
    /// exponentially increasing delay (see ``BackoffPolicy``) between failed
    /// attempts. Hard-fails only once every attempt is exhausted.
    ///
    /// Records `backoffPolicy` as ``activeBackoffPolicy`` up front, so a
    /// later mid-call transport fault (see ``call(toolNamed:arguments:)``)
    /// auto-reconnects using this same policy — "auto-reconnect with the
    /// same policy" per `plan.md`'s Lifecycle policy. Every retry, and the
    /// final exhaustion if it happens, is logged.
    ///
    /// - Parameters:
    ///   - transport: The transport to connect over, constructed and owned
    ///     by the caller; forwarded to ``connect(transport:)`` on every
    ///     attempt, which retains it as ``lastTransport``.
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
                    metadata: ["server": "\(identityNameForDiagnostics)", "attempt": "\(attempt)"])
                return
            } catch {
                lastError = error
                logger.warning(
                    "MCPServer connect attempt failed",
                    metadata: [
                        "server": "\(identityNameForDiagnostics)",
                        "attempt": "\(attempt)",
                        "maxAttempts": "\(backoffPolicy.maxAttempts)",
                        "error": "\(error)",
                    ])
                guard attempt < backoffPolicy.maxAttempts else { break }
                let delay = Self.backoffDelay(afterAttempt: attempt, policy: backoffPolicy)
                logger.info(
                    "MCPServer backing off before next connect retry",
                    metadata: ["server": "\(identityNameForDiagnostics)", "delay": "\(delay)"])
                try await clock.sleep(for: delay)
            }
        }

        // The final attempt may still be running in the background (it lost
        // the ``performConnectAttempt(transport:timeout:)`` race against its
        // own `connectTimeout` rather than having actually finished) — bump
        // ``connectGeneration`` here too, not just on a *newer* connect call,
        // so that attempt's eventual, arbitrarily-late resolution is discarded
        // by ``applyConnect(transport:generation:)`` instead of mutating
        // ``state``/``identity``/``discoveredTools`` after the caller has
        // already received and acted on ``MCPServerError/backoffExhausted(serverName:attempts:lastError:)``.
        connectGeneration += 1

        let exhausted = MCPServerError.backoffExhausted(
            serverName: identityNameForDiagnostics,
            attempts: backoffPolicy.maxAttempts,
            lastError: String(describing: lastError)
        )
        logger.error(
            "MCPServer connect backoff exhausted",
            metadata: ["server": "\(identityNameForDiagnostics)", "attempts": "\(backoffPolicy.maxAttempts)"])
        throw exhausted
    }

    /// Calls a tool on the connected server and renders the result for the
    /// model, mapping a mid-call transport fault to an `isError`-style
    /// rendered result (via ``ToolContentRenderer``) instead of throwing or
    /// hanging, and auto-reconnecting with ``activeBackoffPolicy`` as a side
    /// effect — so the model can react to *this* call's failure while the
    /// connection heals for the next one.
    ///
    /// Never throws: a transport fault becomes rendered `isError` content,
    /// exactly like a server-reported `isError` result already is (see
    /// `MCPTool/call(arguments:)`).
    ///
    /// - Parameters:
    ///   - name: The name of the tool to call.
    ///   - arguments: Arguments to use for the tool call.
    /// - Returns: The rendered `tools/call` result on success, or a rendered
    ///   `isError` result describing the transport fault.
    public func call(toolNamed name: String, arguments: [String: Value]? = nil) async -> String {
        do {
            let result = try await client.callTool(name: name, arguments: arguments)
            return ToolContentRenderer.render(result: result)
        } catch {
            logger.warning(
                "MCPServer mid-call transport fault",
                metadata: ["server": "\(identityNameForDiagnostics)", "tool": "\(name)", "error": "\(error)"])
            state = .faulted(String(describing: error))
            await reconnectAfterFault()
            return ToolContentRenderer.render(result: Self.faultResult(for: error))
        }
    }

    /// Attempts to restore ``state`` to ``MCPServerState/ready`` after a
    /// mid-call transport fault, using ``lastTransport`` and
    /// ``activeBackoffPolicy`` — the "auto-reconnect" half of
    /// ``call(toolNamed:arguments:)``.
    ///
    /// Never throws: both the "no prior transport" case and a
    /// backoff-exhausted reconnect are logged and swallowed, leaving
    /// ``state`` as whatever the failed attempt(s) left it.
    private func reconnectAfterFault() async {
        guard let lastTransport else {
            logger.error(
                "MCPServer cannot auto-reconnect after a mid-call fault: no prior transport recorded",
                metadata: ["server": "\(identityNameForDiagnostics)"])
            return
        }
        do {
            try await connect(transport: lastTransport, backoffPolicy: activeBackoffPolicy)
            logger.info(
                "MCPServer auto-reconnected after mid-call fault",
                metadata: ["server": "\(identityNameForDiagnostics)"])
        } catch {
            logger.error(
                "MCPServer auto-reconnect after mid-call fault failed",
                metadata: ["server": "\(identityNameForDiagnostics)", "error": "\(error)"])
        }
    }

    /// The rendered-`isError` result ``call(toolNamed:arguments:)`` returns
    /// in place of throwing when a mid-call transport fault occurs.
    ///
    /// - Parameter error: The underlying transport error the call caught.
    /// - Returns: A `CallTool.Result` describing the fault, with `isError`
    ///   set, for ``ToolContentRenderer`` to render.
    private static func faultResult(for error: any Error) -> CallTool.Result {
        CallTool.Result(
            content: [.text(text: "Transport fault: \(error)", annotations: nil, _meta: nil)],
            isError: true
        )
    }

    /// Runs one single-attempt connect, bounded by `timeout` measured
    /// against real wall-clock time — never ``clock`` (see
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
    /// ``state``/``identity``/``discoveredTools`` set by a newer attempt
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

    /// Does the actual work of connecting — the shared body behind both
    /// ``connect(transport:)`` and ``performConnectAttempt(transport:timeout:)``
    /// — mutating ``state``/``identity``/``discoveredTools`` only if
    /// `generation` still matches ``connectGeneration`` by the time this
    /// call would apply its result.
    ///
    /// That guard matters only for a ``performConnectAttempt(transport:timeout:)``
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
    ///   be stale, so ``performConnectAttempt(transport:timeout:)``'s
    ///   detached `Task` still observes failure vs. success correctly.
    private func applyConnect(transport: any Transport, generation: Int) async throws {
        guard generation == connectGeneration else {
            logger.warning(
                "MCPServer skipping a connect attempt already superseded by a newer one",
                metadata: ["server": "\(identityNameForDiagnostics)"])
            return
        }
        lastTransport = transport
        state = .connecting
        if let elicitationCoordinator {
            await declareElicitationCapabilityAndRegisterHandler(coordinator: elicitationCoordinator)
        }
        do {
            let initializeResult = try await client.connect(transport: transport)
            let tools = try await discoverAllTools()
            guard generation == connectGeneration else {
                logger.warning(
                    "MCPServer discarding a stale connect success — a newer attempt has since started",
                    metadata: ["server": "\(identityNameForDiagnostics)"])
                return
            }
            if identity == nil {
                identity = ServerIdentity(
                    name: hostSuppliedName ?? initializeResult.serverInfo.name)
            }
            discoveredTools = tools
            state = .ready
        } catch {
            guard generation == connectGeneration else {
                logger.warning(
                    "MCPServer discarding a stale connect failure — a newer attempt has since started",
                    metadata: ["server": "\(identityNameForDiagnostics)", "error": "\(error)"])
                throw error
            }
            state = .faulted(String(describing: error))
            throw error
        }
    }

    /// Computes the exponential backoff delay to wait before the retry
    /// attempt that follows `attempt`.
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

    // MARK: - Elicitation

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
            await Self.answerElicitation(parameters, coordinator: coordinator)
        }
    }

    /// Routes one server-initiated `elicitation/create` request to
    /// `coordinator`, enforcing the no-secrets-in-form-mode rule (see
    /// ``Elicitation/RequestSchema/requiresURLModeRouting`` and
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
        _ parameters: CreateElicitation.Parameters,
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

/// Serializes exactly one resumption of a `CheckedContinuation` shared by
/// two independent, un-joined `Task`s —
/// ``MCPServer/performConnectAttempt(transport:timeout:)``'s connect
/// attempt and its timeout — racing to finish first.
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

    /// Resumes the wrapped continuation with `result`, unless another call
    /// already has — in which case this is a silent no-op.
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
