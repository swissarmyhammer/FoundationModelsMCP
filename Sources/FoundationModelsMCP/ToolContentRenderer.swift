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

    /// The default render budget, in characters: the maximum length of any
    /// single rendered text unit — a `.text`/`.resource` content item's text,
    /// or `structuredContent`'s JSON — before ``trimmed(text:budget:)`` elides
    /// its middle.
    ///
    /// Tool results are the context-window cost, not the model's own output,
    /// so a single oversized result must not be allowed to dominate a
    /// transcript. 8,192 characters (roughly 2,000 tokens) is a conservative
    /// slice of a typical context window, chosen so several tool calls can
    /// still fit alongside the rest of a session — see Apple's
    /// [managing-the-context-window](https://developer.apple.com/documentation/foundationmodels/managing-the-context-window)
    /// guidance, which this renderer's *output*-side budget complements from
    /// the *input* side.
    public static let defaultRenderBudget = 8_192

    /// Renders a `tools/call` result for the model.
    ///
    /// Output shape: each `content` item is rendered (see the per-case rules
    /// below) and the results are joined with newlines; a `structuredContent`
    /// section (see ``renderStructuredContent(_:outputSchema:budget:)``) is
    /// appended after a blank line, if present. If `isError == true`, an
    /// `"Error:"` paragraph is prepended — the failure is marked, never
    /// hidden, and the content/structuredContent that accompanies it is
    /// still rendered in full.
    ///
    /// Per-content-case rendering:
    /// - `.text`: the text, trimmed to `budget` — see ``trimmed(text:budget:)``.
    /// - `.image` / `.audio`: a `"[image: <mimeType>]"` / `"[audio:
    ///   <mimeType>]"` placeholder — the base64 payload is never rendered,
    ///   regardless of `budget`.
    /// - `.resource`: the embedded `text`, prefixed with its `uri` and
    ///   trimmed to `budget`, when the resource carries text; otherwise a
    ///   placeholder naming the `uri` and `mimeType` — a binary `blob` is
    ///   never decoded or rendered.
    /// - `.resourceLink`: a `"[resource link: <title-or-name> <uri>]"`
    ///   descriptor built only from the link's own fields (`uri`, `name`,
    ///   `title`, `mimeType`) — the link is never dereferenced, so its
    ///   `description` (which describes the *target*, not the link itself)
    ///   and any other information that would require fetching it are not
    ///   part of the rendered output. Like `.image`/`.audio`'s placeholder,
    ///   this descriptor is declared metadata, not a text payload, so it is
    ///   not subject to `budget`.
    ///
    /// A `result` whose rendered text units all fall at or under `budget` is
    /// returned exactly as it would be with trimming absent — untouched,
    /// character for character.
    ///
    /// - Parameters:
    ///   - result: The `tools/call` result to render.
    ///   - outputSchema: The tool's declared `outputSchema` (`Tool.outputSchema`),
    ///     used to validate `result.structuredContent` against the pinned
    ///     subset in ``renderStructuredContent(_:outputSchema:budget:)``.
    ///     `nil` skips validation entirely.
    ///   - budget: The maximum character count for any single rendered text
    ///     unit before it is trimmed; see ``defaultRenderBudget`` for the
    ///     default and ``trimmed(text:budget:)`` for the trimming rule.
    /// - Returns: The rendered text.
    public static func render(
        result: CallTool.Result, outputSchema: Value? = nil, budget: Int = defaultRenderBudget
    ) -> String {
        var sections: [String] = []

        let body = result.content.map { render(content: $0, budget: budget) }.joined(separator: "\n")
        if !body.isEmpty {
            sections.append(body)
        }

        if let structuredContent = result.structuredContent {
            sections.append(
                renderStructuredContent(structuredContent, outputSchema: outputSchema, budget: budget))
        }

        if result.isError == true {
            sections.insert("Error:", at: 0)
        }

        return sections.joined(separator: "\n\n")
    }

    // MARK: - Content

    /// Renders one `Tool.Content` item.
    ///
    /// See ``render(result:outputSchema:budget:)`` for the documented per-case
    /// format.
    ///
    /// - Parameters:
    ///   - content: The content item to render.
    ///   - budget: The maximum character count before text-bearing cases are
    ///     trimmed; see ``trimmed(text:budget:)``.
    /// - Returns: The rendered text for `content`.
    private static func render(content: Tool.Content, budget: Int) -> String {
        switch content {
        case .text(let text, _, _):
            return trimmed(text: text, budget: budget)
        case .image(_, let mimeType, _, _):
            return "[image: \(mimeType)]"
        case .audio(_, let mimeType, _, _):
            return "[audio: \(mimeType)]"
        case .resource(let resource, _, _):
            return renderResource(resource: resource, budget: budget)
        case .resourceLink(let uri, let name, let title, _, let mimeType, _):
            return renderResourceLink(uri: uri, name: name, title: title, mimeType: mimeType)
        }
    }

    /// Renders an embedded resource (`EmbeddedResource`).
    ///
    /// Text resources are rendered in full, trimmed to `budget`; binary
    /// resources (only a `blob`) are described, not decoded — see
    /// ``render(result:outputSchema:budget:)``.
    ///
    /// - Parameters:
    ///   - resource: The embedded resource to render.
    ///   - budget: The maximum character count before the resource's `text`
    ///     is trimmed; see ``trimmed(text:budget:)``.
    /// - Returns: The rendered text for `resource`.
    private static func renderResource(resource: Resource.Content, budget: Int) -> String {
        if let text = resource.text {
            return "[resource: \(resource.uri)]\n\(trimmed(text: text, budget: budget))"
        }
        let mimeType = resource.mimeType ?? "application/octet-stream"
        return "[resource: \(resource.uri) (\(mimeType))]"
    }

    /// Renders a `.resourceLink` from its own declared fields only.
    ///
    /// Never fetches `uri` — see ``render(result:outputSchema:budget:)``.
    private static func renderResourceLink(
        uri: String, name: String, title: String?, mimeType: String?
    ) -> String {
        let label = title ?? name
        if let mimeType {
            return "[resource link: \(label) <\(uri)> (\(mimeType))]"
        }
        return "[resource link: \(label) <\(uri)>]"
    }

    // MARK: - Bounded output / render budget

    /// Trims `text` to `budget` characters, replacing an elided middle
    /// section with a marker that names exactly how many characters were
    /// removed.
    ///
    /// `text` at or under `budget` characters is returned unchanged, byte
    /// for byte — trimming never touches an already-in-budget result. An
    /// oversized `text` is split into a head and a tail kept from either end
    /// (as close to evenly as `budget` allows once the marker's own length
    /// is accounted for) with the elided middle described in between; the
    /// split point depends only on `text` and `budget`, so the same input
    /// and budget always produce the identical output.
    ///
    /// The elided count can never exceed `totalCount`, and decimal digit
    /// count is monotonic non-decreasing in value — so a marker sized for
    /// `totalCount` itself is always at least as long as the marker actually
    /// rendered below, once the real elided count is known. Reserving space
    /// for that worst case up front, rather than an approximation of the
    /// elided count, guarantees `head + marker + tail` never exceeds
    /// `budget` — the earlier approach (sizing the reservation off
    /// `totalCount - budget` before the split) could under-reserve when the
    /// approximate and actual elided counts had different digit widths
    /// (e.g. 9,999 vs. 10,000), silently overshooting `budget` by exactly
    /// the extra digit.
    ///
    /// - Parameters:
    ///   - text: The candidate text to trim.
    ///   - budget: The maximum character count `text` may occupy before it
    ///     is trimmed. When `budget` is smaller than the marker's own
    ///     minimum length — which must be long enough to name the full
    ///     elided count — the result is the marker alone, and it may itself
    ///     exceed `budget`: a marker cannot state how much was elided in
    ///     fewer characters than that statement requires.
    /// - Returns: `text` unchanged if it is at or under `budget` characters;
    ///   otherwise a `head + marker + tail` excerpt whose marker states
    ///   exactly how many characters of `text` are not shown.
    private static func trimmed(text: String, budget: Int) -> String {
        let totalCount = text.count
        guard totalCount > budget else { return text }

        let worstCaseMarker = elisionMarker(elidedCount: totalCount)
        let keptCount = max(budget - worstCaseMarker.count, 0)
        let headCount = keptCount / 2
        let tailCount = keptCount - headCount

        let head = text.prefix(headCount)
        let tail = text.suffix(tailCount)
        let marker = elisionMarker(elidedCount: totalCount - headCount - tailCount)
        return head + marker + tail
    }

    /// The elision marker naming `elidedCount`, used by ``trimmed(text:budget:)``.
    ///
    /// - Parameter elidedCount: The number of characters the marker reports
    ///   as removed.
    /// - Returns: A standalone `"[elided <elidedCount> characters]"` line.
    private static func elisionMarker(elidedCount: Int) -> String {
        "\n[elided \(elidedCount) characters]\n"
    }

    // MARK: - structuredContent + outputSchema validation

    /// Renders `structuredContent` as sorted-key JSON, trimmed to `budget`,
    /// under a `"Structured result:"` header, then — when `outputSchema` is
    /// supplied — validates the **untrimmed** value against the **pinned
    /// shallow-validation subset** documented on ``validate(value:against:)``
    /// and appends any failures as a `"Note:"` list.
    ///
    /// Validation runs against the original `value`, not the trimmed JSON
    /// text, so trimming a large payload never changes which validation
    /// issues are reported. A validation failure never hides
    /// `structuredContent`; it is always appended alongside the content it
    /// describes.
    ///
    /// - Parameters:
    ///   - value: The `structuredContent` value to render.
    ///   - outputSchema: The tool's declared `outputSchema`, or `nil` to skip
    ///     validation.
    ///   - budget: The maximum character count before the rendered JSON is
    ///     trimmed; see ``trimmed(text:budget:)``.
    /// - Returns: The rendered `"Structured result:"` section.
    private static func renderStructuredContent(_ value: Value, outputSchema: Value?, budget: Int) -> String {
        var lines = ["Structured result:", trimmed(text: jsonString(for: value), budget: budget)]

        if let outputSchema {
            let issues = validate(value: value, against: outputSchema)
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
    private static func validate(value: Value, against schema: Value) -> [String] {
        guard case .object(let schemaFields) = schema else { return [] }
        var issues: [String] = []

        if let topLevelIssue = validateTopLevelType(value: value, against: schemaFields) {
            issues.append(topLevelIssue)
        }

        guard case .object(let objectFields) = value else {
            // `required`/`properties` only apply when `value` is itself an
            // object — nothing further in the subset applies otherwise.
            return issues
        }

        issues.append(contentsOf: validateRequiredFields(objectFields: objectFields, against: schemaFields))
        issues.append(contentsOf: validatePropertyTypes(objectFields: objectFields, against: schemaFields))
        issues.append(contentsOf: validatePropertyEnums(objectFields: objectFields, against: schemaFields))

        return issues
    }

    /// Validates check 1 of ``validate(value:against:)``'s subset: `value`'s
    /// top-level JSON type against `schema`'s `type` keyword.
    ///
    /// - Parameters:
    ///   - value: The `structuredContent` value being validated.
    ///   - schemaFields: `schema`'s own fields, already unwrapped from its `.object` case.
    /// - Returns: A human-readable "expected type" issue if `schemaFields` declares
    ///   a `type` that `value` does not match; `nil` if `schemaFields` declares no
    ///   `type` or `value` satisfies it.
    private static func validateTopLevelType(value: Value, against schemaFields: [String: Value]) -> String? {
        guard let expectedType = schemaFields["type"]?.stringValue,
            !matchesType(typeName: expectedType, against: value)
        else { return nil }
        return "expected type \"\(expectedType)\", got \"\(jsonType(of: value))\""
    }

    /// Validates check 2 of ``validate(value:against:)``'s subset: every name in
    /// `schema`'s `required` array is a key of `objectFields`.
    ///
    /// - Parameters:
    ///   - objectFields: `value`'s own fields, already unwrapped from its `.object` case.
    ///   - schemaFields: `schema`'s own fields.
    /// - Returns: One "missing required property" issue per name in `schemaFields`'s
    ///   `required` array that is absent from `objectFields`; empty if `schemaFields`
    ///   declares no `required` array or every name is present.
    private static func validateRequiredFields(
        objectFields: [String: Value], against schemaFields: [String: Value]
    ) -> [String] {
        guard case .array(let requiredValues)? = schemaFields["required"] else { return [] }
        return requiredValues.compactMap { requiredValue in
            guard let requiredName = requiredValue.stringValue, objectFields[requiredName] == nil else {
                return nil
            }
            return "missing required property \"\(requiredName)\""
        }
    }

    /// Validates check 3 of ``validate(value:against:)``'s subset: each declared
    /// property's own `type` keyword, one level deep.
    ///
    /// - Parameters:
    ///   - objectFields: `value`'s own fields, already unwrapped from its `.object` case.
    ///   - schemaFields: `schema`'s own fields.
    /// - Returns: One "expected type" issue per property (sorted by name) whose
    ///   value's JSON type doesn't match its schema's declared `type`; a property
    ///   absent from `objectFields`, or whose own schema isn't an object node, is
    ///   skipped. Empty if `schemaFields` declares no `properties`.
    private static func validatePropertyTypes(
        objectFields: [String: Value], against schemaFields: [String: Value]
    ) -> [String] {
        guard case .object(let propertySchemas)? = schemaFields["properties"] else { return [] }
        var issues: [String] = []
        for (propertyName, propertySchemaValue) in propertySchemas.sorted(by: { $0.key < $1.key }) {
            guard let propertyValue = objectFields[propertyName],
                case .object(let propertySchemaFields) = propertySchemaValue,
                let expectedType = propertySchemaFields["type"]?.stringValue,
                !matchesType(typeName: expectedType, against: propertyValue)
            else { continue }
            issues.append(
                "property \"\(propertyName)\" expected type \"\(expectedType)\", got \"\(jsonType(of: propertyValue))\""
            )
        }
        return issues
    }

    /// Validates check 4 of ``validate(value:against:)``'s subset: each declared
    /// property's `enum` membership, in scalar string form.
    ///
    /// - Parameters:
    ///   - objectFields: `value`'s own fields, already unwrapped from its `.object` case.
    ///   - schemaFields: `schema`'s own fields.
    /// - Returns: One "is not one of" issue per property (sorted by name) whose
    ///   value isn't among its schema's declared `enum` members; a property absent
    ///   from `objectFields`, without a scalar string form, or without a declared
    ///   `enum`, is skipped. Empty if `schemaFields` declares no `properties`.
    private static func validatePropertyEnums(
        objectFields: [String: Value], against schemaFields: [String: Value]
    ) -> [String] {
        guard case .object(let propertySchemas)? = schemaFields["properties"] else { return [] }
        var issues: [String] = []
        for (propertyName, propertySchemaValue) in propertySchemas.sorted(by: { $0.key < $1.key }) {
            guard let propertyValue = objectFields[propertyName],
                case .object(let propertySchemaFields) = propertySchemaValue,
                case .array(let enumValues)? = propertySchemaFields["enum"],
                let actual = scalarString(value: propertyValue)
            else { continue }
            let allowed = enumValues.compactMap { scalarString(value: $0) }
            if !allowed.contains(actual) {
                issues.append("property \"\(propertyName)\" value \"\(actual)\" is not one of \(allowed)")
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
    private static func matchesType(typeName: String, against value: Value) -> Bool {
        guard let entry = jsonTypeTable.first(where: { $0.name == typeName }) else {
            return true
        }
        return entry.matches(value)
    }

    /// The JSON Schema primitive type name for `value`'s case, used to
    /// report a ``matchesType(typeName:against:)`` mismatch.
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
    /// its canonical type name; ``matchesType(typeName:against:)`` looks up the
    /// entry by `name` and evaluates its `matches` predicate against a
    /// schema-declared type name instead.
    ///
    /// `"number"` also matches `.int` (in addition to `"integer"`'s own
    /// entry) so an `.int` value satisfies both, per
    /// ``matchesType(typeName:against:)``; `.int` still resolves to the canonical
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
    private static func scalarString(value: Value) -> String? {
        switch value {
        case .string(let string): return string
        case .int(let int): return String(describing: int)
        case .double(let double): return String(describing: double)
        case .bool(let bool): return String(describing: bool)
        default: return nil
        }
    }
}
