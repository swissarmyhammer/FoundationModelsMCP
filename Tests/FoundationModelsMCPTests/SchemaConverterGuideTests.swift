import Foundation
import Testing

@testable import FoundationModelsMCP
import MCP

/// Table-driven tests asserting the JSON-Schema-2020-12 *constraint* mapping
/// — `SchemaIR/guided(base:guide:)` and its ``SchemaIR/GuideSpec`` payload —
/// over a corpus of real-world MCP tool `inputSchema` fixtures.
///
/// `DynamicGenerationSchema` / `GenerationSchema` are opaque (no public
/// introspection), so these tests assert against `SchemaIR` — the inspectable
/// stage-1 intermediate representation — rather than the emitted Apple types.
/// The one exception is `emissionSmokeTest`, which only checks that stage 2
/// (`SchemaIR` → `DynamicGenerationSchema` → `GenerationSchema`) completes
/// without throwing.
@Suite("SchemaConverterGuide")
struct SchemaConverterGuideTests {

    /// Every guide-focused fixture in `Fixtures/`, used by ``emissionSmokeTest``.
    private static let guideFixtureNames = [
        "numeric_range",
        "pattern_match",
        "bounded_list",
        "unsupported_constructs",
    ]

    private static var fixturesDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
    }

    private static func loadSchema(_ fixtureName: String) throws -> Value {
        let url = fixturesDirectory.appendingPathComponent("\(fixtureName).json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Value.self, from: data)
    }

    /// A test-only sink that collects every ``SchemaConversionLogRecord`` reported
    /// during a `SchemaConverter.parse(_:name:onDrop:)` call, so tests can assert
    /// on exactly what was logged.
    ///
    /// `@unchecked Sendable` synchronization invariant: the mutable `records`
    /// array is only ever *mutated* while holding `lock` — `handler()`'s
    /// closure locks before every `append`, so concurrent `onDrop`
    /// invocations from `SchemaConverter.parse` cannot race on the backing
    /// storage. The `records` property's own getter is not separately
    /// synchronized; tests only read it after `parse(_:name:onDrop:)` has
    /// already returned, i.e. once all `handler()` calls have completed, so
    /// no read ever overlaps a concurrent write.
    private final class LogRecorder: @unchecked Sendable {
        private(set) var records: [SchemaConversionLogRecord] = []
        private let lock = NSLock()

        func handler() -> SchemaConversionLogHandler {
            { [weak self] record in
                guard let self else { return }
                self.lock.lock()
                self.records.append(record)
                self.lock.unlock()
            }
        }
    }

    // MARK: - enum → anyOf (already a named choice schema; documented here as its guide-equivalent)

    @Test("enum property is already represented by its own anyOf-shaped named choice schema")
    func enumGuideSpec() throws {
        let inputSchema = try Self.loadSchema("set_log_level")
        let conversion = SchemaConverter.parse(inputSchema, name: "set_log_level")

        guard case let .object(_, _, properties) = conversion.root else {
            Issue.record("expected an object root")
            return
        }
        let level = try #require(properties.first { $0.name == "level" })
        guard case let .enumeration(_, _, values) = level.schema else {
            Issue.record("expected level to be .enumeration (the enum -> anyOf mapping)")
            return
        }
        #expect(values == ["debug", "info", "warning", "error", "critical"])
    }

    // MARK: - minimum / maximum → range / minimum / maximum guides (Decimal)

    @Test("inclusive minimum and maximum produce a numericRange guide spec")
    func numericRangeGuideSpec() throws {
        let inputSchema = try Self.loadSchema("numeric_range")
        let conversion = SchemaConverter.parse(inputSchema, name: "numeric_range")

        guard case let .object(_, _, properties) = conversion.root else {
            Issue.record("expected an object root")
            return
        }

        let score = try #require(properties.first { $0.name == "score" })
        guard case let .guided(base, guide) = score.schema else {
            Issue.record("expected score to be .guided")
            return
        }
        guard case .number = base else {
            Issue.record("expected score's guided base to be .number")
            return
        }
        guard case let .numericRange(minimum, maximum) = guide else {
            Issue.record("expected score's guide to be .numericRange")
            return
        }
        #expect(minimum == 0)
        #expect(maximum == 100)
    }

    @Test("a minimum with no maximum produces a minimum-only numericRange guide spec")
    func numericMinimumOnlyGuideSpec() throws {
        let inputSchema = try Self.loadSchema("numeric_range")
        let conversion = SchemaConverter.parse(inputSchema, name: "numeric_range")

        guard case let .object(_, _, properties) = conversion.root else {
            Issue.record("expected an object root")
            return
        }

        let priority = try #require(properties.first { $0.name == "priority" })
        guard case let .guided(base, guide) = priority.schema else {
            Issue.record("expected priority to be .guided")
            return
        }
        guard case .integer = base else {
            Issue.record("expected priority's guided base to be .integer")
            return
        }
        guard case let .numericRange(minimum, maximum) = guide else {
            Issue.record("expected priority's guide to be .numericRange")
            return
        }
        #expect(minimum == 1)
        #expect(maximum == nil)
    }

    @Test("exclusiveMinimum/exclusiveMaximum on a number are nudged inward by an epsilon")
    func exclusiveNumberBoundsGuideSpec() throws {
        let inputSchema = try Self.loadSchema("numeric_range")
        let conversion = SchemaConverter.parse(inputSchema, name: "numeric_range")

        guard case let .object(_, _, properties) = conversion.root else {
            Issue.record("expected an object root")
            return
        }

        let temperatureDelta = try #require(properties.first { $0.name == "temperatureDelta" })
        guard case let .guided(_, guide) = temperatureDelta.schema else {
            Issue.record("expected temperatureDelta to be .guided")
            return
        }
        guard case let .numericRange(minimum, maximum) = guide else {
            Issue.record("expected temperatureDelta's guide to be .numericRange")
            return
        }
        let effectiveMinimum = try #require(minimum)
        let effectiveMaximum = try #require(maximum)
        #expect(effectiveMinimum > -50)
        #expect(effectiveMaximum < 50)
    }

    @Test("exclusiveMinimum/exclusiveMaximum on an integer are nudged inward by one")
    func exclusiveIntegerBoundsGuideSpec() throws {
        let inputSchema = try Self.loadSchema("numeric_range")
        let conversion = SchemaConverter.parse(inputSchema, name: "numeric_range")

        guard case let .object(_, _, properties) = conversion.root else {
            Issue.record("expected an object root")
            return
        }

        let attempts = try #require(properties.first { $0.name == "attempts" })
        guard case let .guided(_, guide) = attempts.schema else {
            Issue.record("expected attempts to be .guided")
            return
        }
        guard case let .numericRange(minimum, maximum) = guide else {
            Issue.record("expected attempts's guide to be .numericRange")
            return
        }
        #expect(minimum == 1)
        #expect(maximum == 9)
    }

    @Test("a stricter exclusiveMinimum wins over a laxer inclusive minimum on the same property")
    func combinedMinimumBoundsPrefersStricter() throws {
        let inputSchema = try Self.loadSchema("numeric_range")
        let conversion = SchemaConverter.parse(inputSchema, name: "numeric_range")

        guard case let .object(_, _, properties) = conversion.root else {
            Issue.record("expected an object root")
            return
        }

        let strictLowerBound = try #require(properties.first { $0.name == "strictLowerBound" })
        guard case let .guided(_, guide) = strictLowerBound.schema else {
            Issue.record("expected strictLowerBound to be .guided")
            return
        }
        guard case let .numericRange(minimum, maximum) = guide else {
            Issue.record("expected strictLowerBound's guide to be .numericRange")
            return
        }
        // exclusiveMinimum: 5 nudges to 6, which is stricter than the plain minimum: 3.
        #expect(minimum == 6)
        #expect(maximum == nil)
    }

    @Test("a stricter exclusiveMaximum wins over a laxer inclusive maximum on the same property")
    func combinedMaximumBoundsPrefersStricter() throws {
        let inputSchema = try Self.loadSchema("numeric_range")
        let conversion = SchemaConverter.parse(inputSchema, name: "numeric_range")

        guard case let .object(_, _, properties) = conversion.root else {
            Issue.record("expected an object root")
            return
        }

        let strictUpperBound = try #require(properties.first { $0.name == "strictUpperBound" })
        guard case let .guided(_, guide) = strictUpperBound.schema else {
            Issue.record("expected strictUpperBound to be .guided")
            return
        }
        guard case let .numericRange(minimum, maximum) = guide else {
            Issue.record("expected strictUpperBound's guide to be .numericRange")
            return
        }
        // exclusiveMaximum: 9 nudges to just under 9, which is stricter than the plain maximum: 10.
        let effectiveMaximum = try #require(maximum)
        #expect(minimum == nil)
        #expect(effectiveMaximum < 9)
        #expect(effectiveMaximum > 8.9999)
    }

    @Test("crossed bounds (exclusiveMinimum/exclusiveMaximum nudge past each other) fall back to a plain, unguided integer without crashing, and log a dropped-construct record")
    func impossibleRangeFallsBackAndLogs() throws {
        let inputSchema = try Self.loadSchema("numeric_range")
        let recorder = LogRecorder()
        let conversion = SchemaConverter.parse(inputSchema, name: "numeric_range", onDrop: recorder.handler())

        guard case let .object(_, _, properties) = conversion.root else {
            Issue.record("expected an object root")
            return
        }

        let impossibleRange = try #require(properties.first { $0.name == "impossibleRange" })
        guard case .integer = impossibleRange.schema else {
            Issue.record("expected impossibleRange to fall back to plain .integer, got \(impossibleRange.schema)")
            return
        }

        let minimumRecords = recorder.records.filter { $0.path == "/impossibleRange" }
        #expect(minimumRecords.count == 1)

        // Emission must not throw (or crash) either.
        _ = try SchemaConverter.emit(conversion)
    }

    // MARK: - pattern → best-effort ECMA-262 -> Swift Regex compile

    @Test("a valid pattern produces a pattern guide spec")
    func validPatternGuideSpec() throws {
        let inputSchema = try Self.loadSchema("pattern_match")
        let conversion = SchemaConverter.parse(inputSchema, name: "pattern_match")

        guard case let .object(_, _, properties) = conversion.root else {
            Issue.record("expected an object root")
            return
        }

        let code = try #require(properties.first { $0.name == "code" })
        guard case let .guided(base, guide) = code.schema else {
            Issue.record("expected code to be .guided")
            return
        }
        guard case .string = base else {
            Issue.record("expected code's guided base to be .string")
            return
        }
        guard case let .pattern(source) = guide else {
            Issue.record("expected code's guide to be .pattern")
            return
        }
        #expect(source == "^[A-Z]{3}-[0-9]{4}$")
    }

    @Test("an invalid pattern falls back to a plain string without throwing, and logs a dropped-construct record")
    func invalidPatternFallsBackAndLogs() throws {
        let inputSchema = try Self.loadSchema("pattern_match")
        let recorder = LogRecorder()
        let conversion = SchemaConverter.parse(inputSchema, name: "pattern_match", onDrop: recorder.handler())

        guard case let .object(_, _, properties) = conversion.root else {
            Issue.record("expected an object root")
            return
        }

        let raw = try #require(properties.first { $0.name == "raw" })
        guard case .string = raw.schema else {
            Issue.record("expected raw to fall back to plain .string, got \(raw.schema)")
            return
        }

        let patternRecords = recorder.records.filter { $0.keyword == "pattern" }
        #expect(patternRecords.count == 1)
        #expect(patternRecords.first?.path == "/raw")
    }

    // MARK: - minItems / maxItems → count guides, including nested arrays

    @Test("minItems/maxItems on nested arrays each produce their own count guide spec")
    func nestedArrayCountGuideSpec() throws {
        let inputSchema = try Self.loadSchema("bounded_list")
        let conversion = SchemaConverter.parse(inputSchema, name: "bounded_list")

        guard case let .object(_, _, properties) = conversion.root else {
            Issue.record("expected an object root")
            return
        }

        let batches = try #require(properties.first { $0.name == "batches" })
        guard case let .guided(outerBase, outerGuide) = batches.schema else {
            Issue.record("expected batches to be .guided")
            return
        }
        guard case let .count(outerMinimum, outerMaximum) = outerGuide else {
            Issue.record("expected batches's guide to be .count")
            return
        }
        #expect(outerMinimum == 1)
        #expect(outerMaximum == 5)

        guard case let .array(items) = outerBase else {
            Issue.record("expected batches's guided base to be .array")
            return
        }
        guard case let .guided(innerBase, innerGuide) = items else {
            Issue.record("expected the nested array to also be .guided")
            return
        }
        guard case let .count(innerMinimum, innerMaximum) = innerGuide else {
            Issue.record("expected the nested array's guide to be .count")
            return
        }
        #expect(innerMinimum == 2)
        #expect(innerMaximum == 2)
        guard case let .array(innerItems) = innerBase else {
            Issue.record("expected the nested array's guided base to be .array")
            return
        }
        guard case .number = innerItems else {
            Issue.record("expected the innermost items schema to be .number")
            return
        }
    }

    @Test("a self-contradictory count constraint (minItems > maxItems) falls back to a plain, unguided array without misrepresenting it, and logs a dropped-construct record")
    func impossibleCountFallsBackAndLogs() throws {
        let inputSchema = try Self.loadSchema("bounded_list")
        let recorder = LogRecorder()
        let conversion = SchemaConverter.parse(inputSchema, name: "bounded_list", onDrop: recorder.handler())

        guard case let .object(_, _, properties) = conversion.root else {
            Issue.record("expected an object root")
            return
        }

        let impossibleBatch = try #require(properties.first { $0.name == "impossibleBatch" })
        guard case let .array(items) = impossibleBatch.schema else {
            Issue.record("expected impossibleBatch to fall back to a plain .array, got \(impossibleBatch.schema)")
            return
        }
        guard case .string = items else {
            Issue.record("expected impossibleBatch's items to still be .string")
            return
        }

        let matchingRecords = recorder.records.filter { $0.path == "/impossibleBatch" }
        #expect(matchingRecords.count == 1)
        #expect(matchingRecords.first?.keyword == "minItems")

        // Emission must not throw either.
        _ = try SchemaConverter.emit(conversion)
    }

    // MARK: - unsupported constructs degrade to .unknown and log exactly once each

    @Test("every unsupported construct degrades to .unknown and logs exactly one record naming its keyword and path")
    func unsupportedConstructsEachLogExactlyOnce() throws {
        let inputSchema = try Self.loadSchema("unsupported_constructs")
        let recorder = LogRecorder()
        let conversion = SchemaConverter.parse(
            inputSchema, name: "unsupported_constructs", onDrop: recorder.handler())

        guard case let .object(_, _, properties) = conversion.root else {
            Issue.record("expected an object root")
            return
        }

        let expectedDrops: [(property: String, keyword: String)] = [
            ("union", "anyOf"),
            ("choice", "oneOf"),
            ("openBag", "additionalProperties"),
            ("dynamicKeys", "patternProperties"),
            ("pair", "prefixItems"),
            ("legacyTuple", "items"),
            ("anythingButNull", "not"),
            ("selfReferential", "$ref"),
            ("refWithSiblingAnyOf", "anyOf"),
        ]

        for (propertyName, keyword) in expectedDrops {
            let property = try #require(properties.first { $0.name == propertyName })
            guard case .unknown = property.schema else {
                Issue.record("expected \(propertyName) to degrade to .unknown")
                continue
            }
            let matchingRecords = recorder.records.filter { $0.path == "/\(propertyName)" }
            #expect(
                matchingRecords.count == 1,
                "expected exactly one log record for \(propertyName), got \(matchingRecords.count)")
            #expect(matchingRecords.first?.keyword == keyword)
        }

        #expect(recorder.records.count == expectedDrops.count)
    }

    // MARK: - emission smoke test (SchemaIR → DynamicGenerationSchema → GenerationSchema)

    @Test("every guide fixture emits a GenerationSchema without throwing")
    func emissionSmokeTest() throws {
        for fixtureName in Self.guideFixtureNames {
            let inputSchema = try Self.loadSchema(fixtureName)
            let conversion = SchemaConverter.parse(inputSchema, name: fixtureName)
            _ = try SchemaConverter.emit(conversion)
        }
    }
}
