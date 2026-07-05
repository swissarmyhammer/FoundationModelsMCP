import Foundation
import MCP
import System

/// Errors raised while locating or spawning the shared `MCPTestServerCLI`
/// subprocess ``ExampleServerProcess`` wraps.
public enum ExampleServerProcessError: Error, CustomStringConvertible, Equatable {
    /// No executable file exists at the path this helper expected
    /// `MCPTestServerCLI` to have been built to.
    ///
    /// Carried for diagnostics.
    case testServerCLINotFound(String)

    /// A human-readable description of this error, naming the path that was searched.
    public var description: String {
        switch self {
        case .testServerCLINotFound(let path):
            return
                "Could not find the MCPTestServerCLI executable at \(path); run `swift build` first so it is built alongside this example."
        }
    }
}

/// A spawned `MCPTestServerCLI` subprocess wired to a `StdioTransport`,
/// shared by every `Examples/` target that needs a real, out-of-process MCP
/// server — `EchoTool`, `FileAssistant`, and `ToolPicking`.
///
/// Mirrors `Tests/FoundationModelsMCPTests/E2ETests.swift`'s
/// subprocess-spawning pattern (`Process` + `Pipe` + `StdioTransport`), so
/// this plumbing isn't duplicated across three separate example targets.
/// Deliberately its own small library target rather than a dependency on
/// `MCPTestServer` (the test-fixture target) — examples never import the
/// test target; they only know `MCPTestServerCLI` as an external executable
/// to spawn, exactly as `E2ETests.swift` does.
public struct ExampleServerProcess: @unchecked Sendable {
    /// The underlying subprocess.
    ///
    /// `Process` isn't `Sendable`; `@unchecked` is safe here because every
    /// use is a self-contained call (`run()`, `terminate()`,
    /// `waitUntilExit()`) with no state shared concurrently across callers —
    /// this value is only ever touched by whichever single example owns it.
    public let process: Process

    /// The stdio transport wired to the subprocess's stdin/stdout pipes.
    public let transport: StdioTransport

    /// Spawns `MCPTestServerCLI` in the given `mode`, wiring its stdio to a
    /// fresh `StdioTransport`.
    ///
    /// - Parameter mode: The `ServerMode` raw value to pass via `--mode`
    ///   (`"echo"`, `"filesystem"`, or `"all"`) — see `MCPTestServerCLI`'s
    ///   `main.swift`.
    /// - Returns: The spawned process and its transport.
    /// - Throws: ``ExampleServerProcessError/testServerCLINotFound(_:)`` if
    ///   no `MCPTestServerCLI` executable exists alongside this example's
    ///   own build products, or whatever `Process.run()` throws if spawning
    ///   fails for another reason.
    public static func spawn(mode: String) throws -> ExampleServerProcess {
        let process = Process()
        process.executableURL = try executableURL()
        process.arguments = launchArguments(forMode: mode)

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice

        try process.run()

        let transport = StdioTransport(
            input: FileDescriptor(rawValue: stdoutPipe.fileHandleForReading.fileDescriptor),
            output: FileDescriptor(rawValue: stdinPipe.fileHandleForWriting.fileDescriptor)
        )
        return ExampleServerProcess(process: process, transport: transport)
    }

    /// Terminates the subprocess and waits for it to exit.
    ///
    /// Callers should invoke this (typically via `defer`) once done with
    /// ``transport``, mirroring `E2ETests.swift`'s subprocess teardown.
    public func shutdown() {
        process.terminate()
        process.waitUntilExit()
    }

    /// The `MCPTestServerCLI` launch arguments for `mode`.
    ///
    /// - Parameter mode: The `ServerMode` raw value to select.
    /// - Returns: `["--mode", mode]`.
    static func launchArguments(forMode mode: String) -> [String] {
        ["--mode", mode]
    }

    /// Locates the `MCPTestServerCLI` executable expected to sit alongside
    /// this process's own build products.
    ///
    /// - Parameter productsDirectory: The directory to search. Defaults to
    ///   this process's own executable's directory (the SwiftPM build
    ///   products directory when run via `swift run`).
    /// - Returns: `MCPTestServerCLI`'s file URL.
    /// - Throws: ``ExampleServerProcessError/testServerCLINotFound(_:)`` if
    ///   no executable file exists at the expected path.
    static func executableURL(
        productsDirectory: URL = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
    ) throws -> URL {
        let url = productsDirectory.appendingPathComponent("MCPTestServerCLI")
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw ExampleServerProcessError.testServerCLINotFound(url.path)
        }
        return url
    }
}
