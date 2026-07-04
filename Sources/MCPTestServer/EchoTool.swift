import MCP

extension ScriptedServer {
    /// The input schema for ``echoTool(named:description:)``: one required
    /// string property, `text`.
    private static let echoInputSchema: Value = JSONSchemaBuilder.object(
        properties: ["text": JSONSchemaBuilder.string(description: "The text to echo back.")],
        required: ["text"]
    )

    /// Builds a tool that echoes its `text` argument back verbatim as its
    /// only content — scenario 1, "Echo tool."
    ///
    /// A static factory (rather than only an instance method) so tests can
    /// also reuse it to generate distinct fixture tools — e.g. the
    /// pagination self-test names several of these to populate multiple
    /// `tools/list` pages.
    ///
    /// - Parameters:
    ///   - name: The tool's name. Defaults to `"echo"`.
    ///   - description: The tool's description. Defaults to a fixed string.
    /// - Returns: The constructed ``ScriptedTool``.
    public static func echoTool(
        named name: String = "echo",
        description: String = "Echoes the provided text back verbatim."
    ) -> ScriptedTool {
        let definition = MCP.Tool(
            name: name,
            description: description,
            inputSchema: echoInputSchema
        )
        let handler: @Sendable (CallTool.Parameters) async throws -> CallTool.Result = { params in
            let text = params.arguments?["text"]?.stringValue ?? ""
            return CallTool.Result(content: [.text(text: text, annotations: nil, _meta: nil)])
        }
        return ScriptedTool(definition: definition, handler: handler)
    }

    /// Registers ``echoTool(named:description:)`` on this server —
    /// convenience for scenario 1 when a test just wants a default echo tool
    /// present.
    ///
    /// - Parameters:
    ///   - name: The tool's name. Defaults to `"echo"`.
    ///   - description: The tool's description. Defaults to a fixed string.
    public func addEchoTool(
        named name: String = "echo",
        description: String = "Echoes the provided text back verbatim."
    ) {
        addTool(Self.echoTool(named: name, description: description))
    }
}
