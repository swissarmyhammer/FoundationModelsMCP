import MCP

extension ScriptedServer {
    /// The name of the tool ``startDynamicToolsetScenario()`` re-schemas
    /// partway through — present from the start, still present (under the
    /// same name, a different `inputSchema`) at the end.
    public static let dynamicToolsetReschemadToolName = "counter"

    /// The name of the tool ``startDynamicToolsetScenario()`` adds, then later
    /// removes — the tool `Examples/DynamicToolset` watches vanish, to
    /// demonstrate call-time resolution of a tool that is no longer
    /// available.
    public static let dynamicToolsetVanishingToolName = "greeter"

    /// How long ``startDynamicToolsetScenario()`` waits after each stage
    /// before applying the next mutation — short enough that
    /// `Examples/DynamicToolset` finishes in a few seconds, long enough that
    /// each stage's own `tools/list_changed` notification and re-list
    /// round-trip has settled before the next stage fires.
    private static let dynamicToolsetStageDelay: Duration = .milliseconds(1500)

    /// The `inputSchema` ``dynamicToolsetReschemadToolName`` starts with —
    /// no arguments.
    private static let initialCounterSchema = JSONSchemaBuilder.emptySchema

    /// The `inputSchema` ``dynamicToolsetReschemadToolName`` is re-declared
    /// with partway through the scenario: a new required `step` integer
    /// property, structurally different from ``initialCounterSchema`` — the
    /// same-name schema change ``ToolCatalog/diff(from:)`` reports as
    /// ``ToolCatalogDiff/changed``.
    private static let reschemadCounterSchema: Value = JSONSchemaBuilder.object(
        properties: [
            "step": .object([
                "type": .string("integer"),
                "description": .string("How many counts to advance by."),
            ])
        ],
        required: ["step"]
    )

    /// Builds the re-declared ``dynamicToolsetReschemadToolName`` tool
    /// ``startDynamicToolsetScenario()`` swaps in via ``replaceTool(_:)``.
    ///
    /// - Returns: The replacement ``ScriptedTool``, still named
    ///   ``dynamicToolsetReschemadToolName``.
    private static func reschemadCounterTool() -> ScriptedTool {
        let definition = MCP.Tool(
            name: dynamicToolsetReschemadToolName,
            description: "Advances a running count by a caller-supplied step.",
            inputSchema: reschemadCounterSchema
        )
        let handler: @Sendable (CallTool.Parameters) async throws -> CallTool.Result = { params in
            let step = params.arguments?["step"]?.intValue ?? 0
            return CallTool.Result(content: [.text(text: "advanced by \(step)", annotations: nil, _meta: nil)])
        }
        return ScriptedTool(definition: definition, handler: handler)
    }

    /// Registers the initial tool set, then schedules three timed mutations —
    /// the "toy stdio server that adds, removes, and re-schemas a tool on a
    /// timer" `plan.md`'s Examples section describes for `DynamicToolset`
    /// (the live half of M8).
    ///
    /// Starts with ``dynamicToolsetReschemadToolName`` (a no-argument tool)
    /// registered up front, present in the very first catalog snapshot. Three
    /// ``scheduleMutation(after:_:)`` calls then fire in sequence, each
    /// ``dynamicToolsetStageDelay`` after the previous:
    /// 1. **Add**: ``dynamicToolsetVanishingToolName`` joins the catalog.
    /// 2. **Re-schema**: ``dynamicToolsetReschemadToolName`` is re-declared
    ///    with ``reschemadCounterSchema`` in place of ``initialCounterSchema``
    ///    — same name, different `inputSchema`, so its ``ToolDescriptor/fingerprint``
    ///    changes.
    /// 3. **Remove**: ``dynamicToolsetVanishingToolName`` leaves the catalog —
    ///    the vanished tool `Examples/DynamicToolset` then resolves via
    ///    `MCPServer.tool(named:)` and finds `nil`.
    ///
    /// Each mutation emits `notifications/tools/list_changed` itself, so every
    /// stage produces its own ``MCPServer/catalogUpdates`` snapshot with an
    /// incremented `epoch`.
    public func startDynamicToolsetScenario() {
        addScriptedTool(
            name: Self.dynamicToolsetReschemadToolName,
            description: "Advances a running count by one.",
            inputSchema: Self.initialCounterSchema
        ) { _ in
            CallTool.Result(content: [.text(text: "advanced by 1", annotations: nil, _meta: nil)])
        }

        scheduleMutation(after: Self.dynamicToolsetStageDelay) { server in
            await server.addEchoTool(
                named: Self.dynamicToolsetVanishingToolName, description: "Greets the caller by echoing a greeting.")
            try? await server.emitToolListChanged()
        }
        scheduleMutation(after: Self.dynamicToolsetStageDelay * 2.0) { server in
            await server.replaceTool(Self.reschemadCounterTool())
            try? await server.emitToolListChanged()
        }
        scheduleMutation(after: Self.dynamicToolsetStageDelay * 3.0) { server in
            await server.removeTool(named: Self.dynamicToolsetVanishingToolName)
            try? await server.emitToolListChanged()
        }
    }
}
