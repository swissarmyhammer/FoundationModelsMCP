import MCP

/// One tool ``ScriptedServer`` can serve: its `tools/list` definition paired
/// with the handler that answers `tools/call` for it.
///
/// Tests script new tools — or replace existing ones, see
/// ``ScriptedServer/replaceTool(_:)`` — by constructing one of these
/// directly. ``ScriptedServer``'s own factories (``ScriptedServer/echoTool(named:description:)``,
/// the filesystem-tool factories, the progress/eliciting/dropping tool
/// factories) all build ``ScriptedTool`` values the same way.
public struct ScriptedTool: Sendable {
    /// The `tools/list` definition served for this tool.
    public let definition: MCP.Tool

    /// Answers `tools/call` for this tool.
    public let handler: @Sendable (CallTool.Parameters) async throws -> CallTool.Result

    /// Creates a scripted tool from a definition and its call handler.
    ///
    /// - Parameters:
    ///   - definition: The `tools/list` definition to serve.
    ///   - handler: The closure that answers `tools/call` for this tool.
    public init(
        definition: MCP.Tool,
        handler: @escaping @Sendable (CallTool.Parameters) async throws -> CallTool.Result
    ) {
        self.definition = definition
        self.handler = handler
    }
}
