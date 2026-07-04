import FoundationModelsMCP
import MCP

/// A recording, single-scripted-response test double for
/// ``ElicitationCoordinator``.
///
/// Every call — whether routed to
/// ``ElicitationCoordinator/elicit(message:requestedSchema:)`` (form mode) or
/// ``ElicitationCoordinator/elicit(message:url:)`` (URL mode) — is recorded
/// exactly, in call order, and answered with the one `response` this
/// instance was constructed with; tests that need a different response
/// construct a fresh instance, matching this fixture family's
/// one-scripted-response-per-instance pattern.
///
/// An `actor`, not `@unchecked Sendable` like `MockClient`, because
/// ``ElicitationCoordinator`` calls arrive from the wrapped `MCP.Client`'s
/// own message-handling task, not synchronously from the test function's own
/// task — genuine concurrent access is possible here, unlike `MockClient`
/// (see that type's own synchronization-invariant doc for the contrast).
///
/// Test-fixture only — never shipped in the library.
actor RecordingElicitationCoordinator: ElicitationCoordinator {
    /// One recorded ``ElicitationCoordinator/elicit(message:requestedSchema:)``
    /// (form-mode) call.
    struct FormCall: Equatable {
        /// The prompt shown to the user.
        let message: String
        /// The schema describing the fields requested.
        let requestedSchema: Elicitation.RequestSchema
    }

    /// One recorded ``ElicitationCoordinator/elicit(message:url:)``
    /// (URL-mode) call.
    struct URLCall: Equatable {
        /// The prompt shown to the user.
        let message: String
        /// The link the user should visit, or `nil` when no genuine link
        /// exists — see ``ElicitationCoordinator/elicit(message:url:)``.
        let url: String?
    }

    /// Every form-mode call, in call order.
    private(set) var formCalls: [FormCall] = []

    /// Every URL-mode call, in call order.
    private(set) var urlCalls: [URLCall] = []

    /// The response returned by every call this instance answers.
    private let response: ElicitationResponse

    /// Creates a coordinator that answers every call with `response`.
    ///
    /// - Parameter response: The response every call receives.
    init(responding response: ElicitationResponse) {
        self.response = response
    }

    func elicit(message: String, requestedSchema: Elicitation.RequestSchema) async -> ElicitationResponse {
        formCalls.append(FormCall(message: message, requestedSchema: requestedSchema))
        return response
    }

    func elicit(message: String, url: String?) async -> ElicitationResponse {
        urlCalls.append(URLCall(message: message, url: url))
        return response
    }
}
