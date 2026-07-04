import MCP

/// The host-owned coordinator that presents an MCP elicitation request to
/// the user and returns their response.
///
/// One `ElicitationCoordinator` implementation serves both directions
/// `plan.md`'s "Elicitation is unified" decision describes: server-initiated
/// elicitation (``MCPServer`` declares the elicitation client capability,
/// registers `MCP.Client.withElicitationHandler`, and routes every
/// `elicitation/create` request here — see `MCPServer.swift`) and, in a
/// later milestone, agent-initiated elicitation (`MCPElicitationTool`, which
/// will route through this same protocol). This package defines the
/// protocol; the host app owns the concrete UI that presents it to the
/// user.
///
/// - SeeAlso: `docs/swift-sdk-notes.md`'s "Elicitation surface" section, and
///   `plan.md`'s "Elicitation: user input, in both directions" section.
public protocol ElicitationCoordinator: Sendable {
    /// Presents `requestedSchema`'s fields to the user as an ordinary
    /// in-app form and returns the action they took.
    ///
    /// - Important: Per the MCP spec, form-mode elicitation must never
    ///   collect secrets (passwords, tokens, payment credentials). Routing
    ///   in ``MCPServer`` enforces this rule: it never calls this method
    ///   when `requestedSchema.requiresURLModeRouting` is `true`, calling
    ///   ``elicit(message:url:)`` instead. Other callers of this protocol
    ///   (e.g. the agent-initiated `MCPElicitationTool`) must preserve the
    ///   same rule.
    /// - Parameters:
    ///   - message: The human-readable prompt describing what's being asked.
    ///   - requestedSchema: The flat-primitive schema describing the fields
    ///     to collect.
    /// - Returns: The user's response.
    func elicit(message: String, requestedSchema: Elicitation.RequestSchema) async -> ElicitationResponse

    /// Presents a URL-mode request to the user and returns the action they
    /// took.
    ///
    /// Two situations route here instead of
    /// ``elicit(message:requestedSchema:)``: a server's own genuine MCP
    /// URL-mode request, where `url` is the real link it asked the user to
    /// visit; and ``MCPServer``'s no-secrets-in-form-mode enforcement
    /// downgrading a form-mode request whose `requestedSchema` contained a
    /// sensitive-marked field or a `format: "url"` field (see
    /// ``Elicitation/RequestSchema/requiresURLModeRouting``) — a spec
    /// violation by the server, in which case there is no genuine link and
    /// `url` is `nil`. The coordinator is responsible for presenting (or,
    /// in the `nil` case, safely refusing) the request appropriately either
    /// way.
    ///
    /// - Parameters:
    ///   - message: The human-readable prompt describing what's being asked.
    ///   - url: The link the user should visit to complete the request out
    ///     of band, or `nil` when no genuine link exists (the no-secrets
    ///     enforcement case above).
    /// - Returns: The user's response.
    func elicit(message: String, url: String?) async -> ElicitationResponse
}

/// The user's response to one ``ElicitationCoordinator`` request, mirroring
/// `MCP.CreateElicitation.Result.Action`'s three cases.
public enum ElicitationResponse: Sendable, Equatable {
    /// The user submitted `content` matching the request's schema.
    case accept(content: [String: Value])

    /// The user was shown the request and explicitly declined to answer.
    case decline

    /// The user dismissed the request without answering.
    case cancel
}

extension Elicitation.RequestSchema {
    /// This package's custom JSON Schema keyword marking a property as
    /// holding a secret (a password, token, or payment credential) that must
    /// never be collected via ordinary form-mode elicitation.
    ///
    /// Not part of the MCP spec's own elicitation schema vocabulary — see
    /// `plan.md`'s "Agent-elicitation arg shape" decision: "any `secret`
    /// marker is our convention, honored by the coordinator, not a spec
    /// field." A spec-compliant server that needs a secret from the user is
    /// expected to use MCP URL-mode elicitation instead of form mode in the
    /// first place; this keyword lets ``requiresURLModeRouting`` catch a
    /// form-mode request that violates that rule anyway.
    private static let secretKeyword = "secret"

    /// The JSON Schema `format` keyword name, whose value is checked against
    /// ``urlFormatValue`` by ``requiresURLModeRouting``.
    private static let formatKeyword = "format"

    /// The JSON Schema `format` value that also triggers URL-mode routing
    /// alongside ``secretKeyword`` — see ``requiresURLModeRouting``.
    private static let urlFormatValue = "url"

    /// Whether any property in ``properties`` is marked ``secretKeyword`` or
    /// declares `format: "url"` — either of which means this schema must
    /// never reach
    /// ``ElicitationCoordinator/elicit(message:requestedSchema:)`` (form
    /// mode); see ``ElicitationCoordinator/elicit(message:url:)`` for the
    /// path it is routed to instead.
    public var requiresURLModeRouting: Bool {
        properties.values.contains { property in
            guard case .object(let fields) = property else { return false }
            return fields[Self.secretKeyword]?.boolValue == true
                || fields[Self.formatKeyword]?.stringValue == Self.urlFormatValue
        }
    }
}

/// The shared routing decision between a form-mode elicitation request and
/// ``ElicitationCoordinator``'s two entry points — the no-secrets-in-form-mode
/// enforcement every caller that owns a form-mode `requestedSchema` (today,
/// ``MCPServer``'s server-initiated routing; in a later milestone, the
/// agent-initiated `MCPElicitationTool`) must apply identically, kept in one
/// place instead of duplicated at each call site.
public enum ElicitationRouting {
    /// Routes a form-mode elicitation request to `coordinator`, calling
    /// ``ElicitationCoordinator/elicit(message:url:)`` with a `nil` url
    /// instead of ``ElicitationCoordinator/elicit(message:requestedSchema:)``
    /// whenever `requestedSchema.requiresURLModeRouting` is `true`.
    ///
    /// - Parameters:
    ///   - message: The human-readable prompt describing what's being asked.
    ///   - requestedSchema: The schema describing the fields requested.
    ///   - coordinator: The coordinator to route to.
    /// - Returns: The user's response.
    public static func route(
        message: String,
        requestedSchema: Elicitation.RequestSchema,
        coordinator: any ElicitationCoordinator
    ) async -> ElicitationResponse {
        if requestedSchema.requiresURLModeRouting {
            return await coordinator.elicit(message: message, url: nil)
        }
        return await coordinator.elicit(message: message, requestedSchema: requestedSchema)
    }
}
