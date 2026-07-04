import Foundation
import Testing

@testable import FoundationModelsMCP
import FoundationModels
import MCP

/// Coverage for ``MCPElicitationTool``, the `FoundationModels.Tool` that lets
/// the *agent itself* initiate elicitation — as opposed to the
/// server-initiated elicitation ``MCPServer``/``ElicitationCoordinator``
/// already wire up (see `ElicitationServerTests`).
///
/// Exercised against ``RecordingElicitationCoordinator`` rather than a real
/// coordinator: every test proves one of the task's three acceptance
/// criteria — the exact `message`/`requestedSchema` reach the coordinator,
/// accept/decline/cancel each render distinctly for the model, and the
/// declared ``MCPElicitationTool/parameters``' `SchemaIR` contains no
/// nested-object or array-of-object node (asserted on the inspectable IR,
/// never on the opaque Apple `GenerationSchema` types — see
/// `SchemaConverter.swift`).
@Suite("MCPElicitationTool")
struct MCPElicitationToolTests {

    // MARK: - Fixture argument payloads

    /// A fixture ``FoundationModels/GeneratedContent`` describing one
    /// ordinary (non-sensitive) field, with every optional array populated —
    /// the baseline "exact payload reaches the coordinator" fixture.
    private static func ordinaryArguments() -> GeneratedContent {
        GeneratedContent(properties: [
            "message": "What's your favorite color?",
            "fieldNames": ["favoriteColor"],
            "fieldTypes": ["string"],
            "fieldDescriptions": ["Your favorite color"],
            "requiredFieldNames": ["favoriteColor"],
            "sensitiveFieldNames": [] as [String],
            "urlFormatFieldNames": [] as [String],
        ] as KeyValuePairs<String, any ConvertibleToGeneratedContent>)
    }

    /// The ``Elicitation/RequestSchema`` ``ordinaryArguments()`` is expected
    /// to produce.
    private static let ordinaryRequestSchema = Elicitation.RequestSchema(
        properties: [
            "favoriteColor": .object([
                "type": .string("string"),
                "description": .string("Your favorite color"),
            ])
        ],
        required: ["favoriteColor"]
    )

    // MARK: - Exact payload reaches the coordinator

    @Test("call(arguments:) invokes the coordinator with the exact message and requestedSchema")
    func invokesCoordinatorWithExactMessageAndSchema() async throws {
        let coordinator = RecordingElicitationCoordinator(responding: .decline)
        let tool = try MCPElicitationTool(coordinator: coordinator)

        _ = try await tool.call(arguments: Self.ordinaryArguments())

        let formCalls = await coordinator.formCalls
        #expect(
            formCalls == [
                .init(
                    message: "What's your favorite color?",
                    requestedSchema: Self.ordinaryRequestSchema)
            ])
        #expect(await coordinator.urlCalls.isEmpty)
    }

    @Test("call(arguments:) omits optional array properties gracefully when the model leaves them out")
    func handlesOmittedOptionalArrays() async throws {
        let coordinator = RecordingElicitationCoordinator(responding: .decline)
        let tool = try MCPElicitationTool(coordinator: coordinator)

        let arguments = GeneratedContent(properties: [
            "message": "Anything to add?",
            "fieldNames": ["note"],
            "fieldTypes": ["string"],
        ] as KeyValuePairs<String, any ConvertibleToGeneratedContent>)
        _ = try await tool.call(arguments: arguments)

        let formCalls = await coordinator.formCalls
        #expect(
            formCalls == [
                .init(
                    message: "Anything to add?",
                    requestedSchema: Elicitation.RequestSchema(
                        properties: ["note": .object(["type": .string("string")])]
                    ))
            ])
    }

    @Test("a requiredFieldNames entry not present in fieldNames is dropped, never producing an invalid requestedSchema")
    func strayRequiredFieldNameIsDropped() async throws {
        let coordinator = RecordingElicitationCoordinator(responding: .decline)
        let tool = try MCPElicitationTool(coordinator: coordinator)

        let arguments = GeneratedContent(properties: [
            "message": "What's your favorite color?",
            "fieldNames": ["favoriteColor"],
            "fieldTypes": ["string"],
            "requiredFieldNames": ["favoriteColor", "notARealField"],
        ] as KeyValuePairs<String, any ConvertibleToGeneratedContent>)
        _ = try await tool.call(arguments: arguments)

        let formCalls = await coordinator.formCalls
        #expect(
            formCalls == [
                .init(
                    message: "What's your favorite color?",
                    requestedSchema: Elicitation.RequestSchema(
                        properties: ["favoriteColor": .object(["type": .string("string")])],
                        required: ["favoriteColor"]
                    ))
            ])
    }

    // MARK: - Sensitive / format: "url" fields route to URL mode

    @Test("a sensitive-marked field routes the whole request to the coordinator's URL-mode path, never form mode")
    func sensitiveFieldRoutesToURLMode() async throws {
        let coordinator = RecordingElicitationCoordinator(
            responding: .accept(content: ["apiKey": .string("secret-value")]))
        let tool = try MCPElicitationTool(coordinator: coordinator)

        let arguments = GeneratedContent(properties: [
            "message": "Please provide your API key",
            "fieldNames": ["apiKey"],
            "fieldTypes": ["string"],
            "sensitiveFieldNames": ["apiKey"],
        ] as KeyValuePairs<String, any ConvertibleToGeneratedContent>)
        _ = try await tool.call(arguments: arguments)

        #expect(await coordinator.formCalls.isEmpty)
        #expect(
            await coordinator.urlCalls == [
                .init(message: "Please provide your API key", url: nil)
            ])
    }

    @Test("a format: url field routes the whole request to the coordinator's URL-mode path, never form mode")
    func urlFormatFieldRoutesToURLMode() async throws {
        let coordinator = RecordingElicitationCoordinator(
            responding: .accept(content: ["callbackURL": .string("https://example.com")]))
        let tool = try MCPElicitationTool(coordinator: coordinator)

        let arguments = GeneratedContent(properties: [
            "message": "Provide your callback URL",
            "fieldNames": ["callbackURL"],
            "fieldTypes": ["string"],
            "urlFormatFieldNames": ["callbackURL"],
        ] as KeyValuePairs<String, any ConvertibleToGeneratedContent>)
        _ = try await tool.call(arguments: arguments)

        #expect(await coordinator.formCalls.isEmpty)
        #expect(
            await coordinator.urlCalls == [
                .init(message: "Provide your callback URL", url: nil)
            ])
    }

    // MARK: - accept / decline / cancel render distinctly for the model

    @Test("an accept response renders the user's structured answer for the model")
    func acceptRendersStructuredAnswer() async throws {
        let coordinator = RecordingElicitationCoordinator(
            responding: .accept(content: ["favoriteColor": .string("teal")]))
        let tool = try MCPElicitationTool(coordinator: coordinator)

        let output = try await tool.call(arguments: Self.ordinaryArguments())

        #expect(output.contains("teal"))
        #expect(output.contains("favoriteColor"))
    }

    @Test("a decline response renders distinctly from accept and cancel")
    func declineRendersDistinctly() async throws {
        let coordinator = RecordingElicitationCoordinator(responding: .decline)
        let tool = try MCPElicitationTool(coordinator: coordinator)

        let output = try await tool.call(arguments: Self.ordinaryArguments())

        #expect(output.contains("declined"))
        #expect(!output.contains("teal"))
    }

    @Test("a cancel response renders distinctly from accept and decline")
    func cancelRendersDistinctly() async throws {
        let coordinator = RecordingElicitationCoordinator(responding: .cancel)
        let tool = try MCPElicitationTool(coordinator: coordinator)

        let output = try await tool.call(arguments: Self.ordinaryArguments())

        #expect(output.contains("dismissed") || output.contains("cancel"))
        #expect(!output.contains("declined"))
    }

    @Test("accept, decline, and cancel each render a distinct string")
    func allThreeOutcomesRenderDistinctly() async throws {
        let acceptOutput = try await MCPElicitationTool(
            coordinator: RecordingElicitationCoordinator(
                responding: .accept(content: ["favoriteColor": .string("teal")]))
        ).call(arguments: Self.ordinaryArguments())
        let declineOutput = try await MCPElicitationTool(
            coordinator: RecordingElicitationCoordinator(responding: .decline)
        ).call(arguments: Self.ordinaryArguments())
        let cancelOutput = try await MCPElicitationTool(
            coordinator: RecordingElicitationCoordinator(responding: .cancel)
        ).call(arguments: Self.ordinaryArguments())

        #expect(Set([acceptOutput, declineOutput, cancelOutput]).count == 3)
    }

    // MARK: - Metadata

    @Test("name, description, and includesSchemaInInstructions are stable tool metadata")
    func exposesStableMetadata() throws {
        let tool = try MCPElicitationTool(coordinator: RecordingElicitationCoordinator(responding: .decline))

        #expect(tool.name == MCPElicitationTool.toolName)
        #expect(!tool.description.isEmpty)
        #expect(tool.includesSchemaInInstructions == true)
    }

    // MARK: - Declared parameters' SchemaIR is flat-primitive-only

    /// Whether `node` — or any descendant reachable through
    /// `.array(items:)`/`.guided(base:guide:)` — is an object node, or an
    /// array whose items are (transitively) an object node.
    ///
    /// - Parameter node: The `SchemaIR` node to inspect.
    /// - Returns: `true` if `node` contains a nested object or
    ///   array-of-object node anywhere in its structure.
    private func containsNestedObjectOrArrayOfObject(_ node: SchemaIR) -> Bool {
        switch node {
        case .object:
            return true
        case .array(let items):
            return containsNestedObjectOrArrayOfObject(items)
        case .guided(let base, _):
            return containsNestedObjectOrArrayOfObject(base)
        case .string, .integer, .number, .boolean, .enumeration, .reference, .unknown:
            return false
        }
    }

    @Test("MCPElicitationTool.inputSchema parses to an object root with only flat-primitive properties")
    func declaredParametersContainOnlyFlatPrimitives() throws {
        let conversion = SchemaConverter.parse(
            MCPElicitationTool.inputSchema, name: MCPElicitationTool.toolName)

        guard case .object(_, _, let properties) = conversion.root else {
            Issue.record("expected MCPElicitationTool.inputSchema to parse to an object root")
            return
        }
        #expect(!properties.isEmpty)
        for property in properties {
            #expect(
                !containsNestedObjectOrArrayOfObject(property.schema),
                "property \"\(property.name)\" contains a nested object or array-of-object node: \(String(describing: property.schema))"
            )
        }
    }

    @Test("emitting MCPElicitationTool.inputSchema into a GenerationSchema succeeds")
    func emissionSmokeTest() throws {
        let conversion = SchemaConverter.parse(
            MCPElicitationTool.inputSchema, name: MCPElicitationTool.toolName)
        _ = try SchemaConverter.emit(conversion)
    }
}
