import FoundationModels
import FoundationModelsMCP
import MCP

/// An ``MCPServer`` connected to a spawned ``ExampleServerProcess``, plus the
/// process backing it — the "spawn `MCPTestServerCLI`, connect an
/// `MCPServer`" pattern shared by `EchoTool`, `FileAssistant`, and
/// `ToolPicking`.
public struct ConnectedExampleServer: Sendable {
    /// The connected server.
    public let server: MCPServer

    /// The subprocess backing ``server``'s transport.
    public let process: ExampleServerProcess

    /// Disconnects ``server``, then shuts down ``process`` — in that order,
    /// so the subprocess is only killed once the client side has already
    /// disconnected (mirroring `Tests/FoundationModelsMCPTests/E2ETests.swift`'s
    /// teardown ordering).
    public func shutdown() async {
        await server.disconnect()
        process.shutdown()
    }
}

/// Spawns `MCPTestServerCLI` in `mode` and connects a fresh ``MCPServer``
/// named `clientName` to it.
///
/// - Parameters:
///   - mode: The `ServerMode` raw value to pass via `--mode` (see
///     ``ExampleServerProcess/spawn(mode:)``).
///   - clientName: The display name for the `MCP.Client` backing the
///     returned server.
/// - Returns: The connected server and the process backing it, for a single
///   `defer { await connected.shutdown() }` at the call site.
/// - Throws: Whatever ``ExampleServerProcess/spawn(mode:)`` or
///   `MCPServer.connect(transport:)` throws.
public func connectExampleServer(mode: String, clientName: String) async throws -> ConnectedExampleServer {
    let process = try ExampleServerProcess.spawn(mode: mode)
    let server = MCPServer(client: Client(name: clientName, version: "1.0"))
    try await server.connect(transport: process.transport)
    return ConnectedExampleServer(server: server, process: process)
}

/// Guards on `SystemLanguageModel` availability, then spawns and connects a
/// ``ConnectedExampleServer`` — the "check the model is available, then
/// spawn `MCPTestServerCLI` and connect" bootstrap shared by `EchoTool`,
/// `FileAssistant`, and `ToolPicking`'s `main()` entry points.
///
/// - Parameters:
///   - exampleName: The example's display name, forwarded to
///     ``checkSystemLanguageModelAvailable(exampleName:isAvailable:)``.
///   - mode: The `ServerMode` raw value forwarded to
///     ``connectExampleServer(mode:clientName:)``.
///   - clientName: The `MCP.Client` display name forwarded to
///     ``connectExampleServer(mode:clientName:)``.
///   - isAvailable: Whether the system language model is available. Defaults
///     to `SystemLanguageModel.default.isAvailable`; overridable so this
///     function is directly testable without a real model or subprocess.
/// - Returns: The connected server, or `nil` (after printing a clean
///   message, never spawning a subprocess) if `isAvailable` is `false`.
/// - Throws: Whatever ``connectExampleServer(mode:clientName:)`` throws.
public func requireExampleServer(
    exampleName: String,
    mode: String,
    clientName: String,
    isAvailable: Bool = SystemLanguageModel.default.isAvailable
) async throws -> ConnectedExampleServer? {
    guard checkSystemLanguageModelAvailable(exampleName: exampleName, isAvailable: isAvailable) else {
        return nil
    }
    return try await connectExampleServer(mode: mode, clientName: clientName)
}

/// Runs `body` with a connected ``ConnectedExampleServer``, guarding on
/// `SystemLanguageModel` availability first and always disconnecting and
/// shutting down afterward — the full "check the model is available, spawn
/// `MCPTestServerCLI` and connect, run the example, always tear down"
/// bootstrap shared by `EchoTool`, `FileAssistant`, and `ToolPicking`'s
/// `main()` entry points.
///
/// - Parameters:
///   - exampleName: Forwarded to
///     ``requireExampleServer(exampleName:mode:clientName:isAvailable:)``.
///   - mode: Forwarded to
///     ``requireExampleServer(exampleName:mode:clientName:isAvailable:)``.
///   - clientName: Forwarded to
///     ``requireExampleServer(exampleName:mode:clientName:isAvailable:)``.
///   - isAvailable: Whether the system language model is available. Defaults
///     to `SystemLanguageModel.default.isAvailable`; overridable so this
///     function is directly testable without a real model or subprocess.
///   - body: Run with the connected server once it's ready. Never invoked
///     (with no subprocess ever spawned) if `isAvailable` is `false`.
/// - Throws: Whatever
///   ``requireExampleServer(exampleName:mode:clientName:isAvailable:)`` or
///   `body` throws.
///
/// `@MainActor`-isolated to match `@main` executable entry points' own
/// isolation — every `Examples/` caller's `static func main()` runs on the
/// main actor, and without matching isolation here, passing `body` (an
/// ordinary, non-`Sendable` closure capturing the caller's local state)
/// across an isolation boundary would be a compile error under Swift 6's
/// strict concurrency checking.
@MainActor
public func runExample(
    named exampleName: String,
    mode: String,
    clientName: String,
    isAvailable: Bool = SystemLanguageModel.default.isAvailable,
    body: (ConnectedExampleServer) async throws -> Void
) async throws {
    guard
        let connected = try await requireExampleServer(
            exampleName: exampleName, mode: mode, clientName: clientName, isAvailable: isAvailable)
    else {
        return
    }
    defer { await connected.shutdown() }
    try await body(connected)
}
