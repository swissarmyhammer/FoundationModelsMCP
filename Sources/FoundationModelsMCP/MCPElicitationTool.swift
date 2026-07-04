import Foundation
import FoundationModels
import MCP

/// A `FoundationModels.Tool` that lets the *agent itself* initiate
/// elicitation — asking the user a structured question mid-conversation —
/// as opposed to the server-initiated elicitation ``MCPServer`` already
/// routes to a host-provided ``ElicitationCoordinator`` (see
/// `MCPServer.swift`'s "Elicitation" section).
///
/// Both directions share the *same* ``ElicitationCoordinator`` (per
/// `plan.md`'s "Elicitation is unified" decision) and the same wire shape —
/// `message` + a flat-primitive `requestedSchema`. The difference is entirely
/// in how a `requestedSchema` comes to exist: a server already has one to
/// send over the wire, verbatim; this tool's caller is the *model*, which has
/// no wire to send anything over — it can only ever produce whatever shape
/// ``parameters`` constrains its generation to.
///
/// `DynamicGenerationSchema`/`GenerationSchema` have no construct for an
/// open-ended dictionary (arbitrary model-chosen keys mapped to per-key
/// schemas) — every property must be named at schema-construction time. A
/// `requestedSchema`'s `properties` map, which by definition has
/// model-chosen field names, can't be represented as a single generated
/// property. This tool works around that with a **structure-of-arrays**
/// shape instead of the more obvious (but disallowed — see below) array of
/// per-field objects: ``fieldNamesKey``, ``fieldTypesKey``, and
/// ``fieldDescriptionsKey`` are parallel arrays correlated by index, and
/// ``requiredFieldNamesKey``/``sensitiveFieldNamesKey``/``urlFormatFieldNamesKey``
/// each name a subset of ``fieldNamesKey`` by value. Every one of these is an
/// array of a flat primitive (`string`), never an array of objects, so the
/// model still gets *real* constrained decoding over each field's name and
/// type (``fieldTypesKey``'s items are enum-constrained to the four JSON
/// Schema primitive type names) — unlike, say, asking the model to produce
/// one opaque JSON-encoded string, which constrained decoding could not
/// meaningfully restrict.
///
/// The task this type was built for requires the declared ``parameters``'
/// `SchemaIR` (see ``SchemaConverter``) to contain **no nested-object or
/// array-of-object node** anywhere — provable directly on the inspectable
/// IR, not just asserted informally. ``inputSchema`` satisfies that by
/// construction: its every property is either `.string` or `.array(items:
/// .string)`/`.array(items: .enumeration)`, never `.object` nor an array of
/// one.
public struct MCPElicitationTool: FoundationModels.Tool {
    /// `GeneratedContent` already conforms to `ConvertibleFromGeneratedContent`
    /// (the identity conversion), so no per-tool `Generable` type is needed —
    /// see `MCPTool.swift`'s own rationale for the same choice.
    public typealias Arguments = GeneratedContent

    /// This tool's fixed, model-facing name.
    ///
    /// Unlike ``MCPTool``, which sources its name from a discovered
    /// `MCP.Tool`, this tool has no source definition to name itself
    /// after — its identity is fixed at the type level.
    public static let toolName = "ask_user"

    /// The `message` argument's property key in ``inputSchema`` and in the
    /// `GeneratedContent` ``call(arguments:)`` receives.
    private static let messageKey = "message"

    /// The ordered field-name argument's property key — see the type-level
    /// documentation's "structure-of-arrays" rationale.
    private static let fieldNamesKey = "fieldNames"

    /// The per-field JSON Schema primitive type argument's property key,
    /// parallel to ``fieldNamesKey`` by index.
    private static let fieldTypesKey = "fieldTypes"

    /// The per-field human-readable description argument's property key,
    /// parallel to ``fieldNamesKey`` by index.
    private static let fieldDescriptionsKey = "fieldDescriptions"

    /// The required-subset argument's property key: the ``fieldNamesKey``
    /// values (by name, not index) the user must answer.
    private static let requiredFieldNamesKey = "requiredFieldNames"

    /// The sensitive-subset argument's property key: the ``fieldNamesKey``
    /// values (by name, not index) holding a secret that must never be
    /// collected via an ordinary form — see
    /// ``Elicitation/RequestSchema/requiresURLModeRouting``.
    private static let sensitiveFieldNamesKey = "sensitiveFieldNames"

    /// The URL-typed-subset argument's property key: the ``fieldNamesKey``
    /// values (by name, not index) whose answer must be a URL — also routed
    /// to URL mode, per ``Elicitation/RequestSchema/requiresURLModeRouting``.
    private static let urlFormatFieldNamesKey = "urlFormatFieldNames"

    /// The JSON Schema keyword naming a field's primitive type, written into
    /// each synthesized `requestedSchema` property — matches
    /// `SchemaConverter.primitiveTypeMap`'s own keys.
    private static let typeKeyword = "type"

    /// The JSON Schema keyword naming a field's human-readable description.
    private static let descriptionKeyword = "description"

    /// The JSON Schema primitive type names ``fieldTypesKey``'s items are
    /// enum-constrained to, and the table `Elicitation.RequestSchema`
    /// properties are built from — the flat-primitive elicitation subset.
    private static let fieldTypeNames = ["string", "integer", "number", "boolean"]

    /// The primitive type name substituted for a ``fieldNamesKey`` entry
    /// whose parallel ``fieldTypesKey`` entry is missing (a shorter
    /// `fieldTypes` array than `fieldNames`) — a defensive fallback for a
    /// call that violates the correlated-arrays contract ``inputSchema``
    /// describes, never expected from a model actually constrained by
    /// ``parameters``.
    private static let defaultFieldTypeName = fieldTypeNames[0]

    /// The paragraph rendered for the model when the coordinator's response
    /// is ``ElicitationResponse/decline``.
    private static let declinedRendering = "The user declined to answer this request."

    /// The paragraph rendered for the model when the coordinator's response
    /// is ``ElicitationResponse/cancel``.
    private static let cancelledRendering = "The user dismissed this request without answering."

    /// The header rendered before the user's structured answer when the
    /// coordinator's response is ``ElicitationResponse/accept(content:)``.
    private static let acceptedRenderingHeader = "The user answered:"

    /// A JSON Schema `array` property whose `items` is a plain `.string`, the
    /// shape shared by every ``fieldNamesKey``-correlated argument except
    /// ``fieldTypesKey`` (which additionally enum-constrains its items).
    ///
    /// - Parameter description: The property's JSON Schema `description`.
    /// - Returns: The property's JSON Schema node.
    private static func stringArrayProperty(description: String) -> Value {
        .object([
            typeKeyword: .string("array"),
            "items": .object([typeKeyword: .string("string")]),
            descriptionKeyword: .string(description),
        ])
    }

    /// This tool's raw JSON Schema `inputSchema` — hand-authored (this tool
    /// has no source `MCP.Tool` to convert), parsed by ``SchemaConverter``
    /// into ``parameters`` at ``init(coordinator:)``, and exposed here so
    /// tests can assert its `SchemaIR` shape directly (see the type-level
    /// documentation).
    ///
    /// - Important: Every property is a `.string` or a `.string`-`items`
    ///   `.array` — never an `.object`, and never an array of one — by
    ///   construction, per the type-level "structure-of-arrays" rationale.
    public static let inputSchema: Value = .object([
        typeKeyword: .string("object"),
        "properties": .object([
            messageKey: .object([
                typeKeyword: .string("string"),
                descriptionKeyword: .string(
                    "The human-readable prompt describing what's being asked of the user."),
            ]),
            fieldNamesKey: stringArrayProperty(
                description:
                    "The ordered field names to elicit from the user. Every array below is correlated to this one: fieldTypes and fieldDescriptions by matching index, and requiredFieldNames/sensitiveFieldNames/urlFormatFieldNames by naming a subset of these values."
            ),
            fieldTypesKey: .object([
                typeKeyword: .string("array"),
                "items": .object([
                    typeKeyword: .string("string"),
                    "enum": .array(fieldTypeNames.map(Value.string)),
                ]),
                descriptionKeyword: .string(
                    "Parallel to fieldNames: the JSON Schema primitive type of each requested field, by index."
                ),
            ]),
            fieldDescriptionsKey: stringArrayProperty(
                description:
                    "Parallel to fieldNames: a human-readable description of each requested field, by index. Pass an empty string for a field with no description."
            ),
            requiredFieldNamesKey: stringArrayProperty(
                description:
                    "The subset of fieldNames the user must answer; any name not listed here is optional."
            ),
            sensitiveFieldNamesKey: stringArrayProperty(
                description:
                    "The subset of fieldNames holding a secret (password, token, or payment credential) that must never be collected via an ordinary form; routes the whole request to URL mode."
            ),
            urlFormatFieldNamesKey: stringArrayProperty(
                description:
                    "The subset of fieldNames whose answer must be a URL; routes the whole request to URL mode."
            ),
        ]),
        "required": .array([.string(messageKey), .string(fieldNamesKey), .string(fieldTypesKey)]),
    ])

    /// The coordinator every ``call(arguments:)`` routes to via
    /// ``ElicitationRouting/route(message:requestedSchema:coordinator:)`` —
    /// the same protocol ``MCPServer`` routes server-initiated elicitation
    /// to.
    private let coordinator: any ElicitationCoordinator

    /// This tool's fixed model-facing name — always ``toolName``.
    public var name: String { Self.toolName }

    /// This tool's fixed model-facing description.
    public var description: String {
        "Asks the user a structured question and waits for their answer, routed through the host application's own elicitation UI. Use this when you need information only the user can provide, instead of guessing."
    }

    /// The tool's argument schema, precomputed once at construction from
    /// ``inputSchema`` via ``SchemaConverter``.
    public let parameters: GenerationSchema

    /// Always `true`: the converted ``parameters`` schema is injected into
    /// the model's instructions so it knows this tool's argument shape.
    public let includesSchemaInInstructions = true

    /// Creates the agent-initiated elicitation tool, converting
    /// ``inputSchema`` into a `GenerationSchema` up front.
    ///
    /// - Parameter coordinator: The coordinator every ``call(arguments:)``
    ///   routes to.
    /// - Throws: Whatever `SchemaConverter.emit(_:)` throws if
    ///   ``inputSchema`` parses into an invalid `DynamicGenerationSchema`
    ///   type graph — not expected in practice, since ``inputSchema`` is
    ///   fixed and covered by this type's own tests.
    public init(coordinator: any ElicitationCoordinator) throws {
        self.coordinator = coordinator
        let conversion = SchemaConverter.parse(Self.inputSchema, name: Self.toolName)
        self.parameters = try SchemaConverter.emit(conversion)
    }

    /// Elicits from the user and renders the outcome for the model.
    ///
    /// Builds an ``Elicitation/RequestSchema`` from `arguments`'
    /// structure-of-arrays fields (see the type-level documentation), routes
    /// it to ``coordinator`` via
    /// ``ElicitationRouting/route(message:requestedSchema:coordinator:)`` —
    /// which itself enforces the no-secrets-in-form-mode rule — and renders
    /// the coordinator's ``ElicitationResponse``:
    /// - `.accept(content:)`: the structured answer, as sorted-key JSON,
    ///   under an ``acceptedRenderingHeader`` header.
    /// - `.decline`: ``declinedRendering``.
    /// - `.cancel`: ``cancelledRendering``.
    ///
    /// - Parameter arguments: The generated arguments, already constrained
    ///   against ``parameters`` by the calling session.
    /// - Returns: The rendered outcome text.
    /// - Throws: ``GeneratedContentCodecError/argumentsRequireObject`` if
    ///   `arguments.kind` is not `.structure` (arguments constrained against
    ///   an object-shaped ``parameters`` schema always are).
    public func call(arguments: GeneratedContent) async throws -> String {
        let fields = try GeneratedContentCodec.arguments(from: arguments)
        let message = fields[Self.messageKey]?.stringValue ?? ""
        let requestedSchema = Self.makeRequestSchema(from: fields)

        let response = await ElicitationRouting.route(
            message: message, requestedSchema: requestedSchema, coordinator: coordinator)
        return Self.render(response: response)
    }

    /// Reads a `Value`'s `.array` elements as strings, for one of
    /// ``inputSchema``'s array properties.
    ///
    /// - Parameter value: The raw argument value to read, typically a
    ///   dictionary lookup like `fields[fieldNamesKey]`.
    /// - Returns: The array's elements coerced to `String`, or an empty
    ///   array if `value` is `nil` or not a `.array`.
    private static func stringArray(_ value: Value?) -> [String] {
        guard case .array(let elements)? = value else { return [] }
        return elements.compactMap(\.stringValue)
    }

    /// Builds the ``Elicitation/RequestSchema`` this tool sends to
    /// ``coordinator``, from `arguments`' structure-of-arrays fields.
    ///
    /// - Parameter fields: The `call(arguments:)` arguments, already decoded
    ///   into `[String: Value]` by `GeneratedContentCodec`.
    /// - Returns: The equivalent `Elicitation.RequestSchema`, with each
    ///   `fieldNamesKey` entry becoming one `properties` entry keyed by name,
    ///   annotated with its type, optional description, and (when the name
    ///   appears in `sensitiveFieldNamesKey`/`urlFormatFieldNamesKey`) the
    ///   `secret`/`format: "url"` markers ``Elicitation/RequestSchema/requiresURLModeRouting``
    ///   checks for.
    private static func makeRequestSchema(from fields: [String: Value]) -> Elicitation.RequestSchema {
        let fieldNames = stringArray(fields[fieldNamesKey])
        let fieldTypes = stringArray(fields[fieldTypesKey])
        let fieldDescriptions = stringArray(fields[fieldDescriptionsKey])
        let requiredFieldNames = Set(stringArray(fields[requiredFieldNamesKey]))
        let sensitiveFieldNames = Set(stringArray(fields[sensitiveFieldNamesKey]))
        let urlFormatFieldNames = Set(stringArray(fields[urlFormatFieldNamesKey]))

        var properties: [String: Value] = [:]
        for (index, name) in fieldNames.enumerated() {
            properties[name] = makeFieldSchema(
                type: fieldTypes.indices.contains(index) ? fieldTypes[index] : defaultFieldTypeName,
                description: fieldDescriptions.indices.contains(index) ? fieldDescriptions[index] : "",
                isSensitive: sensitiveFieldNames.contains(name),
                isURLFormat: urlFormatFieldNames.contains(name)
            )
        }

        // Only fieldNames' own entries become properties (the loop above),
        // so a stray requiredFieldNames entry not present in fieldNames is
        // intersected away here — a `required` list naming a property that
        // doesn't exist would describe an invalid requestedSchema no
        // ElicitationCoordinator is contracted to handle.
        let required = requiredFieldNames.intersection(properties.keys)
        return Elicitation.RequestSchema(
            properties: properties,
            required: required.isEmpty ? nil : required.sorted()
        )
    }

    /// Builds one `requestedSchema.properties` entry.
    ///
    /// - Parameters:
    ///   - type: The field's JSON Schema primitive type name.
    ///   - description: The field's human-readable description, or an empty
    ///     string to omit the `description` keyword entirely.
    ///   - isSensitive: Whether to mark this field
    ///     ``Elicitation/RequestSchema/secretKeyword``.
    ///   - isURLFormat: Whether to mark this field `format: "url"`.
    /// - Returns: The field's JSON Schema node.
    private static func makeFieldSchema(
        type: String, description: String, isSensitive: Bool, isURLFormat: Bool
    ) -> Value {
        var fieldSchema: [String: Value] = [typeKeyword: .string(type)]
        if !description.isEmpty {
            fieldSchema[descriptionKeyword] = .string(description)
        }
        if isSensitive {
            fieldSchema[Elicitation.RequestSchema.secretKeyword] = .bool(true)
        }
        if isURLFormat {
            fieldSchema[Elicitation.RequestSchema.formatKeyword] = .string(
                Elicitation.RequestSchema.urlFormatValue)
        }
        return .object(fieldSchema)
    }

    /// Renders an ``ElicitationResponse`` for the model — see
    /// ``call(arguments:)``'s documentation for the three distinct outcomes.
    ///
    /// - Parameter response: The coordinator's response.
    /// - Returns: The rendered outcome text.
    private static func render(response: ElicitationResponse) -> String {
        switch response {
        case .accept(let content):
            return "\(acceptedRenderingHeader)\n\(ToolContentRenderer.jsonString(for: .object(content)))"
        case .decline:
            return declinedRendering
        case .cancel:
            return cancelledRendering
        }
    }
}
