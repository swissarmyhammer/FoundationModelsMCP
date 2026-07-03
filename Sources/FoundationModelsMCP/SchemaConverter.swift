import FoundationModels
import MCP

/// An inspectable intermediate representation of a JSON Schema (2020-12) node,
/// parsed from an MCP tool's `inputSchema`.
///
/// `DynamicGenerationSchema` / `GenerationSchema` are opaque — FoundationModels
/// exposes no public introspection on a constructed schema — so `SchemaIR` is
/// the assertion surface for tests: property names, primitive types,
/// optionality, nesting, and resolved `$ref`s are all plain, inspectable data.
///
/// Only *structure* is represented here (the rows of plan.md's JSON-Schema →
/// `DynamicGenerationSchema` table): object/properties/required, primitives,
/// arrays, enums, nested objects, and `$ref`/`$defs`. Guides — `minimum`/
/// `maximum`, `pattern`, `minItems`/`maxItems` as runtime `GenerationGuide`s —
/// and structured fallback logging are a follow-on task; any JSON Schema
/// keyword or shape this converter does not recognize degrades to
/// ``unknown(_:)`` rather than throwing.
public indirect enum SchemaIR: Sendable, Equatable {
    /// `type: "object"` with `properties`/`required`.
    case object(name: String, description: String?, properties: [Property])
    /// `type: "string"`.
    case string
    /// `type: "integer"`.
    case integer
    /// `type: "number"`.
    case number
    /// `type: "boolean"`.
    case boolean
    /// `type: "array"` with `items`.
    case array(items: SchemaIR)
    /// `enum: [...]` — the discrete set of values the model may choose from.
    case enumeration(name: String, description: String?, values: [String])
    /// `$ref` to a `$defs` entry, resolved by name against
    /// `SchemaConversion.definitions`.
    case reference(name: String)
    /// A JSON Schema keyword or shape this converter does not map to a
    /// `DynamicGenerationSchema` structure (e.g. `anyOf`/`oneOf` unions,
    /// `patternProperties`, a schema with no recognized `type`). Degrades to
    /// a permissive string schema at emission time.
    case unknown

    /// One property of an ``object(name:description:properties:)`` node.
    public struct Property: Sendable, Equatable {
        public var name: String
        public var description: String?
        public var schema: SchemaIR
        /// `false` when the property's name is present in the enclosing
        /// object's JSON Schema `required` array.
        public var isOptional: Bool

        public init(name: String, description: String?, schema: SchemaIR, isOptional: Bool) {
            self.name = name
            self.description = description
            self.schema = schema
            self.isOptional = isOptional
        }
    }
}

/// The result of parsing an MCP `inputSchema`: the root ``SchemaIR`` plus any
/// named `$defs` schemas reachable from it via `$ref`.
public struct SchemaConversion: Sendable, Equatable {
    /// The name given to the root schema (typically the MCP tool name); also
    /// the `DynamicGenerationSchema` / `GenerationSchema` type name at
    /// emission.
    public var name: String
    public var root: SchemaIR
    /// Parsed `$defs` entries, keyed by definition name, resolved via
    /// ``SchemaIR/reference(name:)``.
    public var definitions: [String: SchemaIR]

    public init(name: String, root: SchemaIR, definitions: [String: SchemaIR]) {
        self.name = name
        self.root = root
        self.definitions = definitions
    }
}

/// Converts an MCP tool's `inputSchema` (`MCP.Value`, JSON Schema 2020-12)
/// into Apple's `GenerationSchema`.
///
/// Conversion happens in two stages, because `DynamicGenerationSchema`/
/// `GenerationSchema` are opaque with no public introspection:
///
/// 1. ``parse(_:name:)`` walks the raw `Value` into `SchemaIR` — the
///    inspectable representation tests assert against.
/// 2. ``emit(_:)`` is a thin translation of the already-parsed `SchemaIR`
///    into `DynamicGenerationSchema` → `GenerationSchema`.
public enum SchemaConverter {
    /// Parses an MCP `inputSchema` into an inspectable `SchemaIR`.
    ///
    /// - Parameters:
    ///   - inputSchema: The tool's raw JSON Schema `inputSchema`, as decoded
    ///     by the MCP swift-sdk (targets the 2020-12 dialect).
    ///   - name: The name given to the root schema — typically the MCP tool
    ///     name — used as the emitted `DynamicGenerationSchema`'s type name.
    /// - Returns: The parsed root schema plus any resolved `$defs`.
    public static func parse(_ inputSchema: Value, name: String) -> SchemaConversion {
        guard case let .object(fields) = inputSchema else {
            return SchemaConversion(name: name, root: .unknown, definitions: [:])
        }
        let definitions = parseDefinitions(fields)
        let root = parseNode(inputSchema, name: name)
        return SchemaConversion(name: name, root: root, definitions: definitions)
    }

    /// Emits a `GenerationSchema` from an already-parsed `SchemaConversion`.
    ///
    /// Thin by design: every structural decision was already made during
    /// ``parse(_:name:)``. This step only walks `SchemaIR` into
    /// `DynamicGenerationSchema` values and hands them to
    /// `GenerationSchema.init(root:dependencies:)`.
    ///
    /// - Throws: `GenerationSchema.SchemaError` if the parsed schemas
    ///   describe an invalid type graph (e.g. a `$ref` with no matching
    ///   `$defs` entry, or a duplicate type name).
    public static func emit(_ conversion: SchemaConversion) throws -> GenerationSchema {
        let dependencies = conversion.definitions.map { _, node in
            dynamicSchema(for: node)
        }
        let root = dynamicSchema(for: conversion.root)
        return try GenerationSchema(root: root, dependencies: dependencies)
    }

    // MARK: - Parsing (Value → SchemaIR)

    /// JSON Schema 2020-12 (MCP's targeted dialect) uses `$defs`, but many
    /// real-world schemas — ported from draft-07-era generators (Pydantic v1,
    /// `zod-to-json-schema`, OpenAPI-derived tooling) — still emit the legacy
    /// `definitions` container. Both are recognized so a `$ref` into either
    /// resolves instead of silently degrading to `.unknown`.
    private static let definitionsContainerKeys = ["$defs", "definitions"]

    private static func parseDefinitions(_ fields: [String: Value]) -> [String: SchemaIR] {
        var result: [String: SchemaIR] = [:]
        for containerKey in definitionsContainerKeys {
            guard case let .object(defs)? = fields[containerKey] else { continue }
            for (defName, defValue) in defs {
                result[defName] = parseNode(defValue, name: defName)
            }
        }
        return result
    }

    private static func parseNode(_ value: Value, name: String) -> SchemaIR {
        guard case let .object(fields) = value else { return .unknown }

        if case let .string(ref)? = fields["$ref"], let defName = definitionName(fromRef: ref) {
            return .reference(name: defName)
        }

        if case let .array(enumValues)? = fields["enum"] {
            return .enumeration(
                name: name,
                description: fields["description"]?.stringValue,
                values: enumValues.compactMap(scalarString)
            )
        }

        switch fields["type"]?.stringValue {
        case "object":
            return parseObject(fields, name: name)
        case "string":
            return .string
        case "integer":
            return .integer
        case "number":
            return .number
        case "boolean":
            return .boolean
        case "array":
            return parseArray(fields, name: name)
        default:
            // No recognized `type`, but shaped like an object (e.g. a root
            // `inputSchema` that omits `"type": "object"`, which the MCP
            // spec still treats as an object schema).
            if fields["properties"] != nil {
                return parseObject(fields, name: name)
            }
            return .unknown
        }
    }

    private static func parseObject(_ fields: [String: Value], name: String) -> SchemaIR {
        let requiredNames: Set<String>
        if case let .array(requiredValues)? = fields["required"] {
            requiredNames = Set(requiredValues.compactMap(\.stringValue))
        } else {
            requiredNames = []
        }

        var properties: [SchemaIR.Property] = []
        if case let .object(propertyFields)? = fields["properties"] {
            for (propertyName, propertySchema) in propertyFields.sorted(by: { $0.key < $1.key }) {
                let description: String?
                if case let .object(propertySchemaFields) = propertySchema {
                    description = propertySchemaFields["description"]?.stringValue
                } else {
                    description = nil
                }
                properties.append(
                    SchemaIR.Property(
                        name: propertyName,
                        description: description,
                        schema: parseNode(propertySchema, name: "\(name)_\(propertyName)"),
                        isOptional: !requiredNames.contains(propertyName)
                    )
                )
            }
        }

        return .object(
            name: name,
            description: fields["description"]?.stringValue,
            properties: properties
        )
    }

    private static func parseArray(_ fields: [String: Value], name: String) -> SchemaIR {
        guard let items = fields["items"] else { return .array(items: .unknown) }
        return .array(items: parseNode(items, name: "\(name)_item"))
    }

    /// JSON Schema `enum` values are not necessarily strings; render any
    /// scalar to its string form so `enum: [1, 2, 3]` still produces
    /// sensible choices. Non-scalar enum values (nested arrays/objects) are
    /// dropped rather than guessed at.
    private static func scalarString(_ value: Value) -> String? {
        switch value {
        case .string(let string): return string
        case .int(let int): return String(int)
        case .double(let double): return String(double)
        case .bool(let bool): return String(bool)
        default: return nil
        }
    }

    /// MCP 2025-11-25 targets JSON Schema 2020-12, whose default `$ref`
    /// anchor for a top-level `$defs` entry is `#/$defs/<name>`; the legacy
    /// `#/definitions/<name>` form (see `definitionsContainerKeys`) is
    /// recognized alongside it.
    private static func definitionName(fromRef ref: String) -> String? {
        for containerKey in definitionsContainerKeys {
            let prefix = "#/\(containerKey)/"
            if ref.hasPrefix(prefix) {
                return String(ref.dropFirst(prefix.count))
            }
        }
        return nil
    }

    // MARK: - Emission (SchemaIR → DynamicGenerationSchema)

    private static func dynamicSchema(for node: SchemaIR) -> DynamicGenerationSchema {
        switch node {
        case let .object(name, description, properties):
            return DynamicGenerationSchema(
                name: name,
                description: description,
                properties: properties.map { property in
                    DynamicGenerationSchema.Property(
                        name: property.name,
                        description: property.description,
                        schema: dynamicSchema(for: property.schema),
                        isOptional: property.isOptional
                    )
                }
            )
        case .string:
            return DynamicGenerationSchema(type: String.self)
        case .integer:
            return DynamicGenerationSchema(type: Int.self)
        case .number:
            return DynamicGenerationSchema(type: Double.self)
        case .boolean:
            return DynamicGenerationSchema(type: Bool.self)
        case let .array(items):
            return DynamicGenerationSchema(arrayOf: dynamicSchema(for: items))
        case let .enumeration(name, description, values):
            return DynamicGenerationSchema(name: name, description: description, anyOf: values)
        case let .reference(name):
            return DynamicGenerationSchema(referenceTo: name)
        case .unknown:
            return DynamicGenerationSchema(type: String.self)
        }
    }
}
