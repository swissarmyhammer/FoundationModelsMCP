import Foundation
import FoundationModelsMCP
import MCP

/// A minimal console-based ``ElicitationCoordinator``: prints every request
/// to standard output, then resolves it either from real interactive input
/// (typing `accept`, `decline`, or `cancel` at the terminal and pressing
/// return) or, when no interactive input is available — e.g. this example
/// running non-interactively in CI, where standard input is already at
/// end-of-file — from a deterministic scripted rotation through the three
/// actions. Either way, an `.accept` answer is filled with placeholder field
/// values derived from the requested schema's declared types, rather than
/// prompting for each field individually.
///
/// One instance of this coordinator serves *both* elicitation directions
/// `Examples/ElicitingAgent` demonstrates — the `MCPServer`-routed
/// server-initiated request (this type's ``elicit(message:requestedSchema:)``)
/// and the `MCPElicitationTool`-routed agent-initiated request (the very same
/// method, since `MCPElicitationTool` routes through the identical
/// `ElicitationCoordinator` protocol) — per `plan.md`'s "Elicitation is
/// unified" decision.
///
/// An `actor` so ``callCount`` — the state backing the scripted-rotation
/// fallback — is safely shared across however many concurrent elicitation
/// requests arrive.
public actor ConsoleElicitationCoordinator: ElicitationCoordinator {
    /// The three actions an elicitation response can take, named after
    /// `ElicitationResponse`'s own cases.
    public enum Action: String, CaseIterable, Sendable {
        case accept
        case decline
        case cancel
    }

    /// The deterministic fallback sequence ``resolveAction()`` cycles through
    /// by call index whenever ``readInputLine`` yields no recognizable
    /// action — the "auto-accept/decline/cancel based on a simple rule" this
    /// type falls back to for a non-interactive run.
    private let fallbackScript: [Action]

    /// Reads one line of interactive input from standard input, or `nil` if
    /// none is available (e.g. standard input is already at end-of-file).
    ///
    /// Injectable (rather than calling the global `readLine` directly) so
    /// tests can drive this coordinator with scripted input instead of the
    /// real console.
    private let readInputLine: @Sendable () -> String?

    /// How many elicitation requests this coordinator has resolved so far —
    /// advances ``fallbackScript``'s rotation index in ``resolveAction()``.
    private var callCount = 0

    /// Creates a console elicitation coordinator.
    ///
    /// - Parameters:
    ///   - fallbackScript: The deterministic rotation to fall back to when no
    ///     interactive input is available. Defaults to
    ///     ``Action/allCases``. Replaced by ``Action/allCases`` if passed
    ///     empty, since an empty script has no action to fall back to.
    ///   - readInputLine: Reads one line of interactive input, or `nil` if
    ///     none is available. Defaults to the real console
    ///     (`Swift.readLine(strippingNewline:)`); overridable so tests can
    ///     supply scripted input.
    public init(
        fallbackScript: [Action] = Action.allCases,
        readInputLine: @escaping @Sendable () -> String? = { Swift.readLine(strippingNewline: true) }
    ) {
        self.fallbackScript = fallbackScript.isEmpty ? Action.allCases : fallbackScript
        self.readInputLine = readInputLine
    }

    /// Presents a form-mode elicitation request at the console and resolves
    /// it — see the type-level documentation for how.
    ///
    /// - Parameters:
    ///   - message: The human-readable prompt describing what's being asked.
    ///   - requestedSchema: The flat-primitive schema describing the fields
    ///     to collect.
    /// - Returns: The resolved response.
    public func elicit(message: String, requestedSchema: Elicitation.RequestSchema) async -> ElicitationResponse {
        print("\n[Elicitation - form] \(message)")
        for fieldName in requestedSchema.properties.keys.sorted() {
            print("  field: \(fieldName)")
        }
        return respond(action: resolveAction(), requestedSchema: requestedSchema)
    }

    /// Presents a URL-mode elicitation request at the console and resolves
    /// it — see the type-level documentation for how.
    ///
    /// - Parameters:
    ///   - message: The human-readable prompt describing what's being asked.
    ///   - url: The link the user should visit, or `nil` if none exists (see
    ///     ``ElicitationCoordinator/elicit(message:url:)``'s own
    ///     documentation for when that happens).
    /// - Returns: The resolved response.
    public func elicit(message: String, url: String?) async -> ElicitationResponse {
        print("\n[Elicitation - url] \(message)")
        print("  url: \(url ?? "<none>")")
        return respond(action: resolveAction(), requestedSchema: nil)
    }

    /// Resolves the next action: real interactive input if
    /// ``readInputLine`` yields a recognizable ``Action`` name, otherwise
    /// ``fallbackScript``'s next entry.
    ///
    /// - Returns: The resolved action.
    private func resolveAction() -> Action {
        defer { callCount += 1 }
        if let line = readInputLine(),
            let typed = Action(rawValue: line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        {
            return typed
        }
        return Self.scriptedAction(at: callCount, script: fallbackScript)
    }

    /// The scripted fallback action for the `index`th elicitation request,
    /// cycling through `script` — pulled out of ``resolveAction()`` as a pure
    /// `static` function so it's directly testable without stdin or actor
    /// isolation.
    ///
    /// - Parameters:
    ///   - index: The 0-based call index.
    ///   - script: The rotation to cycle through. Must be non-empty.
    /// - Returns: `script[index % script.count]`.
    static func scriptedAction(at index: Int, script: [Action]) -> Action {
        script[index % script.count]
    }

    /// Prints and returns the ``ElicitationResponse`` for `action`.
    ///
    /// - Parameters:
    ///   - action: The resolved action.
    ///   - requestedSchema: The requested schema, or `nil` for a URL-mode
    ///     request (which has none) — forwarded to
    ///     ``placeholderContent(for:)`` when `action` is ``Action/accept``.
    /// - Returns: The corresponding ``ElicitationResponse``.
    private func respond(action: Action, requestedSchema: Elicitation.RequestSchema?) -> ElicitationResponse {
        switch action {
        case .accept:
            let content = Self.placeholderContent(for: requestedSchema)
            print("  -> accept: \(content)")
            return .accept(content: content)
        case .decline:
            print("  -> decline")
            return .decline
        case .cancel:
            print("  -> cancel")
            return .cancel
        }
    }

    /// Builds placeholder `.accept` content for every property in
    /// `requestedSchema`, one per declared field — this coordinator never
    /// prompts for each field's value individually (see the type-level
    /// documentation).
    ///
    /// - Parameter requestedSchema: The requested schema, or `nil` for a
    ///   URL-mode request.
    /// - Returns: One entry per `requestedSchema.properties` key, or empty if
    ///   `requestedSchema` is `nil`.
    static func placeholderContent(for requestedSchema: Elicitation.RequestSchema?) -> [String: Value] {
        guard let requestedSchema else { return [:] }
        var content: [String: Value] = [:]
        for (name, propertySchema) in requestedSchema.properties {
            content[name] = placeholderValue(for: propertySchema)
        }
        return content
    }

    /// A placeholder value for one requested field, chosen from its declared
    /// JSON Schema `type`.
    ///
    /// - Parameter propertySchema: The field's own JSON Schema fragment.
    /// - Returns: `42` for `"integer"`, `42.0` for `"number"`, `true` for
    ///   `"boolean"`, and `"example"` for `"string"` or any other/missing
    ///   `type`.
    static func placeholderValue(for propertySchema: Value) -> Value {
        guard case .object(let fields) = propertySchema, let type = fields["type"]?.stringValue else {
            return .string("example")
        }
        switch type {
        case "integer": return .int(42)
        case "number": return .double(42.0)
        case "boolean": return .bool(true)
        default: return .string("example")
        }
    }
}
