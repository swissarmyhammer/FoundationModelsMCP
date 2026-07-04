import struct Foundation.Data
import Logging
import MCP

/// A `Transport` wrapper whose `connect()` blocks until ``release()`` is
/// called, then delegates to the wrapped transport — lets a test control
/// exactly when an in-flight connect attempt resolves, independent of how
/// long a race against ``BackoffPolicy/connectTimeout`` has already taken.
///
/// This is what makes it possible to prove
/// ``MCPServer/connect(transport:backoffPolicy:)``'s exhaustion path is
/// safe against a *late-resolving* (not just a permanently-hung, like
/// ``HangingTransport``) abandoned attempt: hold the gate closed past
/// `connectTimeout` so the retry loop gives up and throws
/// `MCPServerError.backoffExhausted`, then call ``release()`` afterward
/// and confirm the orphaned attempt's now-late success is discarded rather
/// than clobbering state.
///
/// Like ``FlakyConnectTransport``, `receive()`'s non-`async` requirement
/// means the wrapped transport's receive stream must be cached during
/// ``connect()`` rather than fetched lazily inside ``receive()`` itself.
actor GatedConnectTransport: Transport {
    private let wrapped: any Transport
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var released = false
    private var wrappedReceiveStream: AsyncThrowingStream<Data, Swift.Error>?

    /// The logger to report transport-related events to, supplied via
    /// ``init(wrapping:logger:)`` (or a no-op default).
    nonisolated let logger: Logger

    /// Creates a gated wrapper around `wrapped`, with the gate initially
    /// closed.
    ///
    /// - Parameters:
    ///   - wrapped: The transport to delegate to once released.
    ///   - logger: The logger to report transport-related events to.
    ///     Defaults to a no-op logger, matching every other transport
    ///     double in this fixture set.
    init(wrapping wrapped: any Transport, logger: Logger? = nil) {
        self.wrapped = wrapped
        self.logger =
            logger
            ?? Logger(
                label: "mcp.transport.gated-connect",
                factory: { _ in SwiftLogNoOpLogHandler() }
            )
    }

    /// Blocks until ``release()`` is called, then delegates to the wrapped
    /// transport's `connect()` and caches its receive stream.
    ///
    /// - Throws: Whatever the wrapped transport's `connect()` throws.
    func connect() async throws {
        if !released {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                releaseContinuation = continuation
            }
        }
        try await wrapped.connect()
        wrappedReceiveStream = await wrapped.receive()
    }

    /// Opens the gate: resumes a `connect()` call already blocked on it,
    /// and lets every future `connect()` call proceed immediately.
    func release() {
        released = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    /// Delegates the disconnect to the wrapped transport.
    func disconnect() async {
        await wrapped.disconnect()
    }

    /// Delegates the send operation to the wrapped transport.
    ///
    /// - Parameter data: The raw bytes to send.
    /// - Throws: Whatever the wrapped transport's `send(_:)` throws.
    func send(_ data: Data) async throws {
        try await wrapped.send(data)
    }

    /// Returns the wrapped transport's receive stream, cached by the most
    /// recent successful ``connect()``.
    ///
    /// - Returns: The cached stream, or an already-finished empty stream if
    ///   called before any successful ``connect()``.
    func receive() -> AsyncThrowingStream<Data, Swift.Error> {
        guard let wrappedReceiveStream else {
            return AsyncThrowingStream { $0.finish() }
        }
        return wrappedReceiveStream
    }
}
