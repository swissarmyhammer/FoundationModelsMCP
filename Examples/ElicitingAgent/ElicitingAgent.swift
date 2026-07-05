import ExampleSupport
import FoundationModels
import FoundationModelsMCP

/// `ElicitingAgent` demonstrates both elicitation directions `plan.md`'s
/// Examples §5 describes, both routed through one console
/// ``ConsoleElicitationCoordinator``:
/// 1. **Server-initiated**: calling the spawned `MCPTestServerCLI`'s
///    elicit-on-command tool (`--mode eliciting`, `ServerMode.eliciting`)
///    directly, mid-call, pauses with `elicitation/create` — the
///    `MCPServer`-routed direction.
/// 2. **Agent-initiated**: the model calling `MCPElicitationTool` (`ask_user`)
///    to ask the user a structured question in-conversation — the
///    tool-routed direction.
///
/// Runs the server-initiated direction three times, cycling the
/// coordinator's deterministic fallback through accept, decline, and cancel
/// (per `plan.md`'s "shows accept / decline / cancel at the terminal"), then
/// the agent-initiated direction once — demonstrating all three actions
/// across both directions from one shared coordinator instance.
@main
struct ElicitingAgent {
    /// The `MCPTestServerCLI` `--mode` value registering the elicit-on-command
    /// tool.
    static let serverMode = "eliciting"

    /// The elicit-on-command tool's name — must match
    /// `ServerMode.elicitOnCommandToolName`. Examples never import the
    /// `MCPTestServer` test-fixture target, so this is a documented
    /// convention between the two, not a shared symbol.
    static let elicitOnCommandToolName = "elicit_on_command"

    /// How many times ``demonstrateServerInitiatedElicitation(server:)`` calls
    /// the elicit-on-command tool — matches
    /// ``ConsoleElicitationCoordinator/Action``'s three cases, so a
    /// non-interactive run's fallback rotation demonstrates all of them.
    static let serverInitiatedAttempts = 3

    /// Runs the example: connects an `eliciting`-mode `MCPTestServerCLI`
    /// subprocess with a shared ``ConsoleElicitationCoordinator``, drives the
    /// server-initiated direction ``serverInitiatedAttempts`` times, then the
    /// agent-initiated direction once.
    ///
    /// Prints a clean, non-crashing message and returns early if
    /// `SystemLanguageModel` is unavailable on this machine — needed for the
    /// agent-initiated half, which builds a `LanguageModelSession`.
    ///
    /// - Throws: Whatever ``runExample(named:mode:clientName:elicitationCoordinator:isAvailable:body:)``,
    ///   ``MCPElicitationTool/init(coordinator:)``, or `session.respond(to:)`
    ///   throws.
    static func main() async throws {
        let coordinator = ConsoleElicitationCoordinator()
        try await runExample(
            named: "ElicitingAgent", mode: serverMode, clientName: "ElicitingAgentExample",
            elicitationCoordinator: coordinator
        ) { connected in
            await demonstrateServerInitiatedElicitation(server: connected.server)
            try await demonstrateAgentInitiatedElicitation(coordinator: coordinator)
        }
    }

    /// Demonstrates server-initiated elicitation: calls
    /// ``elicitOnCommandToolName`` directly, ``serverInitiatedAttempts``
    /// times, printing each rendered result.
    ///
    /// - Parameter server: The connected server to call the tool on.
    private static func demonstrateServerInitiatedElicitation(server: MCPServer) async {
        print("=== Server-initiated elicitation: calling \"\(elicitOnCommandToolName)\" directly ===")
        for attempt in 1...serverInitiatedAttempts {
            print("--- Attempt \(attempt) ---")
            print(await server.call(toolNamed: elicitOnCommandToolName))
        }
    }

    /// Demonstrates agent-initiated elicitation: builds a
    /// `LanguageModelSession` with `MCPElicitationTool` routed to
    /// `coordinator`, and prompts the model to ask the user a structured
    /// question.
    ///
    /// - Parameter coordinator: The coordinator `MCPElicitationTool` routes
    ///   to — the same instance ``demonstrateServerInitiatedElicitation(server:)``
    ///   already exercised.
    /// - Throws: Whatever ``MCPElicitationTool/init(coordinator:)`` or
    ///   `session.respond(to:)` throws.
    private static func demonstrateAgentInitiatedElicitation(
        coordinator: ConsoleElicitationCoordinator
    ) async throws {
        print("=== Agent-initiated elicitation: the model calling MCPElicitationTool ===")
        let session = LanguageModelSession(
            tools: [try MCPElicitationTool(coordinator: coordinator)],
            instructions:
                "You have an ask_user tool for asking the user structured questions. Use it to ask the user what their favorite season is, then report their answer."
        )
        let response = try await session.respond(
            to: "Ask the user what their favorite season is, then tell me their answer.")
        print(response.content)
    }
}
