import MCP

/// The subset of `MCP.Client`'s tool-calling surface this library depends on.
///
/// `MCP.Client` is a concrete `actor` in the swift-sdk — it cannot be
/// subclassed, mocked, or otherwise substituted for tests. `MCPToolCalling`
/// is a deliberate, narrow seam whose only purpose is substitutability: code
/// that needs to call a tool (the future `MCPTool` adapter, see `plan.md`)
/// depends on `any MCPToolCalling` instead of `MCP.Client` directly, so a
/// test double can stand in for the real connection. This is *not* a bespoke
/// re-model of MCP's domain types — the requirement's shape and the values
/// that flow through it (`Value`, `CallTool.Result`) are exactly the
/// swift-sdk's own types; only the receiver is abstracted.
///
/// `MCP.Client` conforms to this protocol via the extension below.
public protocol MCPToolCalling: Sendable {
    /// Calls a tool on the server and returns its full result.
    ///
    /// - Parameters:
    ///   - name: The name of the tool to call.
    ///   - arguments: Arguments to use for the tool call.
    /// - Returns: The `tools/call` result — content, `isError`, and any
    ///   `structuredContent` — exactly as the server returned it.
    /// - Throws: Whatever the underlying transport/connection throws.
    func callTool(name: String, arguments: [String: Value]?) async throws -> CallTool.Result
}

extension Client: MCPToolCalling {
    /// Conforms `MCP.Client` to ``MCPToolCalling``.
    ///
    /// `Client` already declares two `callTool(name:arguments:meta:)`
    /// overloads, but neither fits directly: the async one returns only
    /// `(content: [Tool.Content], isError: Bool?)` — discarding
    /// `structuredContent` — and the synchronous, throwing one that returns
    /// `RequestContext<CallTool.Result>` shares the exact same parameter
    /// list, so calling it by name from here is ambiguous with the async
    /// overload rather than a clean override. Both overloads' capability
    /// check (`validateServerCapability`) is also `private` to `Client` and
    /// so isn't reachable from this extension either way. This conformance
    /// therefore builds the `tools/call` request directly and goes through
    /// the public `send(_:)` (which returns a `RequestContext<CallTool.Result>`,
    /// same as the SDK's own advanced-use overload), awaiting `value` to get
    /// the full result.
    public func callTool(name: String, arguments: [String: Value]?) async throws -> CallTool.Result {
        let context = try send(CallTool.request(.init(name: name, arguments: arguments)))
        return try await context.value
    }
}
