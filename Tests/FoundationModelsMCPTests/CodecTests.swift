import Foundation
import Testing

@testable import FoundationModelsMCP
import FoundationModels
import MCP

/// Round-trip and outbound-conversion tests for ``GeneratedContentCodec``,
/// covering every leaf/branch shape `Value` and `GeneratedContent` share:
/// null, bool, string (incl. unicode/escaping), integer, fractional number,
/// array, and (nested) object.
///
/// `GeneratedContent.Kind.number` wraps only a `Double` — there is no
/// separate integer case — so integer-vs-double fidelity is recovered by
/// whether the `Double` has a fractional part (`Int(exactly:)`). Round-trip
/// coverage below therefore uses whole numbers to exercise the integer path
/// and numbers with a genuine fractional part to exercise the double path,
/// since a whole-number `Double` (e.g. `5.0`) is indistinguishable from the
/// integer `5` once inside `GeneratedContent` — that distinction does not
/// exist to preserve.
@Suite("Codec")
struct CodecTests {

    // MARK: - Round-trip: Value -> GeneratedContent -> Value

    @Test("null value round-trips through GeneratedContent")
    func nullRoundTrips() throws {
        try assertRoundTrips(.null)
    }

    @Test("bool value round-trips through GeneratedContent", arguments: [true, false])
    func boolRoundTrips(_ value: Bool) throws {
        try assertRoundTrips(.bool(value))
    }

    @Test(
        "integer value round-trips through GeneratedContent",
        arguments: [0, 1, -1, 42, -1000, 123_456, Int(Int32.max), Int(Int32.min)]
    )
    func integerRoundTrips(_ value: Int) throws {
        try assertRoundTrips(.int(value))
    }

    @Test("integer at exactly 2^53 (Double's last exactly-representable integer) round-trips losslessly")
    func integerAtDoublePrecisionBoundaryRoundTrips() throws {
        try assertRoundTrips(.int(9_007_199_254_740_992))
        try assertRoundTrips(.int(-9_007_199_254_740_992))
    }

    @Test(
        "integer beyond Double's exact-representation range throws instead of silently corrupting",
        arguments: [9_007_199_254_740_993, -9_007_199_254_740_993]
    )
    func integerBeyondDoublePrecisionThrows(_ value: Int) {
        // 2^53 + 1 (and its negative): not exactly representable as Double,
        // so Double(int) would silently round to a different Int on the way
        // back if not guarded.
        #expect(throws: GeneratedContentCodecError.self) {
            try GeneratedContentCodec.generatedContent(from: .int(value))
        }
    }

    @Test(
        "fractional double value round-trips through GeneratedContent",
        arguments: [0.5, -3.25, 3.14159, 1e10 + 0.5, -0.001]
    )
    func fractionalDoubleRoundTrips(_ value: Double) throws {
        try assertRoundTrips(.double(value))
    }

    @Test(
        "string value round-trips through GeneratedContent, including unicode and escaping",
        arguments: [
            "",
            "hello",
            "line1\nline2",
            "quote: \"quoted\"",
            "unicode: héllo wörld",
            "emoji: 👋🎉🚀",
            "tab\tand\\backslash",
            "日本語のテキスト",
        ]
    )
    func stringRoundTrips(_ value: String) throws {
        try assertRoundTrips(.string(value))
    }

    @Test("empty array round-trips through GeneratedContent")
    func emptyArrayRoundTrips() throws {
        try assertRoundTrips(.array([]))
    }

    @Test("array of mixed scalar values round-trips through GeneratedContent")
    func arrayOfMixedScalarsRoundTrips() throws {
        try assertRoundTrips(.array([.int(1), .double(2.5), .string("three"), .bool(true), .null]))
    }

    @Test("empty object round-trips through GeneratedContent")
    func emptyObjectRoundTrips() throws {
        try assertRoundTrips(.object([:]))
    }

    @Test("object with nested object and array round-trips through GeneratedContent")
    func nestedObjectRoundTrips() throws {
        let value: Value = .object([
            "name": .string("Alice"),
            "age": .int(30),
            "score": .double(98.6),
            "active": .bool(true),
            "address": .object([
                "street": .string("123 Main St"),
                "unit": .null,
            ]),
            "tags": .array([.string("a"), .string("b"), .string("unicode: 日本語")]),
        ])
        try assertRoundTrips(value)
    }

    @Test("deeply nested value tree round-trips through GeneratedContent")
    func deeplyNestedRoundTrips() throws {
        let value: Value = .object([
            "level1": .object([
                "level2": .object([
                    "level3": .array([
                        .object(["leaf": .int(7)]),
                        .object(["leaf": .double(7.5)]),
                        .array([.null, .bool(false), .string("deep")]),
                    ])
                ])
            ])
        ])
        try assertRoundTrips(value)
    }

    // MARK: - arguments(from:) — outbound tool-call arguments

    @Test("arguments(from:) extracts a structure's properties as a String-keyed dictionary")
    func argumentsExtractsProperties() throws {
        let content = GeneratedContent(properties: [
            "path": "docs/readme.md",
            "recursive": true,
            "limit": 10,
        ])
        let arguments = try GeneratedContentCodec.arguments(from: content)
        #expect(arguments["path"] == .string("docs/readme.md"))
        #expect(arguments["recursive"] == .bool(true))
        #expect(arguments["limit"] == .int(10))
    }

    @Test("arguments(from:) recovers nested objects and arrays as Value trees")
    func argumentsRecoversNestedShapes() throws {
        let inner = GeneratedContent(properties: ["city": "Springfield"])
        let content = GeneratedContent(properties: [
            "address": inner,
        ] as KeyValuePairs<String, any ConvertibleToGeneratedContent>)
        let arguments = try GeneratedContentCodec.arguments(from: content)
        #expect(arguments["address"] == .object(["city": .string("Springfield")]))
    }

    @Test("arguments(from:) throws when the content is not an object")
    func argumentsThrowsForNonObject() {
        let content = GeneratedContent("just a string")
        #expect(throws: GeneratedContentCodecError.self) {
            try GeneratedContentCodec.arguments(from: content)
        }
    }

    // MARK: - Unsupported Value.data

    @Test("Value.data has no GeneratedContent equivalent and throws")
    func dataValueThrows() {
        let value = Value.data(mimeType: "text/plain", Data("hello".utf8))
        #expect(throws: GeneratedContentCodecError.self) {
            try GeneratedContentCodec.generatedContent(from: value)
        }
    }

    // MARK: - Helpers

    private func assertRoundTrips(_ value: Value) throws {
        let content = try GeneratedContentCodec.generatedContent(from: value)
        let roundTripped = GeneratedContentCodec.value(from: content)
        #expect(roundTripped == value)
    }
}
