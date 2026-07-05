import MCP

/// Which scripted tool set `MCPTestServerCLI` registers on the server it
/// starts, selected via its `--mode` command-line argument.
///
/// Exists so `MCPTestServerCLI`'s stub `main.swift` stays a thin dispatcher —
/// parsing and dispatch live here, in the already-tested `MCPTestServer`
/// library, rather than duplicated as untestable top-level executable code.
/// Added for `Examples/` use: `EchoTool` spawns `MCPTestServerCLI --mode
/// echo`, `FileAssistant` spawns `--mode filesystem`, `ElicitingAgent` spawns
/// `--mode eliciting`, `CatalogBrowser` spawns `--mode catalog` (alongside a
/// `--mode filesystem` second server), and `DynamicToolset` spawns `--mode
/// dynamic`; `.all` preserves the CLI's original stub-level "register
/// everything" behavior for callers (like
/// `Tests/FoundationModelsMCPTests/E2ETests.swift`) that pass no `--mode` flag
/// at all.
public enum ServerMode: String, Sendable {
    /// Registers only ``ScriptedServer/addEchoTool(named:description:)`` —
    /// the tool set `EchoTool` spawns.
    case echo

    /// Registers only ``ScriptedServer/addFilesystemTools(initialFiles:)`` —
    /// the tool set `FileAssistant` spawns.
    case filesystem

    /// Registers only an elicit-on-command tool (via
    /// ``ScriptedServer/addElicitingTool(named:message:requestedSchema:)``) —
    /// the server-initiated half of `ElicitingAgent`'s "both elicitation
    /// directions" demo.
    case eliciting

    /// Registers only ``ScriptedServer/addCatalogShowcaseTool(named:)`` — a
    /// single tool exercising every M8 catalog-facing field (`title`, full
    /// ``ToolAnnotations``, icons, a multi-property `inputSchema`), the tool
    /// set one of `CatalogBrowser`'s spawned servers presents.
    case catalog

    /// Starts ``ScriptedServer/startDynamicToolsetScenario()`` — a tool set
    /// that adds, re-schemas, and removes a tool on a timer, the tool set
    /// `DynamicToolset` spawns.
    case dynamic

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

    /// The tool name ``eliciting`` registers — read by `Examples/ElicitingAgent`
    /// as its own local constant (examples never import this test-fixture
    /// target; the name is a documented convention between the two, not a
    /// shared symbol).
    public static let elicitOnCommandToolName = "elicit_on_command"

    /// The elicitation prompt ``eliciting``'s tool sends.
    private static let elicitOnCommandMessage = "What is your favorite color?"

    /// The elicitation `requestedSchema` ``eliciting``'s tool sends: one
    /// required, ordinary (non-sensitive) string field.
    private static let elicitOnCommandRequestedSchema = Elicitation.RequestSchema(
        properties: ["favoriteColor": .object(["type": .string("string")])],
        required: ["favoriteColor"]
    )

    /// Registers this mode's tool set on `server`.
    ///
    /// - Parameter server: The server to register tools on.
    public func registerTools(on server: ScriptedServer) async {
        switch self {
        case .echo:
            await server.addEchoTool()
        case .filesystem:
            await server.addFilesystemTools()
        case .eliciting:
            await server.addElicitingTool(
                named: Self.elicitOnCommandToolName,
                message: Self.elicitOnCommandMessage,
                requestedSchema: Self.elicitOnCommandRequestedSchema
            )
        case .catalog:
            await server.addCatalogShowcaseTool()
        case .dynamic:
            await server.startDynamicToolsetScenario()
        case .all:
            await server.addEchoTool()
            await server.addFilesystemTools()
        }
    }
}
