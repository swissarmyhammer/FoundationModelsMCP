import Foundation
import System
import Testing

@testable import FoundationModelsMCP
import FoundationModels
import MCP

/// Gated end-to-end test that exercises `LanguageModelSession` with a real stdio MCP server subprocess.
///
/// Built via ``LanguageModelSession/init(model:mcp:instructions:)`` on the
/// **system model**, driven against a **real, out-of-process** MCP server —
/// the `MCPTestServerCLI` executable, spawned as a subprocess and wired to a
/// real `StdioTransport`, not an in-process `InMemoryTransport` pairing or a
/// mock `Client`.
///
/// This is deliberately the one place in the suite that exercises the full
/// stack for real: subprocess spawn, stdio framing, `MCP.Client`, `MCPServer`
/// discovery, `LanguageModelSession(mcp:)`, and Apple's on-device
/// `SystemLanguageModel` actually deciding to call a tool. Everywhere else in
/// this package substitutes `InMemoryTransport` and/or `ScriptedServer` in
/// process specifically so tests stay fast and deterministic — this file is
/// the exception, gated off by default for exactly that reason.
///
/// Gated two ways, both surfaced as a Swift Testing skip (never a failure,
/// never a silently-passing empty body, never a compile-time `#if` that would
/// hide the test from `swift test --filter E2E` entirely):
///
/// 1. The `FOUNDATIONMODELSMCP_E2E` environment variable must be `"1"` — off
///    by default, so CI and every ordinary `swift test` run skips this test
///    with an explanatory message instead of requiring the on-device model.
/// 2. Even with that flag set, `SystemLanguageModel.default.isAvailable` must
///    be `true` — a host with the flag set but no Apple Intelligence model
///    available (wrong OS version, feature disabled, model still
///    downloading) still gets a clean skip rather than a crash or failure.
@Suite("E2E")
struct E2ETests {
    /// The environment variable that must be set to exactly `"1"` to enable this gated test.
    ///
    /// See the type-level doc's gating section for the full two-part gate.
    private static let e2eEnvironmentVariableName = "FOUNDATIONMODELSMCP_E2E"

    /// The name of the tool this test drives the model to call.
    ///
    /// `MCPTestServerCLI`'s registered echo tool (see
    /// `Sources/MCPTestServerCLI/main.swift`), which echoes its `text`
    /// argument back verbatim.
    private static let echoToolName = "echo"

    /// Whether ``e2eEnvironmentVariableName`` is set to `"1"` in this process's environment.
    private static var isE2EFlagSet: Bool {
        ProcessInfo.processInfo.environment[e2eEnvironmentVariableName] == "1"
    }

    /// Whether it's safe to proceed past the model-availability gate.
    ///
    /// `true` whenever ``isE2EFlagSet`` is `false`, without ever touching
    /// `SystemLanguageModel` — so the default (ungated) `swift test` run
    /// never probes on-device model availability at all, only this suite's
    /// own environment-variable check. Only once ``isE2EFlagSet`` is `true`
    /// does this actually consult `SystemLanguageModel.default.isAvailable`.
    private static var modelAvailabilityGatePasses: Bool {
        !isE2EFlagSet || SystemLanguageModel.default.isAvailable
    }

    @Test(
        "LanguageModelSession(mcp:) on the system model calls a real tool through a spawned stdio MCPTestServerCLI subprocess",
        .enabled(
            if: Self.isE2EFlagSet,
            "Set \(Self.e2eEnvironmentVariableName)=1 to run this gated end-to-end test against the on-device system model and a spawned stdio MCP server subprocess."
        ),
        .enabled(
            if: Self.modelAvailabilityGatePasses,
            "SystemLanguageModel is unavailable on this host (see SystemLanguageModel.default.isAvailable); this test requires an on-device Apple Intelligence model."
        )
    )
    func systemModelCallsRealToolThroughStdioServer() async throws {
        let process = Process()
        process.executableURL = try Self.testServerCLIExecutableURL()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice

        try process.run()
        // Runs after `server`'s own teardown defer below (defers run in
        // reverse declaration order), so the subprocess is only killed and
        // reaped once the client side has already disconnected.
        defer {
            process.terminate()
            process.waitUntilExit()
        }

        let transport = StdioTransport(
            input: FileDescriptor(rawValue: stdoutPipe.fileHandleForReading.fileDescriptor),
            output: FileDescriptor(rawValue: stdinPipe.fileHandleForWriting.fileDescriptor)
        )

        let server = MCPServer(client: Client(name: "E2ETestClient", version: "1.0"))
        try await server.connect(transport: transport)
        // Matches every other test in this package that constructs an
        // MCPServer (e.g. MCPServerDiscoveryTests, LiveCatalogTests): stops
        // StdioTransport's background read loop promptly instead of relying
        // on it to exit only once the subprocess eventually dies from
        // `process.terminate()` above.
        defer { await server.disconnect() }

        let marker = "e2e-marker-\(UUID().uuidString)"
        let session = try await LanguageModelSession(
            mcp: server,
            instructions:
                "You have access to an echo tool that returns its \"text\" argument back verbatim. When asked to echo something, call the echo tool with exactly the requested text, then report back exactly what it returned."
        )

        let response = try await session.respond(
            to: "Call the echo tool with the text \"\(marker)\" and tell me exactly what it returned.")

        #expect(response.content.contains(marker))
        #expect(Self.transcriptRecordsCall(toToolNamed: Self.echoToolName, in: session.transcript))
        #expect(Self.transcriptRecordsOutput(fromToolNamed: Self.echoToolName, containing: marker, in: session.transcript))
    }

    // MARK: - Transcript assertions

    /// Whether `transcript` contains a `toolCalls` entry naming `toolName`.
    ///
    /// Proof the model actually decided to invoke the tool, independent of
    /// whatever text the model went on to say about the result.
    ///
    /// - Parameters:
    ///   - toolName: The tool name to look for among recorded calls.
    ///   - transcript: The session transcript to search.
    /// - Returns: `true` if any `toolCalls` entry includes a call to
    ///   `toolName`.
    private static func transcriptRecordsCall(toToolNamed toolName: String, in transcript: Transcript) -> Bool {
        transcript.contains { entry in
            guard case .toolCalls(let calls) = entry else { return false }
            return calls.contains { $0.toolName == toolName }
        }
    }

    /// Whether `transcript` contains a `toolOutput` entry from `toolName` whose rendered text includes `text`.
    ///
    /// Proof the tool's actual result (not just the model's paraphrase)
    /// reached the session.
    ///
    /// - Parameters:
    ///   - toolName: The tool name the output must be attributed to.
    ///   - text: The substring the output's text segments must contain.
    ///   - transcript: The session transcript to search.
    /// - Returns: `true` if any `toolOutput` entry from `toolName` has a text
    ///   segment containing `text`.
    private static func transcriptRecordsOutput(
        fromToolNamed toolName: String, containing text: String, in transcript: Transcript
    ) -> Bool {
        transcript.contains { entry in
            guard case .toolOutput(let output) = entry, output.toolName == toolName else { return false }
            return output.segments.contains { segment in
                guard case .text(let textSegment) = segment else { return false }
                return textSegment.content.contains(text)
            }
        }
    }

    // MARK: - Subprocess setup

    /// Errors specific to locating and launching this test's spawned `MCPTestServerCLI` subprocess.
    private enum SetupError: Error, CustomStringConvertible {
        /// No executable file exists at the path this test expected `MCPTestServerCLI` to have been built to.
        ///
        /// Carried for diagnostics.
        case testServerCLINotFound(String)

        var description: String {
            switch self {
            case .testServerCLINotFound(let path):
                return
                    "Could not find the MCPTestServerCLI executable at \(path); ensure `swift build` (or `swift test`, which builds it as a dependency) has produced it alongside this test bundle."
            }
        }
    }

    /// Locates the build products directory containing this test binary.
    ///
    /// This is the directory (e.g. `.build/debug`) so
    /// ``testServerCLIExecutableURL()`` can find the sibling
    /// `MCPTestServerCLI` executable SwiftPM builds alongside it.
    ///
    /// On Darwin, `swift test` hosts the swift-testing runner inside an
    /// `.xctest` bundle launched by a separate `swiftpm-testing-helper`
    /// process, which receives the bundle's path via a `--test-bundle-path`
    /// argument — parsed here rather than through `Bundle.allBundles`, since
    /// that `.xctest` bundle is loaded without ever registering itself as an
    /// `NSBundle` (confirmed empirically: `Bundle.allBundles` only lists the
    /// helper's own bundle during a `swift test` run).
    ///
    /// CI's gated integration job instead invokes the built bundle directly
    /// via `xcrun xctest <bundle>` (see `swift-ci.yaml`'s integration job),
    /// which never sets `--test-bundle-path` — there the bundle path is
    /// `xctest`'s own positional argument, found here by its `.xctest`
    /// suffix; the bundle's parent directory is the products directory.
    ///
    /// Falls back to this process's own executable directory when neither
    /// applies, which is already the products directory when a test binary
    /// is invoked directly rather than through the helper.
    ///
    /// - Returns: The products directory containing this test's sibling
    ///   build artifacts, including `MCPTestServerCLI`.
    private static func productsDirectoryURL() -> URL {
        if let flagIndex = CommandLine.arguments.firstIndex(of: "--test-bundle-path"),
            CommandLine.arguments.indices.contains(flagIndex + 1)
        {
            return URL(fileURLWithPath: CommandLine.arguments[flagIndex + 1])
                .deletingLastPathComponent()  // .../<Bundle>.xctest/Contents/MacOS
                .deletingLastPathComponent()  // .../<Bundle>.xctest/Contents
                .deletingLastPathComponent()  // .../<Bundle>.xctest
                .deletingLastPathComponent()  // the products directory itself
        }
        if let bundleArgument = CommandLine.arguments.first(where: { $0.hasSuffix(".xctest") }) {
            return URL(fileURLWithPath: bundleArgument).deletingLastPathComponent()
        }
        return URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
    }

    /// Locates the `MCPTestServerCLI` executable SwiftPM builds alongside this test binary.
    ///
    /// - Returns: The executable's file URL.
    /// - Throws: ``SetupError/testServerCLINotFound(_:)`` if no executable
    ///   file exists at the expected path.
    private static func testServerCLIExecutableURL() throws -> URL {
        let url = productsDirectoryURL().appendingPathComponent("MCPTestServerCLI")
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw SetupError.testServerCLINotFound(url.path)
        }
        return url
    }
}
