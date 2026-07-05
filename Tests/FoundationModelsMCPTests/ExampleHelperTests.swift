import Foundation
import Testing

@testable import ExampleSupport
@testable import RemoteHTTP

/// Coverage for the non-model helper logic behind the `Examples/` targets —
/// the pieces that don't require a live `SystemLanguageModel` or a real
/// spawned subprocess/HTTP server to test directly:
///
/// - ``ExampleServerProcess``'s `MCPTestServerCLI`-locating plumbing, shared
///   by `EchoTool`, `FileAssistant`, and `ToolPicking`.
/// - `RemoteHTTP`'s host-supplied bearer token injection into
///   `HTTPClientTransport`'s `requestModifier`.
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
