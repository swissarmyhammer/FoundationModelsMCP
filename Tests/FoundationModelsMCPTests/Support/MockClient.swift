import FoundationModelsMCP
import MCP

/// Errors thrown by ``MockClient`` itself, distinct from any scripted error.
enum MockClientError: Error, Equatable {
    /// ``MockClient/callTool(name:arguments:)`` was called with no scripted
    /// result queued to answer it.
    case noScriptedResult
}

/// A recording, scriptable test double for ``MCPToolCalling``.
///
/// `MCP.Client` is a concrete `actor` from the swift-sdk and cannot be
/// substituted directly, so tests exercise `MCPToolCalling`-typed code
/// against `MockClient` instead. Every `callTool(name:arguments:)`
/// invocation is recorded exactly, in call order; each call consumes the
/// next queued scripted result (a `CallTool.Result` or an error) in FIFO
/// order. Calling past the end of the script throws
/// ``MockClientError/noScriptedResult``.
///
/// Test-target only — never shipped in the library.
///
/// ## Synchronization invariant
///
/// `@unchecked Sendable` is safe here because each test constructs its own
/// private `MockClient` instance and every call against it — `script(_:)`,
/// `script(throwing:)`, and `callTool(name:arguments:)` — is awaited
/// sequentially from that single test function's task. Swift Testing may run
/// different `@Test` functions concurrently, but that only ever creates
/// *separate* `MockClient` instances on *separate* tasks; no instance is ever
/// shared across tasks or mutated from more than one task at a time. If a
/// future test needs to hand one `MockClient` to concurrently-executing code
/// (e.g. a `TaskGroup` exercising overlapping tool calls), this invariant no
/// longer holds and the mutable state (`invocations`, `scriptedResults`) must
/// move behind an actor or a lock instead.
final class MockClient: MCPToolCalling, @unchecked Sendable {
    /// One recorded `callTool` invocation: the tool name and the arguments
    /// exactly as received.
    struct Invocation: Equatable {
        let name: String
        let arguments: [String: Value]?
    }

    /// Every `callTool` invocation, in call order.
    private(set) var invocations: [Invocation] = []

    /// Scripted results, consumed in FIFO order — one per `callTool` call.
    private var scriptedResults: [Result<CallTool.Result, Error>] = []

    init() {}

    /// Queues a successful result to be returned by the next `callTool` call.
    func script(_ result: CallTool.Result) {
        scriptedResults.append(.success(result))
    }

    /// Queues an error to be thrown by the next `callTool` call.
    func script(throwing error: Error) {
        scriptedResults.append(.failure(error))
    }

    func callTool(name: String, arguments: [String: Value]?) async throws -> CallTool.Result {
        invocations.append(Invocation(name: name, arguments: arguments))
        guard !scriptedResults.isEmpty else {
            throw MockClientError.noScriptedResult
        }
        return try scriptedResults.removeFirst().get()
    }
}
