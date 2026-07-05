import ExampleSupport
import FoundationModels
import FoundationModelsMCP

/// `FileAssistant` demonstrates a real multi-tool server: spawns
/// `MCPTestServerCLI` in filesystem mode (`list_files`/`read_file`/
/// `write_file`) as a stdio subprocess, direct-adds the whole `MCPServer` to
/// a session, and drives natural prompts so the model picks among several
/// tools — including a missing-file prompt that demonstrates `isError`
/// bubbling the model recovers from in-session — plan.md → Examples §2.
@main
struct FileAssistant {
    /// The `MCPTestServerCLI` `--mode` value selecting its filesystem-only
    /// tool set.
    static let serverMode = "filesystem"

    /// A file name never written during this example, so asking about it
    /// demonstrates `read_file`'s `isError` result and the model's recovery.
    static let missingFileName = "config.yaml"

    /// Runs the example: spawns the filesystem-mode `MCPTestServerCLI`
    /// subprocess, connects an `MCPServer` to it, and drives three natural
    /// prompts — write, list, and a missing-file read that demonstrates
    /// `isError` bubbling.
    ///
    /// Prints a clean, non-crashing message and returns early if
    /// `SystemLanguageModel` is unavailable on this machine.
    ///
    /// - Throws: Whatever ``runExample(named:mode:clientName:isAvailable:body:)``
    ///   or any `session.respond(to:)` call throws.
    static func main() async throws {
        try await runExample(named: "FileAssistant", mode: serverMode, clientName: "FileAssistantExample") {
            connected in
            let session = try await LanguageModelSession(
                mcp: connected.server,
                instructions:
                    "You have access to a virtual filesystem with list_files, read_file, and write_file tools. Use them to answer the user's questions about files, and let them know clearly if a file doesn't exist."
            )

            print("--- Writing a file ---")
            let writeResponse = try await session.respond(
                to: "Create a file named readme.txt containing the text \"Hello from FileAssistant\".")
            print(writeResponse.content)

            print("--- Listing files ---")
            let listResponse = try await session.respond(to: "What files are available? List them.")
            print(listResponse.content)

            print("--- Reading a missing file (demonstrates isError bubbling) ---")
            let missingResponse = try await session.respond(to: "What's in \(missingFileName)?")
            print(missingResponse.content)
        }
    }
}
