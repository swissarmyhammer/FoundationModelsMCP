import Foundation
import Testing

@testable import FoundationModelsMCP
import FoundationModels
import MCP

/// Coverage for ``MCPTool``, the generic `FoundationModels.Tool` adapter over
/// the ``MCPToolCalling`` client seam.
///
/// Exercised against ``MockClient`` rather than a live `MCP.Client`: every
/// test proves one of the task's three acceptance criteria — the exact tool
/// name and encoded arguments reach the seam, success/`isError`/thrown paths
/// each render to model-consumable text, and metadata (`name`/`description`/
/// `title`/raw `inputSchema`) is sourced verbatim from the source `MCP.Tool`.
@Suite("MCPTool")
struct MCPToolTests {

    /// A minimal object-shaped `inputSchema` — one required string property —
    /// used by tests that don't care about schema shape beyond "some object".
    private static let simpleInputSchema: Value = .object([
        "type": .string("object"),
        "properties": .object([
            "message": .object(["type": .string("string")])
        ]),
        "required": .array([.string("message")]),
    ])

    /// Builds an ``MCPTool`` wired to a fresh, unscripted ``MockClient``.
    ///
    /// - Parameters:
    ///   - name: The source `MCP.Tool`'s name.
    ///   - title: The source `MCP.Tool`'s `title`.
    ///   - description: The source `MCP.Tool`'s `description`.
    ///   - inputSchema: The source `MCP.Tool`'s `inputSchema`.
    /// - Returns: The constructed ``MCPTool`` and the ``MockClient`` backing it.
    private func makeTool(
        name: String = "echo",
        title: String? = nil,
        description: String? = "Echoes the given message",
        inputSchema: Value = simpleInputSchema
    ) throws -> (tool: MCPTool, client: MockClient) {
        let client = MockClient()
        let sourceTool = MCP.Tool(
            name: name, title: title, description: description, inputSchema: inputSchema)
        let tool = try MCPTool(tool: sourceTool, client: client)
        return (tool, client)
    }

    // MARK: - Forwarding: exact name + encoded arguments reach the seam

    @Test("call(arguments:) forwards the exact tool name and encoded arguments to the seam")
    func forwardsNameAndArgumentsExactly() async throws {
        let (tool, client) = try makeTool(name: "echo")
        client.script(CallTool.Result(content: [.text(text: "ok", annotations: nil, _meta: nil)]))

        let arguments = GeneratedContent(properties: ["message": "hello world"])
        _ = try await tool.call(arguments: arguments)

        #expect(client.invocations.count == 1)
        #expect(client.invocations[0].name == "echo")
        #expect(client.invocations[0].arguments == ["message": .string("hello world")])
    }

    @Test("call(arguments:) forwards nested object/array arguments byte-for-byte")
    func forwardsNestedArgumentsExactly() async throws {
        let (tool, client) = try makeTool(inputSchema: .object(["type": .string("object")]))
        client.script(CallTool.Result(content: []))

        let inner = GeneratedContent(properties: ["city": "Springfield"])
        let arguments = GeneratedContent(properties: [
            "address": inner,
            "tags": ["a", "b"],
        ] as KeyValuePairs<String, any ConvertibleToGeneratedContent>)
        _ = try await tool.call(arguments: arguments)

        #expect(
            client.invocations[0].arguments
                == [
                    "address": .object(["city": .string("Springfield")]),
                    "tags": .array([.string("a"), .string("b")]),
                ])
    }

    // MARK: - Rendering: success, isError, structuredContent

    @Test("call(arguments:) renders a successful result for the model")
    func rendersSuccessResult() async throws {
        let (tool, client) = try makeTool()
        client.script(CallTool.Result(content: [.text(text: "hello world", annotations: nil, _meta: nil)]))

        let output = try await tool.call(arguments: GeneratedContent(properties: ["message": "hi"]))
        #expect(output == "hello world")
    }

    @Test("call(arguments:) renders an isError result as model-consumable text, never throwing")
    func rendersIsErrorResultWithoutThrowing() async throws {
        let (tool, client) = try makeTool()
        client.script(
            CallTool.Result(content: [.text(text: "boom", annotations: nil, _meta: nil)], isError: true))

        let output = try await tool.call(arguments: GeneratedContent(properties: ["message": "hi"]))
        #expect(output.contains("Error"))
        #expect(output.contains("boom"))
    }

    @Test("call(arguments:) renders structuredContent alongside content")
    func rendersStructuredContentAlongsideContent() async throws {
        let (tool, client) = try makeTool()
        let structured: Value = .object(["answer": .int(42)])
        client.script(
            CallTool.Result(
                content: [.text(text: "done", annotations: nil, _meta: nil)],
                structuredContent: structured as Value?))

        let output = try await tool.call(arguments: GeneratedContent(properties: ["message": "hi"]))
        #expect(output.contains("done"))
        #expect(output.contains("42"))
    }

    // MARK: - Thrown transport error propagates

    @Test("call(arguments:) propagates a thrown transport error instead of swallowing it")
    func propagatesThrownTransportError() async throws {
        struct TransportError: Error, Equatable {}
        let (tool, client) = try makeTool()
        client.script(throwing: TransportError())

        await #expect(throws: TransportError.self) {
            _ = try await tool.call(arguments: GeneratedContent(properties: ["message": "hi"]))
        }
    }

    // MARK: - Metadata sourced verbatim from MCP.Tool

    @Test("name, description, title, and raw inputSchema are sourced verbatim from the source MCP.Tool")
    func exposesMetadataFromSourceTool() throws {
        let schema: Value = .object(["type": .string("object")])
        let (tool, _) = try makeTool(
            name: "search", title: "Search Tool", description: "Searches things", inputSchema: schema)

        #expect(tool.name == "search")
        #expect(tool.description == "Searches things")
        #expect(tool.title == "Search Tool")
        #expect(tool.inputSchema == schema)
    }

    @Test("description falls back to empty string when the source MCP.Tool has none")
    func descriptionFallsBackToEmptyStringWhenAbsent() throws {
        let (tool, _) = try makeTool(description: nil)
        #expect(tool.description == "")
    }

    @Test("includesSchemaInInstructions is always true")
    func includesSchemaInInstructionsIsAlwaysTrue() throws {
        let (tool, _) = try makeTool()
        #expect(tool.includesSchemaInInstructions == true)
    }

    @Test("parameters is precomputed from the source MCP.Tool's inputSchema via SchemaConverter")
    func parametersIsPrecomputedFromInputSchema() throws {
        let (tool, _) = try makeTool()
        // GenerationSchema is opaque with no public introspection; the
        // strongest assertion available here is simply that construction
        // succeeded and produced a usable schema instance — deeper structural
        // coverage of the conversion itself lives in SchemaConverter's own
        // test suites.
        _ = tool.parameters
    }
}
