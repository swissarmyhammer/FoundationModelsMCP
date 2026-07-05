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

## No other *runtime* dependencies

`Package.swift`'s runtime-relevant dependencies are swift-sdk (the MCP client)
and swift-log (structured logging, `import Logging` in `MCPServer`), plus a
`linkerSettings: [.linkedFramework("FoundationModels")]` on the library target
for the system `FoundationModels` framework. No MLX, no Router (plan.md →
Decisions → Enforcement) — the dependency this decision actually guards
against.

`Package.swift` additionally declares `swift-docc-plugin` as a package
dependency (added for the DocC catalog task) — it is a documentation-build
tool invoked via `swift package generate-documentation`, never imported by
any target's source and never linked into a consumer of this library. It
does not change the "no MLX, no Router" runtime footprint above.

## Cancellation: the SDK does not auto-propagate Swift `Task` cancellation

Recorded at M5/Hardening time (plan.md → Connection lifecycle →
"Cancellation, progress, health") while implementing
`MCPServer.call(toolNamed:arguments:timeout:)`'s cancellation support.

**Cancelling a Swift `Task` that is awaiting an MCP request result does
*not* automatically make `MCP.Client` send a protocol-level
`notifications/cancelled`.** Confirmed by reading the pinned tag's own
source, not by assumption:

- `Client.send<M: Method>(_:)` (`Sources/MCP/Client/Client.swift`) returns a
  `RequestContext<M.Result>` wrapping the request's `id` and an internal
  `Task` that resolves a `CheckedContinuation` once the matching response
  arrives (or the pending request is otherwise removed). Nothing in that
  path observes the *caller's* `Task` cancellation state.
- `RequestContext.value` (`Sources/MCP/Base/Utilities/RequestContext.swift`)
  just `await`s that internal task's `.value` — this is not itself a
  cancellation checkpoint tied to whatever `Task` is awaiting it, since the
  internal task is an independent, already-started unit of work.
- Sending the cancellation notification is a **separate, explicit** client
  API: `Client.cancelRequest(_ requestID: ID, reason: String?) async throws`
  removes the pending request, resumes its continuation with
  `CancellationError()`, and *then* sends
  `CancelledNotification.message(.init(requestId:reason:))` over the wire.
  Its own doc comment is explicit about this being something the caller
  must invoke: "This allows you to track and cancel the request by sending a
  CancelledNotification to the server using the requestID."

So merely wrapping a call in a Swift `Task` and later calling `.cancel()` on
it does nothing at the protocol level by itself — the cooperative
cancellation flag is set, but nothing in the SDK reacts to it. `MCPServer`
therefore sends the notification **explicitly**: `call(toolNamed:arguments:timeout:)`
wraps its await in `withTaskCancellationHandler(operation:onCancel:)`, whose
`onCancel` closure — which fires synchronously the instant the enclosing
`Task` is cancelled, even mid-await — spawns a `Task` that calls
`client.cancelRequest(_:reason:)`. That single mechanism also happens to be
exactly what's needed to unblock the still-pending continuation so
`MCPServer`'s internal `withThrowingTaskGroup` race (response vs. timeout)
can actually finish instead of waiting forever on an orphaned child task —
the same `cancelRequest` call is reused for the per-call timeout's own
"stop waiting on this request" case.

- SeeAlso: https://modelcontextprotocol.io/specification/2025-11-25/basic/utilities/cancellation

## Progress notifications: opt-in via `_meta.progressToken`, no auto-reset semantics

Also recorded at M5/Hardening time, alongside cancellation.

`notifications/progress` is entirely **opt-in per request**: a client only
receives progress for a given `tools/call` if it attaches a `progressToken`
to that request's `_meta` (`Metadata.progressToken`,
`Sources/MCP/Base/Utilities/Progress.swift`); a server has no obligation to
honor it even then (per spec, "the receiver is not obligated to provide
these notifications"). The SDK itself has no concept of a per-request
timeout or a "progress resets the timeout" behavior — that policy is purely
`MCPServer`'s own (see `CallDeadline` and
`MCPServer.resultOrTimeout(toolName:context:progressToken:timeout:)`), built
on top of the SDK's plain `Client.onNotification(ProgressNotification.self)`
registration, matching the existing `notifications/tools/list_changed`
handler-registration pattern (`registerToolListChangedHandler()`) rather than
anything progress-specific in the SDK.
