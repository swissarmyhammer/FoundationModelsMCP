import CryptoKit
import Foundation
import FoundationModels
import MCP

/// A tool's display-facing and operational hints, verbatim from the
/// swift-sdk's `MCP.Tool.Annotations` — see that type's own documentation
/// for the exact hint semantics (`readOnlyHint`, `destructiveHint`,
/// `idempotentHint`, `openWorldHint`, and a display `title`).
///
/// Reused rather than reinvented: the wire shape the swift-sdk already
/// decodes from a server's `tools/list` response is exactly the shape
/// `plan.md`'s catalog spec calls for, so introducing a parallel type here
/// would only duplicate it.
public typealias ToolAnnotations = MCP.Tool.Annotations

/// A single tool's catalog-facing metadata: name, display title, description,
/// the server's raw `inputSchema` verbatim, the schema converted for
/// constrained generation, operational ``ToolAnnotations``, icons, and a
/// content-derived ``fingerprint`` other snapshots can diff against.
///
/// A plain `Sendable` value type — see ``ToolCatalog``'s own documentation
/// for why the catalog surface is snapshot values rather than a live
/// reference type.
public struct ToolDescriptor: Sendable {
    /// The tool's name, exactly as declared by the server.
    public let name: String

    /// The tool's human-readable display title, or `nil` if the server
    /// declared none.
    public let title: String?

    /// The tool's description, or an empty string if the server declared
    /// none — mirrors `MCPTool/description`'s own non-optional/empty-string
    /// convention.
    public let description: String

    /// The tool's raw JSON Schema `inputSchema`, exposed **verbatim** — never
    /// the converted ``parameters`` — for callers that need full schema
    /// fidelity (see `plan.md` → "Expose the raw schema").
    public let inputSchema: Value

    /// The tool's argument schema, converted from ``inputSchema`` via
    /// `SchemaConverter` (or reused from an already-converted `MCPTool`, see
    /// ``init(mcpTool:)``) — the schema a `LanguageModelSession` constrains
    /// generation against.
    public let parameters: GenerationSchema

    /// The tool's operational hints, verbatim from the server.
    public let annotations: ToolAnnotations

    /// The tool's icons, or an empty array if the server declared none.
    public let icons: [MCP.Icon]

    /// A stable content hash of ``name``, ``inputSchema``, and
    /// ``annotations`` — equal for two descriptors with identical content,
    /// different if any of the three changes (even with the same ``name``).
    ///
    /// A hex-encoded SHA-256 digest of a key-sorted JSON encoding of the
    /// three, deliberately not Swift's randomly-seeded `Hasher` — so two
    /// independently-constructed catalog snapshots (in the same process, a
    /// later run, or a persisted log) can be compared for tool-level change
    /// using only their fingerprints, without holding onto the prior
    /// snapshot's actual ``ToolDescriptor`` values. Advisory for consumer
    /// indexing only, per `plan.md`'s Dynamic discovery decision: never a
    /// gate on whether a call is allowed to proceed — a schema-changed
    /// tool's call still goes through, and the server validates it.
    public let fingerprint: String

    /// Creates a descriptor by converting `tool.inputSchema` via
    /// `SchemaConverter` from scratch.
    ///
    /// - Parameter tool: The source MCP tool definition to adapt.
    /// - Throws: Whatever `SchemaConverter.emit(_:)` throws if
    ///   `tool.inputSchema` parses into an invalid `DynamicGenerationSchema`
    ///   type graph (e.g. a `$ref` with no matching `$defs` entry, or a
    ///   duplicate type name).
    public init(tool: MCP.Tool) throws {
        let conversion = SchemaConverter.parse(tool.inputSchema, name: tool.name)
        try self.init(
            name: tool.name,
            title: tool.title,
            description: tool.description ?? "",
            inputSchema: tool.inputSchema,
            parameters: SchemaConverter.emit(conversion),
            annotations: tool.annotations,
            icons: tool.icons ?? []
        )
    }

    /// Creates a descriptor from an already-converted ``MCPTool``, reusing
    /// its precomputed `parameters` rather than re-running `SchemaConverter`
    /// against the same raw `inputSchema` a second time — the path
    /// `MCPServer/catalog` takes for every already-discovered tool.
    ///
    /// - Parameter mcpTool: The already-converted tool adapter to snapshot.
    public init(mcpTool: MCPTool) {
        self.init(
            name: mcpTool.name,
            title: mcpTool.title,
            description: mcpTool.description,
            inputSchema: mcpTool.inputSchema,
            parameters: mcpTool.parameters,
            annotations: mcpTool.tool.annotations,
            icons: mcpTool.tool.icons ?? []
        )
    }

    /// The shared designated initializer behind both ``init(tool:)`` and
    /// ``init(mcpTool:)`` — computes ``fingerprint`` from `name`,
    /// `inputSchema`, and `annotations` once, so the two public initializers
    /// only differ in how they obtain `parameters`.
    private init(
        name: String,
        title: String?,
        description: String,
        inputSchema: Value,
        parameters: GenerationSchema,
        annotations: ToolAnnotations,
        icons: [MCP.Icon]
    ) {
        self.name = name
        self.title = title
        self.description = description
        self.inputSchema = inputSchema
        self.parameters = parameters
        self.annotations = annotations
        self.icons = icons
        self.fingerprint = Self.computeFingerprint(
            name: name, inputSchema: inputSchema, annotations: annotations)
    }

    /// The `Encodable` triple ``computeFingerprint(name:inputSchema:annotations:)``
    /// hashes — its own type only exists to give `JSONEncoder` one value to
    /// encode in a single call, so the encoder's `.sortedKeys` formatting
    /// applies recursively to every nested object inside `inputSchema` too,
    /// not just this payload's own top-level keys.
    private struct FingerprintPayload: Encodable {
        let name: String
        let inputSchema: Value
        let annotations: ToolAnnotations
    }

    /// Computes ``fingerprint``: a hex-encoded SHA-256 digest of `name`,
    /// `inputSchema`, and `annotations`, encoded together as JSON with
    /// alphabetically-sorted object keys so the result never depends on
    /// `Value.object`'s dictionary iteration order.
    ///
    /// - Parameters:
    ///   - name: The tool's name.
    ///   - inputSchema: The tool's raw `inputSchema`.
    ///   - annotations: The tool's operational hints.
    /// - Returns: A stable, hex-encoded digest — identical across processes
    ///   and runs for identical input, different if any parameter changes.
    private static func computeFingerprint(
        name: String, inputSchema: Value, annotations: ToolAnnotations
    ) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // A non-conforming float can only occur here via a hand-built Value
        // literal (e.g. in a test) — JSON itself can't represent NaN or
        // infinity, so any inputSchema sourced from a real tools/list decode
        // never contains one. Configuring a string fallback (rather than the
        // default `.throw`) keeps this computation total either way.
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        let payload = FingerprintPayload(name: name, inputSchema: inputSchema, annotations: annotations)
        let data = try! encoder.encode(payload)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// A versioned, point-in-time snapshot of everything one MCP server exposes:
/// its stable ``ServerIdentity``, a per-server ``epoch`` that increases every
/// time a new snapshot replaces this one, the server's current
/// `MCPServerState`, and every tool it currently declares.
///
/// Per `plan.md`'s Dynamic discovery decision, the catalog is a stream of
/// versioned snapshots, never transmitted deltas: each snapshot is
/// self-contained and idempotent (a consumer can start fresh from any one
/// snapshot with no prior state), and ``diff(from:)`` derives an
/// add/remove/change delta between two snapshots locally, on demand.
public struct ToolCatalog: Sendable {
    /// This server's stable identity — see ``ServerIdentity``.
    public let identity: ServerIdentity

    /// A per-server generation number, incremented every time a new snapshot
    /// replaces this one (a fresh discovery, a coalesced `list_changed`
    /// re-list, a reconnect, or a readiness-state change) — never reset for
    /// the life of the owning `MCPServer`.
    public let epoch: Int

    /// The server's readiness at the moment this snapshot was taken.
    public let state: MCPServerState

    /// Every tool the server currently declares, in `tools/list` page order.
    public let tools: [ToolDescriptor]

    /// Creates a catalog snapshot.
    ///
    /// - Parameters:
    ///   - identity: The server's stable identity.
    ///   - epoch: The snapshot's generation number.
    ///   - state: The server's readiness at the moment of this snapshot.
    ///   - tools: Every tool the server currently declares.
    public init(identity: ServerIdentity, epoch: Int, state: MCPServerState, tools: [ToolDescriptor]) {
        self.identity = identity
        self.epoch = epoch
        self.state = state
        self.tools = tools
    }

    /// Classifies every tool that changed between `previous` and this
    /// snapshot: tools present here but not in `previous`
    /// (``ToolCatalogDiff/added``), tools present in `previous` but not here
    /// (``ToolCatalogDiff/removed``), and tools present in both under the
    /// same ``ToolDescriptor/name`` whose ``ToolDescriptor/fingerprint``
    /// differs (``ToolCatalogDiff/changed``) — e.g. the server re-declared
    /// the same tool with a different `inputSchema` or annotations.
    ///
    /// - Parameter previous: The earlier snapshot to diff against.
    /// - Returns: The classified delta.
    public func diff(from previous: ToolCatalog) -> ToolCatalogDiff {
        let previousByName = Dictionary(
            previous.tools.map { ($0.name, $0) }, uniquingKeysWith: { _, latest in latest })
        let currentNames = Set(tools.map(\.name))

        var added: [ToolDescriptor] = []
        var changed: [ToolCatalogDiff.ChangedTool] = []
        for tool in tools {
            guard let prior = previousByName[tool.name] else {
                added.append(tool)
                continue
            }
            if prior.fingerprint != tool.fingerprint {
                changed.append(ToolCatalogDiff.ChangedTool(before: prior, after: tool))
            }
        }
        let removed = previous.tools.filter { !currentNames.contains($0.name) }

        return ToolCatalogDiff(added: added, removed: removed, changed: changed)
    }
}

/// The add/remove/change delta ``ToolCatalog/diff(from:)`` derives between
/// two ``ToolCatalog`` snapshots of the same server.
public struct ToolCatalogDiff: Sendable {
    /// One same-named tool whose ``ToolDescriptor/fingerprint`` changed
    /// between two snapshots, carrying both the earlier and later descriptor
    /// so a consumer can report exactly what changed.
    public struct ChangedTool: Sendable {
        /// The tool's descriptor in the earlier snapshot.
        public let before: ToolDescriptor

        /// The tool's descriptor in the later snapshot.
        public let after: ToolDescriptor
    }

    /// Every tool present in the newer snapshot under a `name` absent from
    /// the older one.
    public let added: [ToolDescriptor]

    /// Every tool present in the older snapshot under a `name` absent from
    /// the newer one.
    public let removed: [ToolDescriptor]

    /// Every same-named tool present in both snapshots whose
    /// ``ToolDescriptor/fingerprint`` differs between them.
    public let changed: [ChangedTool]
}
