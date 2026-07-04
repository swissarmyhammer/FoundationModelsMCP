import MCP

/// Minimal JSON-Schema-2020-12 object-schema construction, shared by every
/// ``ScriptedServer`` tool factory so each one doesn't hand-roll its own
/// `Value.object([...])` literal for a trivial `inputSchema`.
public enum JSONSchemaBuilder {
    /// Builds an object-typed `inputSchema`/`outputSchema` `Value`.
    ///
    /// - Parameters:
    ///   - properties: Each property name mapped to its own JSON Schema
    ///     fragment (e.g. the result of ``string(description:)``).
    ///   - required: The subset of `properties`' keys that are required.
    ///     Defaults to none required.
    /// - Returns: A `Value.object` describing `{ "type": "object", ... }`.
    public static func object(properties: [String: Value], required: [String] = []) -> Value {
        var fields: [String: Value] = [
            "type": .string("object"),
            "properties": .object(properties),
        ]
        if !required.isEmpty {
            fields["required"] = .array(required.map(Value.string))
        }
        return .object(fields)
    }

    /// Builds a single string-property schema fragment, for use as one value
    /// in ``object(properties:required:)``'s `properties` dictionary.
    ///
    /// - Parameter description: Optional human-readable description of the
    ///   property.
    /// - Returns: A `Value.object` describing `{ "type": "string", ... }`.
    public static func string(description: String? = nil) -> Value {
        var fields: [String: Value] = ["type": .string("string")]
        if let description {
            fields["description"] = .string(description)
        }
        return .object(fields)
    }
}
