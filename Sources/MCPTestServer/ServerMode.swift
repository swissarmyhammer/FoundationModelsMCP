/// Which scripted tool set `MCPTestServerCLI` registers on the server it
/// starts, selected via its `--mode` command-line argument.
///
/// Exists so `MCPTestServerCLI`'s stub `main.swift` stays a thin dispatcher —
/// parsing and dispatch live here, in the already-tested `MCPTestServer`
/// library, rather than duplicated as untestable top-level executable code.
/// Added for `Examples/` use: `EchoTool` spawns `MCPTestServerCLI --mode
/// echo`, `FileAssistant` spawns `--mode filesystem`; `.all` preserves the
/// CLI's original stub-level "register everything" behavior for callers
/// (like `Tests/FoundationModelsMCPTests/E2ETests.swift`) that pass no
/// `--mode` flag at all.
public enum ServerMode: String, Sendable {
    /// Registers only ``ScriptedServer/addEchoTool(named:description:)`` —
    /// the tool set `EchoTool` spawns.
    case echo

    /// Registers only ``ScriptedServer/addFilesystemTools(initialFiles:)`` —
    /// the tool set `FileAssistant` spawns.
    case filesystem

    /// Registers both tool sets — the default, matching this CLI's original
    /// stub-level behavior.
    case all

    /// The command-line flag name ``parse(from:)`` searches `arguments` for.
    public static let flagName = "--mode"

    /// Parses a `--mode` argument out of `arguments`, defaulting to ``all``
    /// if the flag is absent, has no following value, or names an
    /// unrecognized mode.
    ///
    /// - Parameter arguments: The command-line arguments to search,
    ///   typically `CommandLine.arguments`.
    /// - Returns: The selected mode, or ``all`` if `arguments` names no
    ///   recognized ``flagName`` value.
    public static func parse(from arguments: [String]) -> ServerMode {
        guard let flagIndex = arguments.firstIndex(of: flagName),
            arguments.indices.contains(flagIndex + 1),
            let mode = ServerMode(rawValue: arguments[flagIndex + 1])
        else {
            return .all
        }
        return mode
    }

    /// Registers this mode's tool set on `server`.
    ///
    /// - Parameter server: The server to register tools on.
    public func registerTools(on server: ScriptedServer) async {
        switch self {
        case .echo:
            await server.addEchoTool()
        case .filesystem:
            await server.addFilesystemTools()
        case .all:
            await server.addEchoTool()
            await server.addFilesystemTools()
        }
    }
}
