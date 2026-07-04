import Foundation
import Testing

@testable import FoundationModelsMCP
import MCP

/// Self-tests for ``MockClient``: proves it records `callTool` invocations
/// exactly (name + arguments, in call order) and plays back scripted results
/// verbatim — one test per scripted kind (success, `isError`,
/// `structuredContent`, and each `Tool.Content` case) — plus FIFO ordering
/// across multiple calls, a scripted thrown error, and exhaustion.
@Suite("MockClientSelf")
struct MockClientSelfTests {

    // MARK: - Conformance

    @Test("MockClient conforms to the library's MCPToolCalling seam")
    func conformsToSeam() {
        let mock = MockClient()
        let seam: any MCPToolCalling = mock
        #expect(seam is MockClient)
    }

    // MARK: - Recording fidelity

    @Test("records tool name and arguments exactly, in call order")
    func recordsInvocationsExactly() async throws {
        let mock = MockClient()
        mock.script(CallTool.Result(content: [.text(text: "first", annotations: nil, _meta: nil)]))
        mock.script(CallTool.Result(content: [.text(text: "second", annotations: nil, _meta: nil)]))

        _ = try await mock.callTool(name: "alpha", arguments: ["x": .int(1)])
        _ = try await mock.callTool(name: "beta", arguments: nil)

        #expect(mock.invocations.count == 2)
        #expect(mock.invocations[0] == MockClient.Invocation(name: "alpha", arguments: ["x": .int(1)]))
        #expect(mock.invocations[1] == MockClient.Invocation(name: "beta", arguments: nil))
    }

    @Test("records arguments byte-for-byte, including nested structures")
    func recordsNestedArgumentsExactly() async throws {
        let mock = MockClient()
        let arguments: [String: Value] = [
            "path": .string("docs/readme.md"),
            "options": .object(["recursive": .bool(true), "limit": .int(10)]),
            "tags": .array([.string("a"), .string("b")]),
        ]
        mock.script(CallTool.Result(content: []))

        _ = try await mock.callTool(name: "search", arguments: arguments)

        #expect(mock.invocations.count == 1)
        #expect(mock.invocations[0].name == "search")
        #expect(mock.invocations[0].arguments == arguments)
    }

    @Test("records an empty arguments dictionary distinctly from nil arguments")
    func recordsEmptyArgumentsDistinctlyFromNil() async throws {
        let mock = MockClient()
        mock.script(CallTool.Result(content: []))
        mock.script(CallTool.Result(content: []))

        _ = try await mock.callTool(name: "tool", arguments: [:])
        _ = try await mock.callTool(name: "tool", arguments: nil)

        #expect(mock.invocations[0] == MockClient.Invocation(name: "tool", arguments: [:]))
        #expect(mock.invocations[1] == MockClient.Invocation(name: "tool", arguments: nil))
        #expect(mock.invocations[0] != mock.invocations[1])
    }

    // MARK: - Playback: success / isError / structuredContent

    @Test("plays back a scripted success result verbatim")
    func playsBackScriptedSuccess() async throws {
        let mock = MockClient()
        let expected = CallTool.Result(content: [.text(text: "hello", annotations: nil, _meta: nil)])
        mock.script(expected)

        let result = try await mock.callTool(name: "tool", arguments: nil)
        #expect(result == expected)
    }

    @Test("plays back a scripted isError result verbatim")
    func playsBackScriptedIsError() async throws {
        let mock = MockClient()
        let expected = CallTool.Result(
            content: [.text(text: "boom", annotations: nil, _meta: nil)], isError: true)
        mock.script(expected)

        let result = try await mock.callTool(name: "tool", arguments: nil)
        #expect(result == expected)
        #expect(result.isError == true)
    }

    @Test("plays back scripted structuredContent verbatim")
    func playsBackScriptedStructuredContent() async throws {
        let mock = MockClient()
        let structured: Value = .object(["answer": .int(42)])
        let expected = CallTool.Result(content: [], structuredContent: structured as Value?)
        mock.script(expected)

        let result = try await mock.callTool(name: "tool", arguments: nil)
        #expect(result == expected)
        #expect(result.structuredContent == structured)
    }

    // MARK: - Playback: every Tool.Content case

    @Test("plays back scripted .text content verbatim")
    func playsBackTextContent() async throws {
        let mock = MockClient()
        let expected = CallTool.Result(content: [.text(text: "plain text", annotations: nil, _meta: nil)])
        mock.script(expected)

        let result = try await mock.callTool(name: "tool", arguments: nil)
        #expect(result == expected)
    }

    @Test("plays back scripted .image content verbatim")
    func playsBackImageContent() async throws {
        let mock = MockClient()
        let expected = CallTool.Result(content: [
            .image(data: "aGVsbG8=", mimeType: "image/png", annotations: nil, _meta: nil)
        ])
        mock.script(expected)

        let result = try await mock.callTool(name: "tool", arguments: nil)
        #expect(result == expected)
    }

    @Test("plays back scripted .audio content verbatim")
    func playsBackAudioContent() async throws {
        let mock = MockClient()
        let expected = CallTool.Result(content: [
            .audio(data: "aGVsbG8=", mimeType: "audio/mpeg", annotations: nil, _meta: nil)
        ])
        mock.script(expected)

        let result = try await mock.callTool(name: "tool", arguments: nil)
        #expect(result == expected)
    }

    @Test("plays back scripted .resource content verbatim")
    func playsBackResourceContent() async throws {
        let mock = MockClient()
        let resource = Resource.Content.text("file body", uri: "file:///notes.txt", mimeType: "text/plain")
        let expected = CallTool.Result(content: [.resource(resource: resource, annotations: nil, _meta: nil)])
        mock.script(expected)

        let result = try await mock.callTool(name: "tool", arguments: nil)
        #expect(result == expected)
    }

    @Test("plays back scripted .resourceLink content verbatim")
    func playsBackResourceLinkContent() async throws {
        let mock = MockClient()
        let expected = CallTool.Result(content: [
            .resourceLink(
                uri: "https://example.com/thing",
                name: "thing",
                title: "Thing",
                description: nil,
                mimeType: "text/html",
                annotations: nil
            )
        ])
        mock.script(expected)

        let result = try await mock.callTool(name: "tool", arguments: nil)
        #expect(result == expected)
    }

    // MARK: - FIFO ordering across multiple calls

    @Test("plays back multiple scripted results in FIFO order")
    func playsBackInFIFOOrder() async throws {
        let mock = MockClient()
        let first = CallTool.Result(content: [.text(text: "first", annotations: nil, _meta: nil)])
        let second = CallTool.Result(content: [.text(text: "second", annotations: nil, _meta: nil)])
        mock.script(first)
        mock.script(second)

        let result1 = try await mock.callTool(name: "tool", arguments: nil)
        let result2 = try await mock.callTool(name: "tool", arguments: nil)

        #expect(result1 == first)
        #expect(result2 == second)
    }

    // MARK: - Scripted throw

    @Test("plays back a scripted thrown error instead of a result")
    func playsBackScriptedThrow() async throws {
        struct DummyError: Error, Equatable {}
        let mock = MockClient()
        mock.script(throwing: DummyError())

        await #expect(throws: DummyError.self) {
            _ = try await mock.callTool(name: "tool", arguments: nil)
        }
    }

    // MARK: - Exhaustion

    @Test("throws a clear error when no scripted result remains")
    func throwsWhenScriptExhausted() async throws {
        let mock = MockClient()
        await #expect(throws: MockClientError.self) {
            _ = try await mock.callTool(name: "tool", arguments: nil)
        }
    }
}
