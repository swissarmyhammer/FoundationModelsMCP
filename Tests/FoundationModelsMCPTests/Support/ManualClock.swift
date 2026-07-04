import Synchronization

/// An `InstantProtocol` conformance tracking elapsed time as a plain
/// `Duration` offset from an arbitrary zero point — the associated `Instant`
/// type for ``ManualClock``.
struct ManualInstant: InstantProtocol {
    /// The elapsed time since ``ManualClock``'s zero point.
    var offset: Duration

    /// Orders instants by their offset from the clock's zero point.
    static func < (lhs: ManualInstant, rhs: ManualInstant) -> Bool {
        lhs.offset < rhs.offset
    }

    /// Returns an instant `duration` after this one.
    ///
    /// - Parameter duration: The amount of time to advance by.
    /// - Returns: A new ``ManualInstant`` `duration` later than `self`.
    func advanced(by duration: Duration) -> ManualInstant {
        ManualInstant(offset: offset + duration)
    }

    /// The amount of time between this instant and `other`.
    ///
    /// - Parameter other: The instant to measure the distance to.
    /// - Returns: `other`'s offset minus this instant's offset.
    func duration(to other: ManualInstant) -> Duration {
        other.offset - offset
    }
}

/// A `Clock` whose `sleep(until:tolerance:)` never waits in real wall-clock
/// time — it advances its own tracked ``ManualInstant`` to (at least) the
/// requested deadline and records the requested duration, then returns
/// immediately.
///
/// This is the "injected/virtual clock" the resilience task requires:
/// ``MCPServer/connect(transport:backoffPolicy:)``'s retry loop sleeps
/// between attempts via `any Clock<Duration>` rather than a hardcoded
/// `ContinuousClock`, so a test can substitute this clock and exercise a
/// full multi-attempt exponential-backoff schedule without any real delay,
/// then assert on ``recordedSleeps`` — the exact schedule requested.
///
/// State lives behind a `Mutex` (rather than `NSLock`, whose `lock()`/
/// `unlock()` are unavailable from async contexts under Swift 6's strict
/// concurrency checking) since ``sleep(until:tolerance:)`` — a `Clock`
/// requirement — is itself `async`.
final class ManualClock: Clock, Sendable {
    typealias Duration = Swift.Duration

    private struct State {
        var currentInstant = ManualInstant(offset: .zero)
        var sleeps: [Swift.Duration] = []
    }

    private let state = Mutex(State())

    /// Every duration requested via `sleep(until:tolerance:)`, in call
    /// order — the backoff schedule a test asserts against.
    var recordedSleeps: [Swift.Duration] {
        state.withLock { $0.sleeps }
    }

    /// The clock's current virtual instant, advanced only by calls to
    /// ``sleep(until:tolerance:)``.
    var now: ManualInstant {
        state.withLock { $0.currentInstant }
    }

    /// No meaningful minimum resolution: a manual clock has no real
    /// scheduling granularity.
    var minimumResolution: Swift.Duration { .zero }

    /// Records the requested delay (`currentInstant` to `deadline`) and
    /// advances ``now`` to `deadline`, without ever suspending for real
    /// wall-clock time.
    ///
    /// - Parameters:
    ///   - deadline: The instant to "sleep" until.
    ///   - tolerance: Ignored — a manual clock has no scheduling jitter to
    ///     tolerate.
    func sleep(until deadline: ManualInstant, tolerance: Swift.Duration?) async throws {
        state.withLock { current in
            current.sleeps.append(current.currentInstant.duration(to: deadline))
            if deadline > current.currentInstant {
                current.currentInstant = deadline
            }
        }
    }
}
