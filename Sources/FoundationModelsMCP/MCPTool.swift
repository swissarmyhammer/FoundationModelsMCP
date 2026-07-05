import FoundationModels
import MCP

/// The generic `FoundationModels.Tool` adapter that turns any MCP tool into a
/// tool a `LanguageModelSession` can call.
///
/// One `MCPTool` instance backs exactly one MCP `Tool` served by one
/// connection (see `plan.md` → "Why it's feasible"): its `Arguments` is the
/// opaque `GeneratedContent` produced by constrained generation against the
/// converted ``parameters`` schema, and ``call(arguments:)`` is a pure
/// pass-through — encode the generated arguments, forward them through the
/// ``MCPToolCalling`` seam, and render whatever the server returns. By the
/// time ``call(arguments:)`` runs, the arguments were already constrained by
/// the calling session's guided generation against ``parameters``; the MCP
/// server is the authoritative validator of the call, and its `isError`
/// bubbles straight back to the model via ``ToolContentRenderer``. `MCPTool`
/// never re-validates, repairs, or retries a call itself — see `plan.md` →
/// "Models & enforcement: we declare, the session enforces".
public struct MCPTool: FoundationModels.Tool {
    /// `GeneratedContent` already conforms to `ConvertibleFromGeneratedContent`
    /// (the identity conversion), so no per-tool `Generable` type is needed —
    /// see `plan.md` → "Why it's feasible".
    public typealias Arguments = GeneratedContent

    /// The source MCP tool definition — name, description, title, schemas,
    /// annotations, icons, and `_meta` — kept verbatim as the single source
    /// of truth every metadata property below reads from.
    public let tool: MCP.Tool

    /// The seam used to forward ``call(arguments:)`` to the connected MCP
    /// server.
    ///
    /// Typed as `any MCPToolCalling` rather than `MCP.Client` directly, since
    /// `Client` is a concrete `actor` from the swift-sdk and cannot be
    /// substituted in tests — see ``MCPToolCalling``'s own documentation for
    /// the full rationale.
    private let client: any MCPToolCalling

    /// A disambiguated name assigned by ``resolveSessionTools(from:logger:)`` to
    /// resolve a cross-provider tool-name collision, taking precedence over
    /// the source `MCP.Tool`'s own name when present.
    ///
    /// `nil` for every tool built through ``init(tool:client:)`` directly;
    /// only `renamed(to:)` ever sets it, so a tool's name only ever
    /// diverges from `tool.name` as an explicit, traceable disambiguation
    /// step.
    private var nameOverride: String?

    /// The tool's name: `nameOverride` if a cross-provider collision was
    /// disambiguated (see `renamed(to:)`), otherwise sourced verbatim from
    /// the source `MCP.Tool`.
    public var name: String { nameOverride ?? tool.name }

    /// The tool's description, sourced verbatim from the source `MCP.Tool`,
    /// or an empty string if the server declared none.
    ///
    /// `Tool.description` is non-optional, but MCP's `Tool.description` is
    /// (`String?`) — an empty string is the closest non-optional equivalent
    /// of "no description given."
    public var description: String { tool.description ?? "" }

    /// The tool's human-readable display title, sourced verbatim from the
    /// source `MCP.Tool`, or `nil` if the server declared none.
    ///
    /// Not part of the `FoundationModels.Tool` protocol surface — carried
    /// alongside it for callers (e.g. a future tool catalog) that want
    /// display-facing metadata beyond `name`/`description`.
    public var title: String? { tool.title }

    /// The tool's raw JSON Schema `inputSchema`, exposed **verbatim** — never
    /// the converted ``parameters``  — as the integration point for callers
    /// that own generation themselves and need full schema fidelity (see
    /// `plan.md` → "Expose the raw schema").
    public var inputSchema: Value { tool.inputSchema }

    /// The tool's argument schema, precomputed once at construction from
    /// `tool.inputSchema` via ``SchemaConverter``.
    ///
    /// This is the schema a `LanguageModelSession` constrains generation
    /// against when the model calls this tool — the formal guarantee that
    /// whatever arguments reach ``call(arguments:)`` are already well-formed
    /// (see `plan.md` → "Why this is better than naive tool calling").
    public let parameters: GenerationSchema

    /// Always `true`: the converted ``parameters`` schema is injected into
    /// the model's instructions so it knows this tool's argument shape.
    public let includesSchemaInInstructions = true

    /// Creates an adapter for one MCP tool, converting its `inputSchema` into
    /// a `GenerationSchema` up front.
    ///
    /// - Parameters:
    ///   - tool: The source MCP tool definition to adapt.
    ///   - client: The seam used to forward ``call(arguments:)`` to the
    ///     connected MCP server.
    /// - Throws: Whatever `SchemaConverter.emit(_:)` throws if `tool.inputSchema`
    ///   parses into an invalid `DynamicGenerationSchema` type graph (e.g. a
    ///   `$ref` with no matching `$defs` entry, or a duplicate type name).
    public init(tool: MCP.Tool, client: any MCPToolCalling) throws {
        self.tool = tool
        self.client = client
        self.nameOverride = nil
        let conversion = SchemaConverter.parse(tool.inputSchema, name: tool.name)
        self.parameters = try SchemaConverter.emit(conversion)
    }

    /// Returns a copy of this tool with ``name`` overridden to `newName`,
    /// leaving every other property — description, parameters, and calling
    /// behavior (`call(arguments:)` still forwards to the source `MCP.Tool`'s
    /// own `tool.name` against `client`) — unchanged.
    ///
    /// Used exclusively by ``resolveSessionTools(from:logger:)`` to disambiguate a
    /// cross-provider tool-name collision; the model-facing ``name`` changes,
    /// but the tool it calls on the server does not.
    ///
    /// - Parameter newName: The disambiguated name to present in place of the
    ///   source `MCP.Tool`'s own name.
    /// - Returns: A copy of this tool whose ``name`` is `newName`.
    func renamed(to newName: String) -> MCPTool {
        var copy = self
        copy.nameOverride = newName
        return copy
    }

    /// Calls the underlying MCP tool and renders its result for the model.
    ///
    /// Pure pass-through, by design (see `plan.md` → "Models & enforcement"):
    /// encodes `arguments` into MCP's argument map, forwards them verbatim to
    /// ``MCPToolCalling/callTool(name:arguments:)``, and renders whatever
    /// comes back — success, `isError`, or `structuredContent` — via
    /// ``ToolContentRenderer``. No validation or repair happens here; a
    /// thrown transport error propagates unchanged, and an `isError` result
    /// is rendered (not thrown), since the server's failure is content the
    /// model should see and can react to.
    ///
    /// - Parameter arguments: The generated arguments, already constrained
    ///   against ``parameters`` by the calling session.
    /// - Returns: The rendered `tools/call` result.
    /// - Throws: ``GeneratedContentCodecError/argumentsRequireObject`` if
    ///   `arguments.kind` is not `.structure` (arguments constrained against
    ///   an object-shaped ``parameters`` schema always are), or whatever the
    ///   ``MCPToolCalling`` seam throws for a transport/connection failure.
    public func call(arguments: GeneratedContent) async throws -> String {
        let mcpArguments = try GeneratedContentCodec.arguments(from: arguments)
        let result = try await client.callTool(name: tool.name, arguments: mcpArguments)
        return ToolContentRenderer.render(result: result, outputSchema: tool.outputSchema)
    }
}
