import Foundation

/// A per-call timeout deadline that ``resetForProgress()`` proves is still
/// alive, without itself performing any waiting.
///
/// Deliberately holds no `Clock` or `Instant` state of its own — just a
/// reset-count bump that ``MCPServer``'s timeout-enforcement loop (see
/// `MCPServer.resultOrTimeout(toolName:context:progressToken:timeout:)`)
/// compares before and after each `Task.sleep(for: timeout)`, to detect
/// whether a `notifications/progress` reset the deadline while it slept: if
/// the count is unchanged, the sleep ran to completion with no intervening
/// progress, so the call has genuinely timed out; if it changed, progress
/// proved the call still alive and the loop sleeps for another full
/// ``timeout`` window.
///
/// Factoring the arithmetic out to this trivial, pure struct is what lets
/// its "did a reset happen" logic be unit tested directly, without racing
/// real concurrency or depending on a `Clock`'s actual suspension behavior —
/// see `Tests/FoundationModelsMCPTests/CancellationTests.swift`.
struct CallDeadline: Sendable, Equatable {
    /// The full timeout duration a reset restores.
    let timeout: Duration

    /// Bumped by every ``resetForProgress()`` call — the timeout-enforcement
    /// loop's signal that progress arrived since it last checked.
    private(set) var resetCount = 0

    /// Creates a fresh deadline for a call that has not yet received any
    /// progress.
    ///
    /// - Parameter timeout: The full timeout duration a reset restores.
    init(timeout: Duration) {
        self.timeout = timeout
    }

    /// Records that a `notifications/progress` update arrived for this
    /// call, proving it is still alive.
    mutating func resetForProgress() {
        resetCount += 1
    }
}
