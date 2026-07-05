import Foundation
import Testing

import MCP

@testable import ElicitingAgent
@testable import ExampleSupport
@testable import FoundationModelsMCP
@testable import RemoteHTTP

/// Coverage for the non-model helper logic behind the `Examples/` targets —
/// the pieces that don't require a live `SystemLanguageModel` or a real
/// spawned subprocess/HTTP server to test directly:
///
/// - ``ExampleServerProcess``'s `MCPTestServerCLI`-locating plumbing, shared
///   by `EchoTool`, `FileAssistant`, and `ToolPicking`.
/// - `RemoteHTTP`'s host-supplied bearer token injection into
///   `HTTPClientTransport`'s `requestModifier`.
/// - ``CatalogFormatting``'s per-tool field dump (`CatalogBrowser`) and
///   snapshot/diff summaries (`DynamicToolset`).
/// - ``ConsoleElicitationCoordinator``'s scripted-fallback rotation and
///   placeholder content construction (`ElicitingAgent`).
@Suite("ExampleHelper")
struct ExampleHelperTests {

    // MARK: - ExampleServerProcess

    @Test("executableURL(productsDirectory:) finds an executable MCPTestServerCLI in the given directory")
    func executableURLFindsExecutableFile() throws {
        let directory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cliPath = directory.appendingPathComponent("MCPTestServerCLI")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: cliPath)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cliPath.path)

        let found = try ExampleServerProcess.executableURL(productsDirectory: directory)

        #expect(found == cliPath)
    }

    @Test("executableURL(productsDirectory:) throws testServerCLINotFound when no MCPTestServerCLI exists there")
    func executableURLThrowsWhenMissing() throws {
        let directory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(throws: ExampleServerProcessError.self) {
            try ExampleServerProcess.executableURL(productsDirectory: directory)
        }
    }

    @Test("executableURL(productsDirectory:) throws when a file exists at the path but isn't executable")
    func executableURLThrowsWhenNotExecutable() throws {
        let directory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cliPath = directory.appendingPathComponent("MCPTestServerCLI")
        try Data("not executable".utf8).write(to: cliPath)

        #expect(throws: ExampleServerProcessError.self) {
            try ExampleServerProcess.executableURL(productsDirectory: directory)
        }
    }

    @Test("launchArguments(forMode:) passes the mode through as a --mode flag")
    func launchArgumentsPassesMode() {
        #expect(ExampleServerProcess.launchArguments(forMode: "echo") == ["--mode", "echo"])
        #expect(ExampleServerProcess.launchArguments(forMode: "filesystem") == ["--mode", "filesystem"])
    }

    // MARK: - checkSystemLanguageModelAvailable

    @Test("checkSystemLanguageModelAvailable(exampleName:isAvailable:) returns true and prints nothing when available")
    func modelGuardReturnsTrueWhenAvailable() {
        #expect(checkSystemLanguageModelAvailable(exampleName: "EchoTool", isAvailable: true))
    }

    @Test("checkSystemLanguageModelAvailable(exampleName:isAvailable:) returns false when unavailable")
    func modelGuardReturnsFalseWhenUnavailable() {
        #expect(!checkSystemLanguageModelAvailable(exampleName: "EchoTool", isAvailable: false))
    }

    // MARK: - requireExampleServer

    @Test("requireExampleServer(exampleName:mode:clientName:isAvailable:) returns nil without spawning when the model is unavailable")
    func requireExampleServerReturnsNilWhenModelUnavailable() async throws {
        let connected = try await requireExampleServer(
            exampleName: "EchoTool", mode: "echo", clientName: "EchoToolTestClient", isAvailable: false)

        #expect(connected == nil)
    }

    // MARK: - runExample

    @Test("runExample(named:mode:clientName:isAvailable:body:) never invokes body when the model is unavailable")
    func runExampleSkipsBodyWhenModelUnavailable() async throws {
        var bodyRan = false

        try await runExample(
            named: "EchoTool", mode: "echo", clientName: "EchoToolTestClient", isAvailable: false
        ) { _ in
            bodyRan = true
        }

        #expect(!bodyRan)
    }

    // MARK: - RemoteHTTP token injection

    @Test("requestModifier(bearerToken:) adds an Authorization header when a token is supplied")
    func requestModifierAddsAuthorizationHeaderWhenTokenPresent() {
        let request = URLRequest(url: URL(string: "https://example.com/mcp")!)
        let modifier = RemoteHTTP.requestModifier(bearerToken: "secret-token")

        let modified = modifier(request)

        #expect(modified.value(forHTTPHeaderField: "Authorization") == "Bearer secret-token")
    }

    @Test("requestModifier(bearerToken:) leaves the request unmodified when no token is supplied")
    func requestModifierLeavesRequestUnmodifiedWhenTokenAbsent() {
        let request = URLRequest(url: URL(string: "https://example.com/mcp")!)
        let modifier = RemoteHTTP.requestModifier(bearerToken: nil)

        let modified = modifier(request)

        #expect(modified.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(modified == request)
    }

    // MARK: - CatalogFormatting: CatalogBrowser's full per-tool field dump

    /// The empty object schema (`{ "type": "object", "properties": {} }`)
    /// shared by several fixtures below — a local literal rather than
    /// `MCPTestServer.JSONSchemaBuilder.emptySchema`, since examples (and
    /// this suite's coverage of their helper logic) never depend on the
    /// `MCPTestServer` test-fixture target.
    private static let emptyObjectSchema: Value = .object([
        "type": .string("object"),
        "properties": .object([:]),
    ])

    /// Builds a `ToolDescriptor` exercising every M8 catalog field — `title`,
    /// full `ToolAnnotations`, icons, and a multi-property `inputSchema` —
    /// the same shape as `MCPTestServer.ScriptedServer.catalogShowcaseTool(named:)`'s
    /// tool, reconstructed locally so this suite never depends on the
    /// `MCPTestServer` test-fixture target.
    private static func makeShowcaseDescriptor() throws -> ToolDescriptor {
        let tool = MCP.Tool(
            name: "weather_lookup",
            title: "Weather Lookup",
            description: "Looks up the current weather for a city.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object(["city": .object(["type": .string("string")])]),
                "required": .array([.string("city")]),
            ]),
            annotations: .init(
                title: "Weather Lookup",
                readOnlyHint: true,
                destructiveHint: false,
                idempotentHint: true,
                openWorldHint: true
            ),
            icons: [MCP.Icon(src: "https://example.com/icons/weather.png", mimeType: "image/png", sizes: ["48x48"])]
        )
        return try ToolDescriptor(tool: tool)
    }

    @Test("CatalogFormatting.describe(_:) renders every M8 catalog field")
    func catalogFormattingDescribesEveryField() throws {
        let descriptor = try Self.makeShowcaseDescriptor()

        let rendered = CatalogFormatting.describe(descriptor).joined(separator: "\n")

        #expect(rendered.contains("name: weather_lookup"))
        #expect(rendered.contains("title: Weather Lookup"))
        #expect(rendered.contains("description: Looks up the current weather for a city."))
        #expect(rendered.contains("annotations.title: Weather Lookup"))
        #expect(rendered.contains("annotations.readOnlyHint: true"))
        #expect(rendered.contains("annotations.destructiveHint: false"))
        #expect(rendered.contains("annotations.idempotentHint: true"))
        #expect(rendered.contains("annotations.openWorldHint: true"))
        #expect(rendered.contains("https://example.com/icons/weather.png"))
        #expect(rendered.contains("\"city\""))
        #expect(rendered.contains("parameters (GenerationSchema name):"))
        #expect(rendered.contains("fingerprint: \(descriptor.fingerprint)"))
    }

    @Test("CatalogFormatting.describe(_:) renders placeholders when title, annotations, and icons are absent")
    func catalogFormattingRendersPlaceholdersForAbsentFields() throws {
        let tool = MCP.Tool(name: "bare", description: "A bare tool.", inputSchema: Self.emptyObjectSchema)
        let descriptor = try ToolDescriptor(tool: tool)

        let rendered = CatalogFormatting.describe(descriptor).joined(separator: "\n")

        #expect(rendered.contains("title: <none>"))
        #expect(rendered.contains("annotations.title: <none>"))
        #expect(rendered.contains("annotations.readOnlyHint: <unset>"))
        #expect(rendered.contains("icons: <none>"))
    }

    // MARK: - CatalogFormatting: DynamicToolset's snapshot + diff summaries

    @Test("CatalogFormatting.summarize(_:) for a ToolCatalog snapshot names its identity, epoch, state, and tools")
    func catalogFormattingSummarizesSnapshot() throws {
        let descriptor = try Self.makeShowcaseDescriptor()
        let snapshot = ToolCatalog(
            identity: ServerIdentity(name: "dynamic-toolset-server"), epoch: 3, state: .ready, tools: [descriptor])

        let summary = CatalogFormatting.summarize(snapshot)

        #expect(summary.contains("dynamic-toolset-server"))
        #expect(summary.contains("epoch 3"))
        #expect(summary.contains("ready"))
        #expect(summary.contains("weather_lookup"))
    }

    @Test("CatalogFormatting.summarize(_:) for a ToolCatalog snapshot names a faulted state's reason")
    func catalogFormattingSummarizesFaultedState() {
        let snapshot = ToolCatalog(identity: ServerIdentity(name: "x"), epoch: 1, state: .faulted("boom"), tools: [])

        #expect(CatalogFormatting.summarize(snapshot).contains("faulted: boom"))
    }

    /// Builds a ``ToolCatalog`` snapshot for the diff fixtures below.
    ///
    /// `ToolCatalogDiff` has no public initializer of its own (only
    /// `ToolCatalog.diff(from:)` produces one), so these tests build two
    /// snapshots and diff them, exactly as `Examples/DynamicToolset` does
    /// against consecutive `catalogUpdates` snapshots.
    private static func makeSnapshot(epoch: Int, tools: [ToolDescriptor]) -> ToolCatalog {
        ToolCatalog(identity: ServerIdentity(name: "diff-fixture-server"), epoch: epoch, state: .ready, tools: tools)
    }

    @Test("CatalogFormatting.summarize(_:) for a ToolCatalogDiff renders added and changed tools, with fingerprints")
    func catalogFormattingSummarizesAddedAndChangedDiff() throws {
        let reschemadSchema: Value = .object([
            "type": .string("object"),
            "properties": .object(["step": .object(["type": .string("integer")])]),
            "required": .array([.string("step")]),
        ])
        let counterBefore = try ToolDescriptor(
            tool: MCP.Tool(name: "counter", description: "before", inputSchema: Self.emptyObjectSchema))
        let counterAfter = try ToolDescriptor(
            tool: MCP.Tool(name: "counter", description: "after", inputSchema: reschemadSchema))
        let addedTool = try ToolDescriptor(
            tool: MCP.Tool(name: "greeter", description: "added", inputSchema: Self.emptyObjectSchema))

        let before = Self.makeSnapshot(epoch: 1, tools: [counterBefore])
        let after = Self.makeSnapshot(epoch: 2, tools: [counterAfter, addedTool])
        let diff = after.diff(from: before)

        let rendered = CatalogFormatting.summarize(diff).joined(separator: "\n")

        #expect(rendered.contains("+ added: greeter"))
        #expect(rendered.contains("~ changed: counter"))
        #expect(rendered.contains(counterBefore.fingerprint))
        #expect(rendered.contains(counterAfter.fingerprint))
    }

    @Test("CatalogFormatting.summarize(_:) for a ToolCatalogDiff renders removed tools")
    func catalogFormattingSummarizesRemovedDiff() throws {
        let removedTool = try ToolDescriptor(
            tool: MCP.Tool(name: "gone", description: "removed", inputSchema: Self.emptyObjectSchema))

        let before = Self.makeSnapshot(epoch: 1, tools: [removedTool])
        let after = Self.makeSnapshot(epoch: 2, tools: [])
        let diff = after.diff(from: before)

        #expect(CatalogFormatting.summarize(diff).contains("  - removed: gone"))
    }

    @Test("CatalogFormatting.summarize(_:) for a ToolCatalogDiff with no change renders no lines")
    func catalogFormattingSummarizesEmptyDiff() throws {
        let steadyTool = try ToolDescriptor(
            tool: MCP.Tool(name: "steady", description: "unchanged", inputSchema: Self.emptyObjectSchema))

        let before = Self.makeSnapshot(epoch: 1, tools: [steadyTool])
        let after = Self.makeSnapshot(epoch: 2, tools: [steadyTool])
        let diff = after.diff(from: before)

        #expect(CatalogFormatting.summarize(diff).isEmpty)
    }

    // MARK: - ConsoleElicitationCoordinator (ElicitingAgent)

    @Test("ConsoleElicitationCoordinator.scriptedAction(at:script:) cycles through the script by call index")
    func consoleCoordinatorScriptedActionCycles() {
        let script: [ConsoleElicitationCoordinator.Action] = [.accept, .decline, .cancel]

        #expect(ConsoleElicitationCoordinator.scriptedAction(at: 0, script: script) == .accept)
        #expect(ConsoleElicitationCoordinator.scriptedAction(at: 1, script: script) == .decline)
        #expect(ConsoleElicitationCoordinator.scriptedAction(at: 2, script: script) == .cancel)
        #expect(ConsoleElicitationCoordinator.scriptedAction(at: 3, script: script) == .accept)
    }

    @Test("ConsoleElicitationCoordinator.placeholderContent(for:) builds one entry per requested field, typed from its schema")
    func consoleCoordinatorPlaceholderContentBuildsTypedFields() {
        let requestedSchema = Elicitation.RequestSchema(
            properties: [
                "name": .object(["type": .string("string")]),
                "age": .object(["type": .string("integer")]),
                "score": .object(["type": .string("number")]),
                "subscribed": .object(["type": .string("boolean")]),
            ])

        let content = ConsoleElicitationCoordinator.placeholderContent(for: requestedSchema)

        #expect(content["name"] == .string("example"))
        #expect(content["age"] == .int(42))
        #expect(content["score"] == .double(42.0))
        #expect(content["subscribed"] == .bool(true))
    }

    @Test("ConsoleElicitationCoordinator.placeholderContent(for:) returns empty content for a nil requestedSchema (URL mode)")
    func consoleCoordinatorPlaceholderContentEmptyForURLMode() {
        #expect(ConsoleElicitationCoordinator.placeholderContent(for: nil).isEmpty)
    }

    /// An always-empty `requestedSchema` shared by the actor-level fixtures
    /// below, which care about which action is resolved, not about a
    /// particular field shape.
    private static let emptyRequestedSchema = Elicitation.RequestSchema(properties: [:])

    @Test("ConsoleElicitationCoordinator.elicit(message:requestedSchema:) uses interactive input when readInputLine yields a recognizable action, even when it disagrees with the fallback script")
    func consoleCoordinatorElicitPrefersInteractiveInputOverFallback() async {
        let coordinator = ConsoleElicitationCoordinator(
            fallbackScript: [.cancel], readInputLine: { "decline" })

        let response = await coordinator.elicit(
            message: "What's your favorite color?", requestedSchema: Self.emptyRequestedSchema)

        #expect(response == .decline)
    }

    @Test("ConsoleElicitationCoordinator.elicit(message:requestedSchema:) falls back to the scripted rotation when readInputLine yields nil")
    func consoleCoordinatorElicitFallsBackWhenNoInput() async {
        let coordinator = ConsoleElicitationCoordinator(fallbackScript: [.accept], readInputLine: { nil })
        let requestedSchema = Elicitation.RequestSchema(
            properties: ["favoriteColor": .object(["type": .string("string")])])

        let response = await coordinator.elicit(message: "What's your favorite color?", requestedSchema: requestedSchema)

        #expect(response == .accept(content: ["favoriteColor": .string("example")]))
    }

    @Test("ConsoleElicitationCoordinator.elicit(message:requestedSchema:) falls back to the scripted rotation when readInputLine yields unrecognized text")
    func consoleCoordinatorElicitFallsBackWhenInputUnrecognized() async {
        let coordinator = ConsoleElicitationCoordinator(fallbackScript: [.cancel], readInputLine: { "banana" })

        let response = await coordinator.elicit(message: "Pick one.", requestedSchema: Self.emptyRequestedSchema)

        #expect(response == .cancel)
    }

    @Test("ConsoleElicitationCoordinator.elicit(message:url:) resolves via the same fallback rotation as form mode")
    func consoleCoordinatorElicitURLModeUsesFallbackRotation() async {
        let coordinator = ConsoleElicitationCoordinator(fallbackScript: [.decline], readInputLine: { nil })

        let response = await coordinator.elicit(message: "Visit this URL.", url: "https://example.com")

        #expect(response == .decline)
    }

    @Test("ConsoleElicitationCoordinator's fallback rotation cycles across successive elicit(_:) calls on the same instance")
    func consoleCoordinatorFallbackRotationAdvancesAcrossCalls() async {
        let coordinator = ConsoleElicitationCoordinator(
            fallbackScript: [.accept, .decline, .cancel], readInputLine: { nil })

        let first = await coordinator.elicit(message: "one", requestedSchema: Self.emptyRequestedSchema)
        let second = await coordinator.elicit(message: "two", requestedSchema: Self.emptyRequestedSchema)
        let third = await coordinator.elicit(message: "three", requestedSchema: Self.emptyRequestedSchema)
        let fourth = await coordinator.elicit(message: "four", requestedSchema: Self.emptyRequestedSchema)

        #expect(first == .accept(content: [:]))
        #expect(second == .decline)
        #expect(third == .cancel)
        #expect(fourth == .accept(content: [:]))
    }

    // MARK: - Fixtures

    /// Creates a fresh, empty temporary directory for a test to populate.
    ///
    /// - Returns: The created directory's URL.
    private static func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExampleHelperTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
