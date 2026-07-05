import ExampleSupport
import Foundation
import FoundationModels
import FoundationModelsMCP
import MCP

/// `RemoteHTTP` demonstrates connecting to a remote MCP server over
/// `HTTPClientTransport` with a **host-supplied bearer token** —
/// plan.md → Examples §4 / "Authorization (decided — delegated)": OAuth for
/// remote HTTP servers is the host's responsibility, not this package's. This
/// example plays the host: it reads a token from its own environment and
/// injects it as an `Authorization: Bearer` header via
/// `HTTPClientTransport`'s `requestModifier` hook. `FoundationModelsMCP`
/// itself implements no OAuth flow and never sees the token directly — it
/// only ever sees the transport this example already authenticated.
///
/// Configure with two environment variables before running:
/// - `REMOTE_MCP_ENDPOINT`: the remote MCP server's URL (required).
/// - `REMOTE_MCP_BEARER_TOKEN`: the bearer token to send (optional — omit to
///   demonstrate connecting to an unauthenticated server).
@main
struct RemoteHTTP {
    /// The environment variable this example reads its remote server's
    /// endpoint URL from.
    static let endpointEnvironmentVariableName = "REMOTE_MCP_ENDPOINT"

    /// The environment variable this example reads its host-supplied bearer
    /// token from.
    static let bearerTokenEnvironmentVariableName = "REMOTE_MCP_BEARER_TOKEN"

    /// The HTTP header name the bearer token is injected under.
    static let authorizationHeaderName = "Authorization"

    /// Runs the example: builds an `HTTPClientTransport` to
    /// ``endpointEnvironmentVariableName``'s URL with
    /// ``bearerTokenEnvironmentVariableName``'s token injected via
    /// ``requestModifier(bearerToken:)``, connects an `MCPServer` to it, and
    /// drives one prompt.
    ///
    /// Prints a clean, non-crashing message and returns early if
    /// `SystemLanguageModel` is unavailable, or if
    /// ``endpointEnvironmentVariableName`` is unset or not a valid URL.
    ///
    /// - Throws: Whatever connecting `server` or `session.respond(to:)`
    ///   throws.
    static func main() async throws {
        guard checkSystemLanguageModelAvailable(exampleName: "RemoteHTTP") else { return }

        let environment = ProcessInfo.processInfo.environment
        guard let endpointString = environment[endpointEnvironmentVariableName],
            let endpoint = URL(string: endpointString)
        else {
            print(
                "Set \(endpointEnvironmentVariableName) to the remote MCP server's URL to run this example (optionally also \(bearerTokenEnvironmentVariableName))."
            )
            return
        }

        let transport = HTTPClientTransport(
            endpoint: endpoint,
            requestModifier: requestModifier(bearerToken: environment[bearerTokenEnvironmentVariableName])
        )

        let server = MCPServer(client: Client(name: "RemoteHTTPExample", version: "1.0"))
        try await server.connect(transport: transport)
        defer { await server.disconnect() }

        let session = try await LanguageModelSession(mcp: server)
        let response = try await session.respond(
            to: "What tools do you have access to, and what can you help me with?")
        print(response.content)
    }

    /// Builds the `HTTPClientTransport` request modifier that injects
    /// `bearerToken` as an `Authorization: Bearer` header — the host-supplied
    /// auth this package delegates to (see plan.md's "Authorization
    /// (decided — delegated)").
    ///
    /// - Parameter bearerToken: The host-supplied bearer token to inject, or
    ///   `nil` to leave every request unmodified (e.g. for an
    ///   unauthenticated remote server).
    /// - Returns: A closure suitable for `HTTPClientTransport`'s
    ///   `requestModifier` parameter.
    static func requestModifier(bearerToken: String?) -> (URLRequest) -> URLRequest {
        { request in
            guard let bearerToken else { return request }
            var modified = request
            modified.addValue("Bearer \(bearerToken)", forHTTPHeaderField: authorizationHeaderName)
            return modified
        }
    }
}
