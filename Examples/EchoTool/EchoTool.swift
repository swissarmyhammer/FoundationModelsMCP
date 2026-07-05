import ExampleSupport
import FoundationModels
import FoundationModelsMCP

/// `EchoTool` is the ~20-line hello world of this bridge: spawn
/// `MCPTestServerCLI` in echo mode as a stdio subprocess, wrap it in
/// `MCPServer`, build a `LanguageModelSession(mcp:)` on the system model, and
/// run one prompt that triggers one tool call — plan.md → Examples §1.
@main
struct EchoTool {
    /// The `MCPTestServerCLI` `--mode` value selecting its echo-only tool set.
    static let serverMode = "echo"

    /// Runs the example: spawns the echo-mode `MCPTestServerCLI` subprocess,
    /// connects an `MCPServer` to it, and drives one prompt that triggers one
    /// tool call.
    ///
    /// Prints a clean, non-crashing message and returns early if
    /// `SystemLanguageModel` is unavailable on this machine.
    ///
    /// - Throws: Whatever ``runExample(named:mode:clientName:isAvailable:body:)``
    ///   or `session.respond(to:)` throws.
    static func main() async throws {
        try await runExample(named: "EchoTool", mode: serverMode, clientName: "EchoToolExample") { connected in
            let session = try await LanguageModelSession(
                mcp: connected.server,
                instructions:
                    "You have access to an echo tool that returns its \"text\" argument back verbatim. When asked to echo something, call the echo tool with exactly the requested text."
            )

            let response = try await session.respond(
                to: "Call the echo tool with the text \"hello from EchoTool\" and tell me exactly what it returned."
            )
            print(response.content)
        }
    }
}
