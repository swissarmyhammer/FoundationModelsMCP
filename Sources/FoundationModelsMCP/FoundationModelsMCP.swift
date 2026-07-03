import FoundationModels

/// FoundationModelsMCP bridges Apple's FoundationModels `LanguageModelSession`
/// to tools served by any Model Context Protocol (MCP) server, using the
/// official `MCP` swift-sdk for all protocol, transport, and connection
/// concerns. See `plan.md` at the repository root for the full design.
public enum FoundationModelsMCP {
    /// The MCP protocol revision this package targets.
    ///
    /// - SeeAlso: `docs/swift-sdk-notes.md`
    public static let targetedProtocolRevision = "2025-11-25"
}
