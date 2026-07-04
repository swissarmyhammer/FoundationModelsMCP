import struct Foundation.Data
import Logging
import MCP

/// A `Transport` wrapper that fails the first `failingConnectAttempts` calls
/// to `connect()` with a scripted error, then delegates to the wrapped
/// transport on every attempt after — scenario 6, "fail-N-times-then-succeed
/// connects."
///
/// Neither `Client.connect(transport:)` nor `Server.start(transport:)` has a
/// first-class notion of "retry my handshake N times" — they each just call
/// `transport.connect()` once. Scripting a flaky handshake therefore means
/// intercepting that one call, which is exactly what this wrapper does; it
/// forwards every other `Transport` requirement to the wrapped transport.
///
/// `Transport.receive()` is a non-`async` requirement, so a wrapper actor
/// can't cross into a *different* actor (the wrapped transport) to fetch its
/// stream from directly inside `receive()`'s body — that would require
/// `await` in a synchronous function. Instead, ``connect()`` fetches and
/// caches the wrapped transport's receive stream right after delegating
/// successfully (mirroring how every real caller already sequences
/// `connect()` before `receive()`), and ``receive()`` just returns the
/// cached stream synchronously.
public actor FlakyConnectTransport: Transport {
    private let wrapped: any Transport
    private var remainingFailures: Int
    private let failureError: any Swift.Error
    private var wrappedReceiveStream: AsyncThrowingStream<Data, Swift.Error>?

    /// This transport's logger — `nonisolated` per the `Transport` protocol's
    /// own requirement (see the ``init(wrapping:failingConnectAttempts:error:logger:)``
    /// `logger` parameter for why it isn't sourced from the wrapped transport).
    public nonisolated let logger: Logger

    /// How many `connect()` calls have been made so far, successful or not.
    public private(set) var connectAttempts = 0

    /// Creates a flaky wrapper around `wrapped`.
    ///
    /// - Parameters:
    ///   - wrapped: The transport to delegate to once the scripted failures
    ///     are exhausted.
    ///   - failingConnectAttempts: How many leading `connect()` calls should
    ///     fail. `0` means every call delegates immediately.
    ///   - error: The error thrown on each failing attempt. Defaults to
    ///     `MCPError.connectionClosed`.
    ///   - logger: The logger to report transport-related events to.
    ///     Defaults to a no-op logger — `Transport.logger` is also a
    ///     `nonisolated` requirement that can't be read off `wrapped` (an
    ///     existential actor reference) without an actor hop; a fresh no-op
    ///     logger avoids that entirely, matching `InMemoryTransport`'s own
    ///     default.
    public init(
        wrapping wrapped: any Transport,
        failingConnectAttempts: Int,
        error: any Swift.Error = MCPError.connectionClosed,
        logger: Logger? = nil
    ) {
        self.wrapped = wrapped
        self.remainingFailures = failingConnectAttempts
        self.failureError = error
        self.logger =
            logger
            ?? Logger(
                label: "mcp.transport.flaky-connect",
                factory: { _ in SwiftLogNoOpLogHandler() }
            )
    }

    /// Fails with the scripted error while failures remain, otherwise
    /// delegates to the wrapped transport's `connect()` and caches its
    /// receive stream for ``receive()``.
    public func connect() async throws {
        connectAttempts += 1
        guard remainingFailures <= 0 else {
            remainingFailures -= 1
            throw failureError
        }
        try await wrapped.connect()
        wrappedReceiveStream = await wrapped.receive()
    }

    /// Delegates the disconnect to the wrapped transport.
    public func disconnect() async {
        await wrapped.disconnect()
    }

    /// Delegates the send operation to the wrapped transport.
    public func send(_ data: Data) async throws {
        try await wrapped.send(data)
    }

    /// Returns the wrapped transport's receive stream, cached by the most
    /// recent successful ``connect()``.
    ///
    /// - Returns: The cached stream, or an already-finished empty stream if
    ///   called before any successful ``connect()``.
    public func receive() -> AsyncThrowingStream<Data, Swift.Error> {
        guard let wrappedReceiveStream else {
            return AsyncThrowingStream { $0.finish() }
        }
        return wrappedReceiveStream
    }
}
