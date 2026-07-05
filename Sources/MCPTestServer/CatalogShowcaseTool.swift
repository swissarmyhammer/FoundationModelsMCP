import MCP

extension ScriptedServer {
    /// The input schema for ``catalogShowcaseTool(named:)``: a required `city`
    /// string plus an optional `units` string constrained to two enum values —
    /// deliberately richer than ``echoTool(named:description:)``'s single
    /// property, so a catalog consumer has more than one property to render.
    private static let catalogShowcaseInputSchema: Value = JSONSchemaBuilder.object(
        properties: [
            "city": JSONSchemaBuilder.string(description: "The city to look up."),
            "units": .object([
                "type": .string("string"),
                "description": .string("The temperature units to report in."),
                "enum": .array([.string("celsius"), .string("fahrenheit")]),
            ]),
        ],
        required: ["city"]
    )

    /// This tool's operational hints — every ``ToolAnnotations`` field
    /// populated with a non-default value, so a catalog consumer (see
    /// `Examples/CatalogBrowser`) has something concrete to print for each
    /// one.
    private static let catalogShowcaseAnnotations = MCP.Tool.Annotations(
        title: "Weather Lookup",
        readOnlyHint: true,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: true
    )

    /// This tool's icon set — a single, sized icon, so a catalog consumer has
    /// a non-empty ``ToolDescriptor/icons`` array to print.
    private static let catalogShowcaseIcons: [MCP.Icon] = [
        MCP.Icon(src: "https://example.com/icons/weather.png", mimeType: "image/png", sizes: ["48x48"])
    ]

    /// Builds a tool exercising every catalog-facing field the M8 surface
    /// (`ToolDescriptor`) exposes — `title`, full ``ToolAnnotations``, icons,
    /// and a multi-property `inputSchema` — unlike
    /// ``echoTool(named:description:)`` and the filesystem tools, which leave
    /// `title`/`annotations`/`icons` at their empty defaults.
    ///
    /// - Parameter name: The tool's name. Defaults to `"weather_lookup"`.
    /// - Returns: The constructed ``ScriptedTool``.
    public static func catalogShowcaseTool(named name: String = "weather_lookup") -> ScriptedTool {
        let definition = MCP.Tool(
            name: name,
            title: "Weather Lookup",
            description: "Looks up the current weather for a city.",
            inputSchema: catalogShowcaseInputSchema,
            annotations: catalogShowcaseAnnotations,
            icons: catalogShowcaseIcons
        )
        let handler: @Sendable (CallTool.Parameters) async throws -> CallTool.Result = { params in
            let city = params.arguments?["city"]?.stringValue ?? "an unknown city"
            let units = params.arguments?["units"]?.stringValue ?? "celsius"
            return CallTool.Result(
                content: [.text(text: "The weather in \(city) is a mild 21 degrees \(units).", annotations: nil, _meta: nil)]
            )
        }
        return ScriptedTool(definition: definition, handler: handler)
    }

    /// Registers ``catalogShowcaseTool(named:)`` on this server — convenience
    /// for `Examples/CatalogBrowser`'s `.catalog` ``ServerMode``.
    ///
    /// - Parameter name: The tool's name. Defaults to `"weather_lookup"`.
    public func addCatalogShowcaseTool(named name: String = "weather_lookup") {
        addTool(Self.catalogShowcaseTool(named: name))
    }
}
