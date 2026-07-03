# swift-sdk notes

Verification notes for the pinned `modelcontextprotocol/swift-sdk` dependency
(`.product(name: "MCP", package: "swift-sdk")`), recorded at M0 scaffolding
time per plan.md → M0 / Decisions → Spec revision.

## Pinned version

`Package.swift` pins `from: "0.12.1"` — the latest stable tag at the time of
this writing (verified via `git ls-remote --tags
https://github.com/modelcontextprotocol/swift-sdk.git`).

## Protocol revision

Target revision: **2025-11-25** (the current MCP spec revision — see
plan.md → Decisions → Spec revision).

Confirmed against the pinned tag's source
(`Sources/MCP/Base/Versioning.swift`):

```swift
public enum Version {
    /// All protocol versions supported by this implementation, ordered from newest to oldest.
    public static let supported: Set<String> = [
        "2025-11-25",
        "2025-06-18",
        "2025-03-26",
        "2024-11-05",
    ]

    /// The latest protocol version supported by this implementation.
    public static let latest = supported.max()!
}
```

`Version.latest` resolves to `"2025-11-25"`, and it is the default
`protocolVersion` used by `HTTPClientTransport` and the client's `Initialize`
request (`Sources/MCP/Base/Lifecycle.swift`, `Sources/MCP/Base/Transports/HTTPClientTransport.swift`).
So the pinned swift-sdk speaks the targeted revision natively — no shim
required.

- SeeAlso: https://modelcontextprotocol.io/specification/2025-11-25/

## Elicitation surface

The pinned swift-sdk exposes elicitation as a client capability with a
handler-registration API on `MCP.Client`:

```swift
// Sources/MCP/Client/Client.swift
@discardableResult
public func withElicitationHandler(
    _ handler:
        @escaping @Sendable (CreateElicitation.Parameters) async throws ->
        CreateElicitation.Result
) -> Self
```

Registering a handler is how a client declares the elicitation capability and
opts into servers pausing mid-tool-call to request structured input via
`elicitation/create` (`Sources/MCP/Client/Elicitation.swift`). The handler
receives `CreateElicitation.Parameters` — either `.form(FormParameters)`
(`message`, optional `mode`, `requestedSchema`, optional `_meta`) or
`.url(URLParameters)` — and returns a `CreateElicitation.Result` describing the
user's `accept` / `decline` / `cancel` action.

This is the API `MCPServer` will call in M7 (see plan.md → Elicitation) to
route server-initiated elicitation requests to the host's
`ElicitationCoordinator`.

- SeeAlso: https://modelcontextprotocol.io/specification/2025-11-25/client/elicitation

## No other external dependencies

`Package.swift` declares exactly one external dependency — swift-sdk — plus a
`linkerSettings: [.linkedFramework("FoundationModels")]` on the library target
for the system `FoundationModels` framework. No MLX, no Router (plan.md →
Decisions → Enforcement).
