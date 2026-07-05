import ExampleSupport
import FoundationModelsMCP

/// `CatalogBrowser` connects to two spawned `MCPTestServerCLI` subprocesses —
/// one in `catalog` mode (a single tool exercising every M8 catalog field:
/// `title`, full `ToolAnnotations`, icons, a multi-property `inputSchema`)
/// and one in `filesystem` mode (the same multi-tool server `FileAssistant`
/// uses) — and prints each server's full catalog: name, `title`, description,
/// `ToolAnnotations`, icons, the raw `inputSchema`, and the converted
/// `GenerationSchema` — the exact M8 surface `plan.md`'s Examples §6
/// describes, doubling as `FoundationModelsMultitool`'s integration stub (see
/// `Tests/FoundationModelsMCPTests/StubConsumerTests.swift` for the same
/// surface exercised as a test).
///
/// Unlike `EchoTool`/`FileAssistant`/`ToolPicking`/`RemoteHTTP`, this example
/// never builds a `LanguageModelSession` — it only reads ``MCPServer/catalog``,
/// so it needs no `SystemLanguageModel` availability check at all.
@main
struct CatalogBrowser {
    /// The `MCPTestServerCLI` `--mode` value selecting the single tool that
    /// exercises every M8 catalog field.
    static let catalogServerMode = "catalog"

    /// The `MCPTestServerCLI` `--mode` value selecting the same multi-tool
    /// filesystem server `FileAssistant` connects to — the second of the
    /// "one or more servers" this example browses.
    static let filesystemServerMode = "filesystem"

    /// Runs the example: connects one `catalog`-mode and one
    /// `filesystem`-mode `MCPTestServerCLI` subprocess, and prints each
    /// server's full catalog.
    ///
    /// - Throws: Whatever ``connectExampleServer(mode:clientName:)`` or
    ///   `MCPServer.catalog` throws.
    static func main() async throws {
        let catalogServer = try await connectExampleServer(
            mode: catalogServerMode, clientName: "CatalogBrowserExample-catalog")
        defer { await catalogServer.shutdown() }

        let filesystemServer = try await connectExampleServer(
            mode: filesystemServerMode, clientName: "CatalogBrowserExample-filesystem")
        defer { await filesystemServer.shutdown() }

        try await printCatalog(from: catalogServer.server)
        try await printCatalog(from: filesystemServer.server)
    }

    /// Prints `server`'s full catalog: a header naming its identity and
    /// epoch, then every field ``CatalogFormatting/describe(_:)`` renders for
    /// each of its tools.
    ///
    /// - Parameter server: The connected server to print the catalog of.
    /// - Throws: Whatever `MCPServer.catalog` throws.
    private static func printCatalog(from server: MCPServer) async throws {
        let catalog = try await server.catalog
        print("=== Server: \(catalog.identity.name) (epoch \(catalog.epoch)) ===")
        for tool in catalog.tools {
            print("--- Tool: \(tool.name) ---")
            for line in CatalogFormatting.describe(tool) {
                print(line)
            }
        }
    }
}
