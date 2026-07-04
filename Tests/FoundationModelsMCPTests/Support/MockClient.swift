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
