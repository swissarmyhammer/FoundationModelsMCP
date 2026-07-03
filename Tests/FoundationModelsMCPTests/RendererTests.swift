import Foundation
import Testing

@testable import FoundationModelsMCP
import MCP

/// Coverage for ``ToolContentRenderer``: one test per `Tool.Content` case,
/// the `isError` marker, `structuredContent` surfacing, each rule of the
/// pinned outputSchema-validation subset (passing and failing), an
/// out-of-subset keyword being ignored, and proof `.resourceLink` is never
/// dereferenced.
@Suite("Renderer")
struct RendererTests {

    // MARK: - Content cases

    @Test("text content renders verbatim")
    func textContentRendersVerbatim() {
        let result = CallTool.Result(content: [.text(text: "hello world", annotations: nil, _meta: nil)])
        let rendered = ToolContentRenderer.render(result)
        #expect(rendered == "hello world")
    }

    @Test("image content renders a deterministic placeholder, never the raw data")
    func imageContentRendersPlaceholder() {
        let result = CallTool.Result(content: [
            .image(data: "aGVsbG8=", mimeType: "image/png", annotations: nil, _meta: nil)
        ])
        let rendered = ToolContentRenderer.render(result)
        #expect(rendered.contains("image/png"))
        #expect(!rendered.contains("aGVsbG8="))
    }

    @Test("audio content renders a deterministic placeholder, never the raw data")
    func audioContentRendersPlaceholder() {
        let result = CallTool.Result(content: [
            .audio(data: "aGVsbG8=", mimeType: "audio/mpeg", annotations: nil, _meta: nil)
        ])
        let rendered = ToolContentRenderer.render(result)
        #expect(rendered.contains("audio/mpeg"))
        #expect(!rendered.contains("aGVsbG8="))
    }

    @Test("resource content with text renders the embedded text")
    func resourceContentWithTextRendersText() {
        let resource = Resource.Content.text("file body", uri: "file:///notes.txt", mimeType: "text/plain")
        let result = CallTool.Result(content: [.resource(resource: resource, annotations: nil, _meta: nil)])
        let rendered = ToolContentRenderer.render(result)
        #expect(rendered.contains("file:///notes.txt"))
        #expect(rendered.contains("file body"))
    }

    @Test("resource content with only binary blob renders a placeholder, never decodes the blob")
    func resourceContentWithBlobRendersPlaceholder() {
        let resource = Resource.Content.binary(
            Data("binary".utf8), uri: "file:///image.bin", mimeType: "application/octet-stream")
        let result = CallTool.Result(content: [.resource(resource: resource, annotations: nil, _meta: nil)])
        let rendered = ToolContentRenderer.render(result)
        #expect(rendered.contains("file:///image.bin"))
        #expect(rendered.contains("application/octet-stream"))
    }

    @Test("resourceLink renders a link and is never dereferenced")
    func resourceLinkRendersLinkWithoutDereferencing() {
        let result = CallTool.Result(content: [
            .resourceLink(
                uri: "https://example.com/does-not-exist-and-is-never-fetched",
                name: "example",
                title: "Example Resource",
                description: "a description that must not appear",
                mimeType: "text/html",
                annotations: nil
            )
        ])
        let rendered = ToolContentRenderer.render(result)
        #expect(rendered.contains("https://example.com/does-not-exist-and-is-never-fetched"))
        #expect(rendered.contains("Example Resource"))
        // Only the link's declared metadata is rendered — description is not
        // part of the documented resourceLink format, and no fetch ever
        // happens to discover more about the target.
        #expect(!rendered.contains("a description that must not appear"))
    }

    @Test("multiple content items are each rendered and joined")
    func multipleContentItemsAreJoined() {
        let result = CallTool.Result(content: [
            .text(text: "first", annotations: nil, _meta: nil),
            .text(text: "second", annotations: nil, _meta: nil),
        ])
        let rendered = ToolContentRenderer.render(result)
        #expect(rendered.contains("first"))
        #expect(rendered.contains("second"))
    }

    // MARK: - isError

    @Test("isError nil means success — no error marker")
    func isErrorNilMeansSuccess() {
        let result = CallTool.Result(content: [.text(text: "ok", annotations: nil, _meta: nil)], isError: nil)
        let rendered = ToolContentRenderer.render(result)
        #expect(!rendered.contains("Error"))
    }

    @Test("isError false means success — no error marker")
    func isErrorFalseMeansSuccess() {
        let result = CallTool.Result(content: [.text(text: "ok", annotations: nil, _meta: nil)], isError: false)
        let rendered = ToolContentRenderer.render(result)
        #expect(!rendered.contains("Error"))
    }

    @Test("isError true is clearly marked in the rendered output")
    func isErrorTrueIsMarked() {
        let result = CallTool.Result(
            content: [.text(text: "boom", annotations: nil, _meta: nil)], isError: true)
        let rendered = ToolContentRenderer.render(result)
        #expect(rendered.contains("Error"))
        #expect(rendered.contains("boom"))
    }

    // MARK: - structuredContent surfacing

    @Test("structuredContent is surfaced in the rendered output")
    func structuredContentIsSurfaced() {
        let structured: Value = .object(["name": .string("Alice"), "age": .int(30)])
        let result = CallTool.Result(content: [], structuredContent: structured as Value?)
        let rendered = ToolContentRenderer.render(result)
        #expect(rendered.contains("Alice"))
        #expect(rendered.contains("30"))
    }

    @Test("structuredContent with no outputSchema produces no validation note")
    func structuredContentWithoutSchemaHasNoNote() {
        let structured: Value = .object(["anything": .string("goes")])
        let result = CallTool.Result(content: [], structuredContent: structured as Value?)
        let rendered = ToolContentRenderer.render(result, outputSchema: nil)
        #expect(!rendered.contains("Note"))
    }

    // MARK: - outputSchema validation subset: passing

    private var passingSchema: Value {
        .object([
            "type": .string("object"),
            "required": .array([.string("name"), .string("age")]),
            "properties": .object([
                "name": .object(["type": .string("string")]),
                "age": .object(["type": .string("integer")]),
                "status": .object([
                    "type": .string("string"),
                    "enum": .array([.string("active"), .string("inactive")]),
                ]),
            ]),
        ])
    }

    @Test("structuredContent that satisfies every subset rule produces no validation note")
    func structuredContentPassingAllRules() {
        let structured: Value = .object([
            "name": .string("Alice"), "age": .int(30), "status": .string("active"),
        ])
        let result = CallTool.Result(content: [], structuredContent: structured as Value?)
        let rendered = ToolContentRenderer.render(result, outputSchema: passingSchema)
        #expect(!rendered.contains("Note"))
    }

    // MARK: - outputSchema validation subset: failing, one rule at a time

    @Test("top-level type mismatch renders as a note, never hidden")
    func topLevelTypeMismatchIsNoted() {
        let structured: Value = .array([.string("not an object")])
        let result = CallTool.Result(content: [], structuredContent: structured as Value?)
        let rendered = ToolContentRenderer.render(result, outputSchema: passingSchema)
        #expect(rendered.contains("Note"))
        #expect(rendered.contains("object"))
        #expect(rendered.contains("array"))
        // Failure is a note alongside content, never a suppression.
        #expect(rendered.contains("not an object"))
    }

    @Test("missing required property renders as a note")
    func missingRequiredPropertyIsNoted() {
        let structured: Value = .object(["name": .string("Alice")])
        let result = CallTool.Result(content: [], structuredContent: structured as Value?)
        let rendered = ToolContentRenderer.render(result, outputSchema: passingSchema)
        #expect(rendered.contains("Note"))
        #expect(rendered.contains("age"))
    }

    @Test("per-property primitive type mismatch renders as a note")
    func propertyTypeMismatchIsNoted() {
        let structured: Value = .object([
            "name": .string("Alice"), "age": .string("thirty"),
        ])
        let result = CallTool.Result(content: [], structuredContent: structured as Value?)
        let rendered = ToolContentRenderer.render(result, outputSchema: passingSchema)
        #expect(rendered.contains("Note"))
        #expect(rendered.contains("age"))
    }

    @Test("enum non-membership renders as a note")
    func enumMismatchIsNoted() {
        let structured: Value = .object([
            "name": .string("Alice"), "age": .int(30), "status": .string("unknown"),
        ])
        let result = CallTool.Result(content: [], structuredContent: structured as Value?)
        let rendered = ToolContentRenderer.render(result, outputSchema: passingSchema)
        #expect(rendered.contains("Note"))
        #expect(rendered.contains("status"))
    }

    // MARK: - out-of-subset keywords are ignored, not enforced

    @Test("additionalProperties: false is outside the subset and never enforced")
    func additionalPropertiesKeywordIsIgnored() {
        let schemaWithAdditionalProperties: Value = .object([
            "type": .string("object"),
            "additionalProperties": .bool(false),
            "properties": .object([
                "name": .object(["type": .string("string")])
            ]),
        ])
        // "extra" is not declared in properties and additionalProperties is
        // false — a full JSON Schema validator would reject this, but the
        // pinned subset does not inspect additionalProperties at all.
        let structured: Value = .object(["name": .string("Alice"), "extra": .string("surprise")])
        let result = CallTool.Result(content: [], structuredContent: structured as Value?)
        let rendered = ToolContentRenderer.render(result, outputSchema: schemaWithAdditionalProperties)
        #expect(!rendered.contains("Note"))
    }

    @Test("format is outside the subset and never enforced")
    func formatKeywordIsIgnored() {
        let schemaWithFormat: Value = .object([
            "type": .string("object"),
            "properties": .object([
                "email": .object(["type": .string("string"), "format": .string("email")])
            ]),
        ])
        // Not a well-formed email — a validator that enforced `format` would
        // reject this; the pinned subset only checks primitive `type`.
        let structured: Value = .object(["email": .string("not-an-email")])
        let result = CallTool.Result(content: [], structuredContent: structured as Value?)
        let rendered = ToolContentRenderer.render(result, outputSchema: schemaWithFormat)
        #expect(!rendered.contains("Note"))
    }

    @Test("a property's own nested properties/required is outside the subset and never enforced")
    func nestedPropertiesAndRequiredKeywordsAreIgnored() {
        let schemaWithNestedRequired: Value = .object([
            "type": .string("object"),
            "properties": .object([
                "address": .object([
                    "type": .string("object"),
                    "required": .array([.string("street")]),
                    "properties": .object([
                        "street": .object(["type": .string("string")])
                    ]),
                ])
            ]),
        ])
        // "address" is missing its own "street" — a validator that recursed
        // into a property's nested `required` would reject this, but the
        // pinned subset only checks a property's own top-level `type`, one
        // level deep, and does not recurse further.
        let structured: Value = .object(["address": .object([:])])
        let result = CallTool.Result(content: [], structuredContent: structured as Value?)
        let rendered = ToolContentRenderer.render(result, outputSchema: schemaWithNestedRequired)
        #expect(!rendered.contains("Note"))
    }

    @Test("a Value.data structuredContent value satisfies a string-typed schema, matching its JSON type")
    func dataValueMatchesStringSchemaType() {
        // `.data` decodes from a JSON string (a data URL); `matchesType` must
        // agree with `jsonType(of:)` reporting it as `"string"` — otherwise
        // a `.data` value under a `"string"` schema would self-contradictorily
        // note "expected type string, got string".
        let schema: Value = .object([
            "type": .string("object"),
            "properties": .object([
                "payload": .object(["type": .string("string")])
            ]),
        ])
        let structured: Value = .object([
            "payload": .data(mimeType: "text/plain", Data("hello".utf8))
        ])
        let result = CallTool.Result(content: [], structuredContent: structured as Value?)
        let rendered = ToolContentRenderer.render(result, outputSchema: schema)
        #expect(!rendered.contains("Note"))
    }

    // MARK: - Composition

    @Test("content, isError, and structuredContent compose in one rendered result")
    func contentErrorAndStructuredContentCompose() {
        let structuredContent: Value = .object(["code": .int(500)])
        let result = CallTool.Result(
            content: [.text(text: "partial failure", annotations: nil, _meta: nil)],
            structuredContent: structuredContent as Value?,
            isError: true
        )
        let rendered = ToolContentRenderer.render(result)
        #expect(rendered.contains("Error"))
        #expect(rendered.contains("partial failure"))
        #expect(rendered.contains("500"))
    }

    @Test("a structuredContent validation failure never hides the accompanying content")
    func validationFailureNeverHidesAccompanyingContent() {
        let structured: Value = .object(["name": .string("Alice")])  // missing required "age"
        let result = CallTool.Result(
            content: [.text(text: "call succeeded", annotations: nil, _meta: nil)],
            structuredContent: structured as Value?
        )
        let rendered = ToolContentRenderer.render(result, outputSchema: passingSchema)
        // The failure is a note alongside the content, not a replacement for it.
        #expect(rendered.contains("call succeeded"))
        #expect(rendered.contains("Alice"))
        #expect(rendered.contains("Note"))
        #expect(rendered.contains("age"))
    }
}
