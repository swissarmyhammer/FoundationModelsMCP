import Foundation
import MCP

/// Renders a `tools/call` result — `Tool.Content` items, `isError`, and an
/// optional `structuredContent` — into the `String` a `FoundationModels.Tool`
/// adapter (see `MCPTool`) hands back as its `call(arguments:)` `Output`.
///
/// `String` already conforms to `PromptRepresentable`, so no bespoke output
/// type is needed to satisfy `Tool`'s associated type.
///
/// Rendering is deterministic and lossy by design: binary payloads
/// (`.image`/`.audio`/resource blobs) are described, never inlined, and
/// `.resourceLink` is described from its own declared metadata only — the
/// link is never fetched to learn more about it.
public enum ToolContentRenderer {

    /// Renders a `tools/call` result for the model.
    ///
    /// Output shape: each `content` item is rendered (see the per-case rules
    /// below) and the results are joined with newlines; a `structuredContent`
    /// section (see ``renderStructuredContent(_:outputSchema:)``) is appended
    /// after a blank line, if present. If `isError == true`, an `"Error:"`
    /// paragraph is prepended — the failure is marked, never hidden, and the
    /// content/structuredContent that accompanies it is still rendered in
    /// full.
    ///
    /// Per-content-case rendering:
    /// - `.text`: the text, verbatim.
    /// - `.image` / `.audio`: a `"[image: <mimeType>]"` / `"[audio:
    ///   <mimeType>]"` placeholder — the base64 payload is never rendered.
    /// - `.resource`: the embedded `text`, prefixed with its `uri`, when the
    ///   resource carries text; otherwise a placeholder naming the `uri` and
    ///   `mimeType` — a binary `blob` is never decoded or rendered.
    /// - `.resourceLink`: a `"[resource link: <title-or-name> <uri>]"`
    ///   descriptor built only from the link's own fields (`uri`, `name`,
    ///   `title`, `mimeType`) — the link is never dereferenced, so its
    ///   `description` (which describes the *target*, not the link itself)
    ///   and any other information that would require fetching it are not
    ///   part of the rendered output.
    ///
    /// - Parameters:
    ///   - result: The `tools/call` result to render.
    ///   - outputSchema: The tool's declared `outputSchema` (`Tool.outputSchema`),
    ///     used to validate `result.structuredContent` against the pinned
    ///     subset in ``renderStructuredContent(_:outputSchema:)``. `nil` skips
    ///     validation entirely.
    /// - Returns: The rendered text.
    public static func render(_ result: CallTool.Result, outputSchema: Value? = nil) -> String {
        var sections: [String] = []

        let body = result.content.map(render(content:)).joined(separator: "\n")
        if !body.isEmpty {
            sections.append(body)
        }

        if let structuredContent = result.structuredContent {
            sections.append(renderStructuredContent(structuredContent, outputSchema: outputSchema))
        }

        if result.isError == true {
            sections.insert("Error:", at: 0)
        }

        return sections.joined(separator: "\n\n")
    }

    // MARK: - Content

    /// Renders one `Tool.Content` item.
    ///
    /// See ``render(_:outputSchema:)`` for the documented per-case format.
    private static func render(content: Tool.Content) -> String {
        switch content {
        case .text(let text, _, _):
            return text
        case .image(_, let mimeType, _, _):
            return "[image: \(mimeType)]"
        case .audio(_, let mimeType, _, _):
            return "[audio: \(mimeType)]"
        case .resource(let resource, _, _):
            return renderResource(resource)
        case .resourceLink(let uri, let name, let title, _, let mimeType, _):
            return renderResourceLink(uri: uri, name: name, title: title, mimeType: mimeType)
        }
    }

    /// Renders an embedded resource (`EmbeddedResource`).
    ///
    /// Text resources are rendered in full; binary resources (only a
    /// `blob`) are described, not decoded — see ``render(_:outputSchema:)``.
    private static func renderResource(_ resource: Resource.Content) -> String {
        if let text = resource.text {
            return "[resource: \(resource.uri)]\n\(text)"
        }
        let mimeType = resource.mimeType ?? "application/octet-stream"
        return "[resource: \(resource.uri) (\(mimeType))]"
    }

    /// Renders a `.resourceLink` from its own declared fields only.
    ///
    /// Never fetches `uri` — see ``render(_:outputSchema:)``.
    private static func renderResourceLink(
        uri: String, name: String, title: String?, mimeType: String?
    ) -> String {
        let label = title ?? name
        if let mimeType {
            return "[resource link: \(label) <\(uri)> (\(mimeType))]"
        }
        return "[resource link: \(label) <\(uri)>]"
    }

    // MARK: - structuredContent + outputSchema validation

    /// Renders `structuredContent` as sorted-key JSON under a `"Structured
    /// result:"` header, then — when `outputSchema` is supplied —
    /// validates it against the **pinned shallow-validation subset**
    /// documented on ``validate(_:against:)`` and appends any failures as a
    /// `"Note:"` list.
    ///
    /// A validation failure never hides `structuredContent`; it is always
    /// appended alongside the content it describes.
    private static func renderStructuredContent(_ value: Value, outputSchema: Value?) -> String {
        var lines = ["Structured result:", jsonString(for: value)]

        if let outputSchema {
            let issues = validate(value, against: outputSchema)
            if !issues.isEmpty {
                lines.append("Note: structuredContent does not match the declared outputSchema:")
                lines.append(contentsOf: issues.map { "- \($0)" })
            }
        }

        return lines.joined(separator: "\n")
    }

    /// Renders a `Value` as sorted-key JSON text, for deterministic,
    /// diffable output.
    private static func jsonString(for value: Value) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value),
            let string = String(data: data, encoding: .utf8)
        else {
            return value.description
        }
        return string
    }

    /// Validates `value` against `schema` using a **pinned shallow subset**
    /// of JSON Schema — this is *not* a full JSON Schema validator.
    ///
    /// Exactly four checks are performed:
    ///
    /// 1. **Top-level `type`**: if `schema.type` is present, it must match
    ///    `value`'s JSON type (`"object"`/`"array"`/`"string"`/`"integer"`/
    ///    `"number"`/`"boolean"`/`"null"`). An `.int` value also satisfies a
    ///    `"number"` schema type.
    /// 2. **`required`**: every name in `schema.required` must be a key of
    ///    `value` (checked only when `value` is an object).
    /// 3. **Per-property `type`**: for each key in `schema.properties` that
    ///    is also a key of `value`, that property's own `type` (if declared)
    ///    must match the corresponding value's JSON type — one level deep;
    ///    the property schema's own nested keywords are not recursed into.
    /// 4. **Per-property `enum`**: for each key in `schema.properties` that
    ///    declares an `enum`, the corresponding value (in its scalar string
    ///    form) must be a member.
    ///
    /// Every other JSON Schema keyword — `additionalProperties`, `pattern`,
    /// `format`, `minimum`/`maximum`, `items`, a property's own nested
    /// `properties`/`required`, `$ref`, `oneOf`/`anyOf`, etc. — is outside
    /// this subset and is never inspected: a schema that relies on them
    /// validates exactly as if they were absent, neither enforced nor
    /// rejected.
    ///
    /// - Parameters:
    ///   - value: The `structuredContent` value to validate.
    ///   - schema: The tool's declared `outputSchema`.
    /// - Returns: Human-readable descriptions of every subset rule violated,
    ///   or an empty array if `value` satisfies all of them (or `schema` is
    ///   not an object node, in which case nothing in the subset applies).
    private static func validate(_ value: Value, against schema: Value) -> [String] {
        guard case .object(let schemaFields) = schema else { return [] }
        var issues: [String] = []

        if let expectedType = schemaFields["type"]?.stringValue,
            !matchesType(expectedType, value: value)
        {
            issues.append("expected type \"\(expectedType)\", got \"\(jsonType(of: value))\"")
        }

        guard case .object(let objectFields) = value else {
            // `required`/`properties` only apply when `value` is itself an
            // object — nothing further in the subset applies otherwise.
            return issues
        }

        if case .array(let requiredValues)? = schemaFields["required"] {
            for requiredValue in requiredValues {
                guard let requiredName = requiredValue.stringValue else { continue }
                if objectFields[requiredName] == nil {
                    issues.append("missing required property \"\(requiredName)\"")
                }
            }
        }

        if case .object(let propertySchemas)? = schemaFields["properties"] {
            for (propertyName, propertySchemaValue) in propertySchemas.sorted(by: { $0.key < $1.key }) {
                guard let propertyValue = objectFields[propertyName],
                    case .object(let propertySchemaFields) = propertySchemaValue
                else { continue }

                if let expectedType = propertySchemaFields["type"]?.stringValue,
                    !matchesType(expectedType, value: propertyValue)
                {
                    issues.append(
                        "property \"\(propertyName)\" expected type \"\(expectedType)\", got \"\(jsonType(of: propertyValue))\""
                    )
                }

                if case .array(let enumValues)? = propertySchemaFields["enum"] {
                    let allowed = enumValues.compactMap(scalarString)
                    if let actual = scalarString(propertyValue), !allowed.contains(actual) {
                        issues.append(
                            "property \"\(propertyName)\" value \"\(actual)\" is not one of \(allowed)"
                        )
                    }
                }
            }
        }

        return issues
    }

    /// Whether `value`'s JSON type matches the JSON Schema primitive `type`
    /// keyword string `typeName`.
    ///
    /// An `.int` value satisfies both `"integer"` and `"number"`; a
    /// `.double` value only satisfies `"number"`. An unrecognized
    /// `typeName` is outside the validated subset and is treated as
    /// satisfied (never a failure).
    ///
    /// Looked up from ``jsonTypeTable`` by name — the same table
    /// ``jsonType(of:)`` uses to name a value's canonical type, reused here
    /// to test membership against a schema-declared type name instead of a
    /// parallel switch.
    private static func matchesType(_ typeName: String, value: Value) -> Bool {
        guard let entry = jsonTypeTable.first(where: { $0.name == typeName }) else {
            return true
        }
        return entry.matches(value)
    }

    /// The JSON Schema primitive type name for `value`'s case, used to
    /// report a ``matchesType(_:value:)`` mismatch.
    ///
    /// Looked up from ``jsonTypeTable`` instead of a switch, since every
    /// case differs only in the constant type-name string it maps to.
    private static func jsonType(of value: Value) -> String {
        guard let entry = jsonTypeTable.first(where: { $0.matches(value) }) else {
            preconditionFailure("Value case not covered by jsonTypeTable")
        }
        return entry.name
    }

    /// `Value` case → JSON Schema primitive type name and membership test,
    /// checked in order using the case-testing accessors `Value` already
    /// exposes (`isNull`, `boolValue`, `intValue`, etc.) instead of
    /// pattern-matching again.
    ///
    /// Shared by both consumers: ``jsonType(of:)`` takes the first entry
    /// whose `matches` predicate accepts a value, in table order, to get
    /// its canonical type name; ``matchesType(_:value:)`` looks up the
    /// entry by `name` and evaluates its `matches` predicate against a
    /// schema-declared type name instead.
    ///
    /// `"number"` also matches `.int` (in addition to `"integer"`'s own
    /// entry) so an `.int` value satisfies both, per
    /// ``matchesType(_:value:)``; `.int` still resolves to the canonical
    /// name `"integer"` in ``jsonType(of:)`` because `"integer"` is checked
    /// first. `"string"` also matches `.data` — which decodes from a JSON
    /// string (a data URL) — so it is reported as `"string"` too.
    private static let jsonTypeTable: [(name: String, matches: @Sendable (Value) -> Bool)] = [
        ("null", { $0.isNull }),
        ("boolean", { $0.boolValue != nil }),
        ("integer", { $0.intValue != nil }),
        ("number", { $0.intValue != nil || $0.doubleValue != nil }),
        ("string", { $0.stringValue != nil || $0.dataValue != nil }),
        ("array", { $0.arrayValue != nil }),
        ("object", { $0.objectValue != nil }),
    ]

    /// Renders any scalar `Value` (string/int/double/bool) to its string
    /// form, for `enum` membership comparison.
    ///
    /// Non-scalar values (array/object/null/data) have no defined enum
    /// representation and return `nil`.
    private static func scalarString(_ value: Value) -> String? {
        switch value {
        case .string(let string): return string
        case .int(let int): return String(describing: int)
        case .double(let double): return String(describing: double)
        case .bool(let bool): return String(describing: bool)
        default: return nil
        }
    }
}
