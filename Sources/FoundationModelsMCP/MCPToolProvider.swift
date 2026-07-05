import FoundationModels
import Logging

/// A uniform interface for contributing tools to a `LanguageModelSession`.
///
/// The single question both ``MCPTool`` (one tool) and ``MCPServer`` (many
/// tools, discovered once connected) answer the same way. Conforming types
/// are combined via ``resolveSessionTools(from:logger:)``,
/// the function backing the `LanguageModelSession.init(model:mcp:instructions:)`
/// convenience initializer — see `plan.md`'s "Uniform entry point" section for
/// the full rationale.
public protocol MCPToolProvider {
    /// Returns the tools this provider contributes to a `LanguageModelSession`.
    ///
    /// Declared `async throws` because answering may require awaiting
    /// discovery — an ``MCPServer`` conformance blocks here until its
    /// connection is ``MCPServerState/ready``.
    ///
    /// - Returns: The tools this provider contributes, type-erased to `any
    ///   FoundationModels.Tool`.
    /// - Throws: Whatever the provider needs to throw while producing its
    ///   tools — e.g. ``MCPServerError/notReady(_:)`` if an ``MCPServer``
    ///   never reaches ``MCPServerState/ready``.
    func sessionTools() async throws -> [any FoundationModels.Tool]
}

extension MCPTool: MCPToolProvider {
    /// Returns this tool as the sole element of its session tool list.
    ///
    /// - Returns: `[self]`.
    public func sessionTools() async throws -> [any FoundationModels.Tool] {
        [self]
    }
}

extension MCPServer: MCPToolProvider {
    /// Awaits this server's readiness, then returns every tool it discovered.
    ///
    /// - Returns: The same tools ``foundationModelsTools()`` would return,
    ///   once this server reaches ``MCPServerState/ready``.
    /// - Throws: ``MCPServerError/notReady(_:)`` if this server's connection
    ///   reaches ``MCPServerState/faulted(_:)`` before becoming ready.
    public func sessionTools() async throws -> [any FoundationModels.Tool] {
        try await waitUntilReady()
        return try foundationModelsTools()
    }
}

extension MCPServer {
    /// The interval ``waitUntilReady()`` sleeps between polls of ``state``.
    ///
    /// Polling is the same pattern `MCPTestServer`'s
    /// `ScriptedServer.waitForRecordedNotifications(count:timeout:)` already
    /// uses elsewhere in this package for observing actor-isolated state with
    /// no synchronous completion signal to await instead.
    fileprivate static let readinessPollInterval = Duration.milliseconds(5)

    /// Blocks until ``state`` leaves ``MCPServerState/connecting``, by
    /// polling every ``readinessPollInterval``.
    ///
    /// - Throws: ``MCPServerError/notReady(_:)`` carrying the current
    ///   ``MCPServerState/faulted(_:)`` state, if this server's connection
    ///   fails before ever becoming ready. A server that never has
    ///   `connect(transport:)` called on it at all stays ``MCPServerState/connecting``
    ///   forever, so this call blocks forever too — the caller is expected to
    ///   drive (or have already scheduled) that connect.
    fileprivate func waitUntilReady() async throws {
        while true {
            switch state {
            case .ready:
                return
            case .faulted:
                throw MCPServerError.notReady(state)
            case .connecting:
                try await Task.sleep(for: Self.readinessPollInterval)
            }
        }
    }
}

/// Flattens `providers` into the tool list a `LanguageModelSession` should be
/// constructed with, disambiguating cross-provider tool-name collisions
/// deterministically along the way.
///
/// Each provider's ``MCPToolProvider/sessionTools()`` is awaited in array
/// order — for an ``MCPServer`` provider this blocks until its connection
/// reaches ``MCPServerState/ready`` (or throws once it reaches
/// ``MCPServerState/faulted(_:)``), so a still-connecting server delays this
/// function rather than silently omitting its tools. Once every provider has
/// answered, any tool `name` shared by two or more providers is disambiguated
/// by renaming **every** tool sharing that name to `"<providerLabel>_<name>"`
/// — an ``MCPServer``'s label is its ``ServerIdentity/name``; a provider with
/// no server identity to draw from (e.g. a standalone ``MCPTool``) is labeled
/// by its position in `providers`, as `"provider<index>"`. Because a given
/// `providers` input always yields the same provider labels and the same
/// tool names in the same order, the disambiguated names are identical on
/// every run. Every disambiguation is reported through `logger`.
///
/// - Parameters:
///   - providers: The providers to combine, in the order their tools should
///     be preferred/ordered in the result.
///   - logger: The structured logger every disambiguation is reported to.
///     Defaults to a logger labeled `"com.foundationmodelsmcp.mcptoolprovider"`.
/// - Returns: One `any FoundationModels.Tool` per tool across every
///   provider, with any cross-provider name collision disambiguated.
/// - Throws: Whatever an individual provider's ``MCPToolProvider/sessionTools()``
///   throws — e.g. ``MCPServerError/notReady(_:)`` if an ``MCPServer``
///   reaches ``MCPServerState/faulted(_:)`` before becoming ready.
public func resolveSessionTools(
    from providers: [any MCPToolProvider],
    logger: Logger = Logger(label: "com.foundationmodelsmcp.mcptoolprovider")
) async throws -> [any FoundationModels.Tool] {
    var groups: [ProviderToolGroup] = []
    for (index, provider) in providers.enumerated() {
        let tools = try await provider.sessionTools()
        let label = await providerLabel(for: provider, atIndex: index)
        groups.append(ProviderToolGroup(label: label, tools: tools))
    }
    return disambiguated(groups: groups, logger: logger)
}

/// One provider's contributed tools, tagged with the label
/// ``resolveSessionTools(from:logger:)`` uses to disambiguate any of them
/// that collide with a tool from a different provider.
private struct ProviderToolGroup {
    /// This provider's disambiguation label — see
    /// ``providerLabel(for:atIndex:)``.
    let label: String

    /// This provider's contributed tools, exactly as
    /// ``MCPToolProvider/sessionTools()`` returned them.
    let tools: [any FoundationModels.Tool]
}

/// Derives the disambiguation label ``resolveSessionTools(from:logger:)``
/// prefixes a colliding tool's name with.
///
/// - Parameters:
///   - provider: The provider to derive a label for.
///   - index: `provider`'s position within the `providers` array passed to
///     ``resolveSessionTools(from:logger:)``, used as a deterministic
///     fallback label when `provider` has no server identity to draw one
///     from.
/// - Returns: The connected ``MCPServer``'s ``ServerIdentity/name`` if
///   `provider` is an ``MCPServer`` with an established identity; otherwise
///   `"provider<index>"`.
private func providerLabel(for provider: any MCPToolProvider, atIndex index: Int) async -> String {
    if let server = provider as? MCPServer, let identity = await server.identity {
        return identity.name
    }
    return "provider\(index)"
}

/// Renames every tool whose name collides across two or more of `groups`,
/// per ``resolveSessionTools(from:logger:)``'s naming scheme, and logs each
/// disambiguation to `logger`.
///
/// - Parameters:
///   - groups: Every provider's contributed tools, each tagged with its
///     disambiguation label.
///   - logger: The structured logger every disambiguation is reported to.
/// - Returns: One tool per tool across every group, in group order, with any
///   cross-group name collision disambiguated.
private func disambiguated(groups: [ProviderToolGroup], logger: Logger) -> [any FoundationModels.Tool] {
    var nameCounts: [String: Int] = [:]
    for tool in groups.flatMap(\.tools) {
        nameCounts[tool.name, default: 0] += 1
    }

    var resolved: [any FoundationModels.Tool] = []
    for group in groups {
        for tool in group.tools {
            guard nameCounts[tool.name, default: 0] > 1 else {
                resolved.append(tool)
                continue
            }
            resolved.append(disambiguatedTool(tool, providerLabel: group.label, logger: logger))
        }
    }
    return resolved
}

/// Renames one colliding `tool` to `"<providerLabel>_<tool.name>"` and logs
/// the disambiguation, or — for a tool this package cannot rename — logs a
/// warning and passes it through unchanged.
///
/// Every provider this package ships (``MCPTool`` and ``MCPServer``, which
/// itself only ever vends ``MCPTool`` values) can always be renamed here, so
/// the unrenameable path is unreached in practice; it exists so a future
/// ``MCPToolProvider`` conformance vending some other `Tool` type degrades to
/// a passthrough-with-warning instead of a crash or a silently dropped tool.
///
/// - Parameters:
///   - tool: The colliding tool to disambiguate.
///   - providerLabel: The owning provider's disambiguation label.
///   - logger: The structured logger the disambiguation (or the
///     cannot-rename warning) is reported to.
/// - Returns: The disambiguated tool, or `tool` unchanged if it isn't an
///   ``MCPTool``.
private func disambiguatedTool(
    _ tool: any FoundationModels.Tool,
    providerLabel: String,
    logger: Logger
) -> any FoundationModels.Tool {
    let disambiguatedName = "\(providerLabel)_\(tool.name)"
    guard let mcpTool = tool as? MCPTool else {
        logger.warning(
            "MCPToolProvider cannot rename a non-MCPTool with a colliding name; passing it through unchanged",
            metadata: ["name": "\(tool.name)", "provider": "\(providerLabel)"])
        return tool
    }
    logger.info(
        "MCPToolProvider disambiguating a cross-provider tool-name collision",
        metadata: [
            "originalName": "\(tool.name)",
            "provider": "\(providerLabel)",
            "disambiguatedName": "\(disambiguatedName)",
        ])
    return mcpTool.renamed(to: disambiguatedName)
}

/// Adds the `LanguageModelSession(mcp:)` convenience initializer described in
/// `plan.md`'s "Uniform entry point" section — the one call site that adds
/// one or more ``MCPToolProvider``s (servers and/or loose tools) to a
/// session.
extension LanguageModelSession {
    /// Creates a session whose tools are resolved from `providers` via
    /// ``resolveSessionTools(from:logger:)`` — a thin convenience over
    /// `init(model:tools:instructions:)` for the common "one or more MCP
    /// servers and/or tools" case.
    ///
    /// This initializer performs no logic of its own beyond resolving
    /// `providers` and forwarding the result: every collision-disambiguation
    /// and readiness-blocking behavior documented on
    /// ``resolveSessionTools(from:logger:)`` applies here exactly as it does
    /// when that function is called directly. Tests therefore assert on
    /// ``resolveSessionTools(from:logger:)``'s return value rather than on
    /// this initializer's constructed session, which `LanguageModelSession`
    /// exposes no way to introspect the tool list of.
    ///
    /// - Parameters:
    ///   - model: The language model to use. Defaults to `.default`.
    ///   - providers: The providers to combine into the session's tools, in
    ///     the order their tools should be preferred/ordered — variadic, so
    ///     ``MCPServer``s and standalone ``MCPTool``s compose freely at the
    ///     call site, e.g. `LanguageModelSession(mcp: serverA, serverB,
    ///     someTool)`.
    ///   - instructions: The session's instructions, or `nil` for none.
    /// - Throws: Whatever ``resolveSessionTools(from:logger:)`` throws.
    public convenience init(
        model: SystemLanguageModel = .default,
        mcp providers: any MCPToolProvider...,
        instructions: String? = nil
    ) async throws {
        let tools = try await resolveSessionTools(from: providers)
        self.init(model: model, tools: tools, instructions: instructions)
    }
}
