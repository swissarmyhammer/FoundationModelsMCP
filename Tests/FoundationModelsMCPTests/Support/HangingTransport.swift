import struct Foundation.Data
import Logging
import MCP

/// A `Transport` whose `connect()` never returns and never checks
/// `Task.isCancelled` — simulating a genuinely wedged real-world transport
/// (a stuck subprocess spawn, a stalled TCP/HTTP handshake) that never
/// observes cooperative cancellation, so ``MCPServer``'s per-attempt
/// ``BackoffPolicy/connectTimeout`` can be proven to actually bound
/// wall-clock time — not just be the error type thrown in the easy,
/// fast-failing case every other scripted transport in this fixture set
/// exercises.
///
/// Deliberately **not** `Task.sleep(for:)`: that suspends via the Swift
/// runtime's own cancellation-aware timer, so a `withThrowingTaskGroup`
/// race that cancels its losing child (as `MCPServer`'s per-attempt
/// timeout *used* to, before it was rewritten to fix exactly this
/// insufficiently-realistic-hang gap) would still return promptly against
/// it — `Task.sleep(for:)` throws `CancellationError` as soon as it's
/// cancelled, masking the very bug this double exists to catch. Blocking
/// instead on a `withCheckedContinuation` that's never resumed and
/// installs no cancellation handler genuinely never returns once
/// suspended, regardless of any cancellation the calling task later
/// receives — the only way to prove a fix actually stopped joining the
/// loser task, rather than merely relying on the loser's own
/// cancellation-cooperativeness.
actor HangingTransport: Transport {
    /// A no-op logger; this double never connects, so nothing is ever
    /// logged through it.
    nonisolated let logger = Logger(
        label: "mcp.transport.hanging",
        factory: { _ in SwiftLogNoOpLogHandler() }
    )

    /// Never returns, and does not respond to cancellation — suspends on a
    /// continuation that is never resumed.
    func connect() async throws {
        await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in
            // Never resumed: this is the point.
        }
    }

    /// This stub transport has nothing to disconnect.
    func disconnect() async {}

    /// Always throws: this double never reaches a connected state.
    func send(_ data: Data) async throws {
        throw MCPError.internalError("HangingTransport never connects")
    }

    /// Returns an empty receive stream; this hanging transport never
    /// connects and produces no data.
    func receive() -> AsyncThrowingStream<Data, Swift.Error> {
        AsyncThrowingStream { _ in }
    }
}
