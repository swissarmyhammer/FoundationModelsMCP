import Foundation
import Testing

@testable import FoundationModelsMCP
import FoundationModels
import MCP
import MCPTestServer

/// Coverage for the catalog value types added in `ToolCatalog.swift`:
/// ``ToolDescriptor``'s content-derived ``ToolDescriptor/fingerprint``,
/// ``ToolCatalog/diff(from:)``'s add/remove/change classification, and the
/// `Sendable` conformance every catalog type must hold with no
/// reference-type leakage.
///
/// Live-discovery behavior (``MCPServer/catalog``'s epoch incrementing
/// across reconnects, the `catalogUpdates` stream, coalesced
/// `list_changed` re-listing) is out of scope here — that's the next task's
/// `LiveCatalogTests.swift`. This suite only proves the plain value types
/// themselves: constructed directly from `MCP.Tool` literals, with no live
/// server involved except for the one `MCPServer.catalog` smoke test at the
/// bottom.
@Suite("CatalogType")
struct CatalogTypeTests {

    /// A minimal object-shaped `inputSchema` — one required string property —
    /// used by every test that doesn't care about schema shape beyond "some
    /// object", mirroring ``MCPToolTests``'s own fixture.
    private static let simpleInputSchema: Value = .object([
        "type": .string("object"),
        "properties": .object([
            "message": .object(["type": .string("string")])
        ]),
        "required": .array([.string("message")]),
    ])

    /// A second, structurally different object-shaped `inputSchema` — a
    /// different required property — used by tests proving the fingerprint
    /// is sensitive to a schema change under the same tool name.
    private static let differentInputSchema: Value = .object([
        "type": .string("object"),
        "properties": .object([
            "count": .object(["type": .string("integer")])
        ]),
        "required": .array([.string("count")]),
    ])

    /// Builds an `MCP.Tool` fixture, defaulting to ``simpleInputSchema``.
    ///
    /// - Parameters:
    ///   - name: The tool's name. Defaults to `"search"`.
    ///   - inputSchema: The tool's raw `inputSchema`. Defaults to
    ///     ``simpleInputSchema``.
    ///   - annotations: The tool's annotations. Defaults to empty.
    /// - Returns: The constructed `MCP.Tool`.
    private static func makeTool(
        name: String = "search",
        inputSchema: Value = simpleInputSchema,
        annotations: MCP.Tool.Annotations = nil
    ) -> MCP.Tool {
        MCP.Tool(
            name: name,
            description: "Searches things",
            inputSchema: inputSchema,
            annotations: annotations
        )
    }

    // MARK: - Fingerprint stability

    @Test("fingerprint is equal for two descriptors built from identical name, inputSchema, and annotations")
    func fingerprintStableForIdenticalDescriptors() throws {
        let first = try ToolDescriptor(tool: Self.makeTool())
        let second = try ToolDescriptor(tool: Self.makeTool())

        #expect(first.fingerprint == second.fingerprint)
    }

    @Test("fingerprint is stable across repeated computation, not just repeated construction")
    func fingerprintStableAcrossRepeatedComputation() throws {
        let tool = Self.makeTool()
        let fingerprints = try (0..<5).map { _ in try ToolDescriptor(tool: tool).fingerprint }

        #expect(Set(fingerprints).count == 1)
    }

    // MARK: - Fingerprint sensitivity

    @Test("fingerprint differs when only the inputSchema changes, with the same name")
    func fingerprintDiffersWhenInputSchemaChanges() throws {
        let unchanged = try ToolDescriptor(tool: Self.makeTool(inputSchema: Self.simpleInputSchema))
        let changed = try ToolDescriptor(tool: Self.makeTool(inputSchema: Self.differentInputSchema))

        #expect(unchanged.name == changed.name)
        #expect(unchanged.fingerprint != changed.fingerprint)
    }

    @Test("fingerprint differs when only annotations change, with the same name and inputSchema")
    func fingerprintDiffersWhenAnnotationsChange() throws {
        let readOnly = try ToolDescriptor(
            tool: Self.makeTool(annotations: MCP.Tool.Annotations(readOnlyHint: true)))
        let destructive = try ToolDescriptor(
            tool: Self.makeTool(annotations: MCP.Tool.Annotations(destructiveHint: true)))

        #expect(readOnly.name == destructive.name)
        #expect(readOnly.fingerprint != destructive.fingerprint)
    }

    @Test("fingerprint differs when only the name changes, with the same inputSchema")
    func fingerprintDiffersWhenNameChanges() throws {
        let first = try ToolDescriptor(tool: Self.makeTool(name: "search"))
        let second = try ToolDescriptor(tool: Self.makeTool(name: "find"))

        #expect(first.fingerprint != second.fingerprint)
    }

    // MARK: - diff(from:) classification

    @Test("diff(from:) classifies a tool present only in the newer snapshot as added")
    func diffClassifiesAddedTool() throws {
        let previous = try Self.makeCatalog(toolNames: ["alpha"])
        let current = try Self.makeCatalog(toolNames: ["alpha", "beta"])

        let delta = current.diff(from: previous)

        #expect(delta.added.map(\.name) == ["beta"])
        #expect(delta.removed.isEmpty)
        #expect(delta.changed.isEmpty)
    }

    @Test("diff(from:) classifies a tool present only in the older snapshot as removed")
    func diffClassifiesRemovedTool() throws {
        let previous = try Self.makeCatalog(toolNames: ["alpha", "beta"])
        let current = try Self.makeCatalog(toolNames: ["alpha"])

        let delta = current.diff(from: previous)

        #expect(delta.removed.map(\.name) == ["beta"])
        #expect(delta.added.isEmpty)
        #expect(delta.changed.isEmpty)
    }

    @Test("diff(from:) classifies a same-named tool with a changed inputSchema as changed")
    func diffClassifiesChangedTool() throws {
        let previous = ToolCatalog(
            identity: ServerIdentity(name: "server"),
            epoch: 1,
            state: .ready,
            tools: [try ToolDescriptor(tool: Self.makeTool(name: "alpha", inputSchema: Self.simpleInputSchema))]
        )
        let current = ToolCatalog(
            identity: ServerIdentity(name: "server"),
            epoch: 2,
            state: .ready,
            tools: [try ToolDescriptor(tool: Self.makeTool(name: "alpha", inputSchema: Self.differentInputSchema))]
        )

        let delta = current.diff(from: previous)

        #expect(delta.changed.map(\.after.name) == ["alpha"])
        #expect(delta.added.isEmpty)
        #expect(delta.removed.isEmpty)
        #expect(delta.changed[0].before.fingerprint != delta.changed[0].after.fingerprint)
    }

    @Test("diff(from:) reports no changes between two snapshots with identical tools")
    func diffReportsNoChangesForIdenticalSnapshots() throws {
        let previous = try Self.makeCatalog(toolNames: ["alpha", "beta"])
        let current = try Self.makeCatalog(toolNames: ["alpha", "beta"])

        let delta = current.diff(from: previous)

        #expect(delta.added.isEmpty)
        #expect(delta.removed.isEmpty)
        #expect(delta.changed.isEmpty)
    }

    @Test("diff(from:) classifies add, remove, and change together in a single mixed snapshot")
    func diffClassifiesMixedDelta() throws {
        let previous = ToolCatalog(
            identity: ServerIdentity(name: "server"),
            epoch: 1,
            state: .ready,
            tools: [
                try ToolDescriptor(tool: Self.makeTool(name: "unchanged")),
                try ToolDescriptor(tool: Self.makeTool(name: "removed")),
                try ToolDescriptor(tool: Self.makeTool(name: "reschema", inputSchema: Self.simpleInputSchema)),
            ]
        )
        let current = ToolCatalog(
            identity: ServerIdentity(name: "server"),
            epoch: 2,
            state: .ready,
            tools: [
                try ToolDescriptor(tool: Self.makeTool(name: "unchanged")),
                try ToolDescriptor(tool: Self.makeTool(name: "reschema", inputSchema: Self.differentInputSchema)),
                try ToolDescriptor(tool: Self.makeTool(name: "added")),
            ]
        )

        let delta = current.diff(from: previous)

        #expect(delta.added.map(\.name) == ["added"])
        #expect(delta.removed.map(\.name) == ["removed"])
        #expect(delta.changed.map(\.after.name) == ["reschema"])
    }

    /// Builds a ``ToolCatalog`` snapshot with one echo-shaped tool per name in
    /// `toolNames`, all sharing ``simpleInputSchema``.
    ///
    /// - Parameter toolNames: The names of the tools to include, in order.
    /// - Returns: The constructed catalog.
    private static func makeCatalog(toolNames: [String]) throws -> ToolCatalog {
        ToolCatalog(
            identity: ServerIdentity(name: "server"),
            epoch: 1,
            state: .ready,
            tools: try toolNames.map { try ToolDescriptor(tool: Self.makeTool(name: $0)) }
        )
    }

    // MARK: - Sendable conformance (compile-time)

    /// Compile-time proof that every catalog type is `Sendable` with no
    /// reference-type leakage: this only compiles if the argument type truly
    /// conforms, so a regression that widens any catalog type's stored
    /// properties to something non-`Sendable` fails the *build*, not just an
    /// assertion.
    ///
    /// - Parameter value: Any `Sendable` value, discarded.
    private func requireSendable(_ value: some Sendable) {
        _ = value
    }

    @Test("ServerIdentity, ToolDescriptor, ToolCatalog, and ToolCatalogDiff are all Sendable")
    func catalogTypesAreSendable() throws {
        let descriptor = try ToolDescriptor(tool: Self.makeTool())
        let catalog = try Self.makeCatalog(toolNames: ["alpha"])
        let diff = catalog.diff(from: catalog)

        requireSendable(ServerIdentity(name: "server"))
        requireSendable(descriptor)
        requireSendable(catalog)
        requireSendable(diff)

        // Also provable by crossing an actual concurrency boundary: this
        // would fail to compile if any of these types weren't Sendable.
        Task {
            requireSendable(descriptor)
            requireSendable(catalog)
            requireSendable(diff)
        }
    }

    // MARK: - MCPServer.catalog

    @Test("MCPServer.catalog returns a snapshot of the currently-discovered tools after a successful connect")
    func serverCatalogReflectsDiscoveredTools() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let scripted = ScriptedServer()
        await scripted.addEchoTool(named: "echo")
        try await scripted.start(transport: serverTransport)

        let server = MCPServer(client: Client(name: "CatalogTypeTestClient", version: "1.0"))
        try await server.connect(transport: clientTransport)

        let catalog = try await server.catalog
        #expect(catalog.tools.map(\.name) == ["echo"])
        #expect(catalog.state == .ready)
        #expect(catalog.epoch == 1)
    }

    @Test("MCPServer.catalog throws before the first successful connect completes")
    func serverCatalogThrowsBeforeReady() async throws {
        let server = MCPServer(client: Client(name: "CatalogTypeTestClient", version: "1.0"))

        await #expect(throws: MCPServerError.self) {
            _ = try await server.catalog
        }
    }
}
