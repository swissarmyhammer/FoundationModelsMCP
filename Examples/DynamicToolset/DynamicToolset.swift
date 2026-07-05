import ExampleSupport
import FoundationModelsMCP

/// `DynamicToolset` connects to an `MCPTestServerCLI` subprocess spawned in
/// `dynamic` mode — a toy server that adds, re-schemas, and removes a tool on
/// a timer (`plan.md`'s Examples §7, the live half of M8) — and prints every
/// `ToolCatalog` snapshot as it arrives on `MCPServer/catalogUpdates`: its
/// epoch, its current tool membership, and (from the second snapshot on) a
/// membership/fingerprint diff against the previous one.
///
/// Once the server's whole scripted mutation schedule has played out, this
/// example demonstrates call-time resolution of the tool that vanished along
/// the way: resolving it via `MCPServer.tool(named:)` now returns `nil`, and
/// `MCPServer.toolNoLongerAvailableResult(named:)` renders the structured
/// "no longer available" result a real caller would see.
///
/// Like `CatalogBrowser`, this example never builds a `LanguageModelSession`
/// — it only observes the live catalog stream — so it needs no
/// `SystemLanguageModel` availability check.
@main
struct DynamicToolset {
    /// The `MCPTestServerCLI` `--mode` value starting the timed
    /// add/re-schema/remove scenario (`ServerMode.dynamic`, driven by
    /// `ScriptedServer.startDynamicToolsetScenario()`).
    static let serverMode = "dynamic"

    /// The name of the tool the scripted server adds, then later removes —
    /// must match `ScriptedServer.dynamicToolsetVanishingToolName`. Examples
    /// never import the `MCPTestServer` test-fixture target, so this is a
    /// documented convention between the two, not a shared symbol.
    static let vanishingToolName = "greeter"

    /// How many ``FoundationModelsMCP/ToolCatalog`` snapshots this example
    /// waits for before moving on to the vanished-tool resolution demo: the
    /// initial post-connect snapshot, plus one for each of the scripted
    /// server's three mutations (add, re-schema, remove).
    static let expectedSnapshotCount = 4

    /// Runs the example: connects a `dynamic`-mode `MCPTestServerCLI`
    /// subprocess, prints every catalog snapshot (with a diff against the
    /// previous one) as the scripted server mutates its tool set, then
    /// demonstrates resolving the tool that vanished along the way.
    ///
    /// - Throws: Whatever ``connectExampleServer(mode:clientName:)`` throws.
    static func main() async throws {
        let connected = try await connectExampleServer(mode: serverMode, clientName: "DynamicToolsetExample")
        defer { await connected.shutdown() }

        await printSnapshotsUntilScenarioSettles(server: connected.server)

        print("--- Resolving the vanished tool by name ---")
        let resolved = await connected.server.tool(named: vanishingToolName)
        if resolved == nil {
            print(MCPServer.toolNoLongerAvailableResult(named: vanishingToolName))
        } else {
            print(
                "Expected \"\(vanishingToolName)\" to have vanished by now; the scripted server's mutation schedule may not have finished."
            )
        }
    }

    /// Consumes `server`'s `catalogUpdates` stream, printing
    /// ``CatalogFormatting/summarize(_:)`` for every snapshot and
    /// ``CatalogFormatting/summarize(_:)-(ToolCatalogDiff)`` against the
    /// previous one, until ``expectedSnapshotCount`` snapshots have arrived.
    ///
    /// - Parameter server: The connected server to observe.
    private static func printSnapshotsUntilScenarioSettles(server: MCPServer) async {
        var previous: ToolCatalog?
        var observedCount = 0
        for await snapshot in await server.catalogUpdates {
            print(CatalogFormatting.summarize(snapshot))
            if let previous {
                for line in CatalogFormatting.summarize(snapshot.diff(from: previous)) {
                    print(line)
                }
            }
            previous = snapshot
            observedCount += 1
            if observedCount >= expectedSnapshotCount {
                return
            }
        }
    }
}
