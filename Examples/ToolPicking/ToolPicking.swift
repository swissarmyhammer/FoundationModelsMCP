import ExampleSupport
import Foundation
import FoundationModels
import FoundationModelsMCP

/// `ToolPicking` demonstrates provider composition: one loose `MCPTool` —
/// a single (server, tool) pair pulled off a connected `MCPServer`, not the
/// whole server — plus a native Swift `Tool` in the same session, showing
/// `MCPToolProvider` flattening (``resolveSessionTools(from:)``) and that MCP
/// and native tools coexist — plan.md → Examples §3.
///
/// `LanguageModelSession(mcp:)`'s variadic initializer only accepts
/// ``MCPToolProvider``-conforming values (``MCPTool``/``MCPServer``); a plain
/// native `FoundationModels.Tool` like ``ClockTool`` doesn't conform to that
/// protocol (see `MCPToolProvider.swift`), so this example resolves the loose
/// `MCPTool` through ``resolveSessionTools(from:)`` directly — the same
/// flattening the `mcp:` convenience wraps — and appends the native tool to
/// the resulting array before constructing the session with the base
/// `LanguageModelSession(model:tools:instructions:)` initializer.
@main
struct ToolPicking {
    /// The `MCPTestServerCLI` `--mode` value selecting its echo-only tool
    /// set, the source of the one loose `MCPTool` this example picks.
    static let serverMode = "echo"

    /// The name of the loose tool pulled off the connected server.
    static let echoToolName = "echo"

    /// Runs the example: spawns the echo-mode `MCPTestServerCLI` subprocess,
    /// pulls one loose `MCPTool` off the connected `MCPServer`, composes it
    /// with a native ``ClockTool``, and drives one prompt.
    ///
    /// Prints a clean, non-crashing message and returns early if
    /// `SystemLanguageModel` is unavailable on this machine.
    ///
    /// - Throws: Whatever ``runExample(named:mode:clientName:isAvailable:body:)``,
    ///   ``resolveSessionTools(from:)``, or `session.respond(to:)` throws.
    static func main() async throws {
        try await runExample(named: "ToolPicking", mode: serverMode, clientName: "ToolPickingExample") {
            connected in
            guard let echoTool = await connected.server.tool(named: echoToolName) else {
                print("Expected the spawned server to have discovered an \"\(echoToolName)\" tool.")
                return
            }

            // The flattening MCPToolProvider composition this example
            // demonstrates: one loose MCPTool, resolved the same way
            // LanguageModelSession(mcp:) resolves its providers internally.
            let providerTools = try await resolveSessionTools(from: [echoTool])
            let session = LanguageModelSession(
                tools: providerTools + [ClockTool()],
                instructions:
                    "You can echo text back with the echo tool, or report the current time with the clock tool."
            )

            let response = try await session.respond(to: "What time is it right now?")
            print(response.content)
        }
    }
}

/// A simple hand-written native `FoundationModels.Tool` reporting the current
/// date and time — composed alongside a loose `MCPTool` in ``ToolPicking``
/// to show native and MCP tools coexisting in one session.
struct ClockTool: FoundationModels.Tool {
    let name = "clock"
    let description = "Reports the current date and time."

    /// This tool takes no arguments.
    @Generable
    struct Arguments {}

    /// Reports the current date and time.
    ///
    /// - Parameter arguments: Ignored — this tool takes no arguments.
    /// - Returns: The current date and time, ISO 8601-formatted.
    func call(arguments: Arguments) async throws -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}
