import Foundation
import FoundationModels
import FoundationModelsMCP
import MCP

/// Pure, testable rendering for ``ToolCatalog``/``ToolDescriptor`` — the
/// human-readable output shared by `Examples/CatalogBrowser` (a full per-tool
/// field dump, the M8 surface named in `plan.md`'s Examples §6) and
/// `Examples/DynamicToolset` (a per-snapshot summary plus a
/// ``ToolCatalogDiff`` printout, per Examples §7).
///
/// Kept as its own file in this shared support library — not inline in either
/// executable — so `Tests/FoundationModelsMCPTests/ExampleHelperTests.swift`
/// can exercise every formatting rule directly, with no live model and no
/// spawned subprocess.
public enum CatalogFormatting {

    // MARK: - CatalogBrowser: full per-tool field dump

    /// Renders every catalog-facing field ``ToolDescriptor`` exposes — name,
    /// title, description, every ``ToolAnnotations`` field, icons, the raw
    /// `inputSchema` (as sorted-key JSON), the converted `GenerationSchema`,
    /// and the content fingerprint — one line per field, in a fixed order.
    ///
    /// - Parameter descriptor: The tool to render.
    /// - Returns: One line per field.
    public static func describe(_ descriptor: ToolDescriptor) -> [String] {
        var lines: [String] = [
            "name: \(descriptor.name)",
            "title: \(descriptor.title ?? "<none>")",
            "description: \(descriptor.description)",
        ]
        lines.append(contentsOf: describe(annotations: descriptor.annotations))
        lines.append("icons: \(describe(icons: descriptor.icons))")
        lines.append("inputSchema: \(jsonString(for: descriptor.inputSchema))")
        lines.append("parameters (GenerationSchema name): \(descriptor.parameters.name)")
        lines.append("parameters (GenerationSchema detail): \(String(reflecting: descriptor.parameters))")
        lines.append("fingerprint: \(descriptor.fingerprint)")
        return lines
    }

    /// Renders every ``ToolAnnotations`` field, one line each — including
    /// unset hints, named by their implicit MCP-spec default rather than
    /// silently omitted.
    ///
    /// - Parameter annotations: The tool's operational hints.
    /// - Returns: One line per annotation field.
    private static func describe(annotations: ToolAnnotations) -> [String] {
        [
            "annotations.title: \(annotations.title ?? "<none>")",
            "annotations.readOnlyHint: \(describe(hint: annotations.readOnlyHint))",
            "annotations.destructiveHint: \(describe(hint: annotations.destructiveHint))",
            "annotations.idempotentHint: \(describe(hint: annotations.idempotentHint))",
            "annotations.openWorldHint: \(describe(hint: annotations.openWorldHint))",
        ]
    }

    /// Renders one optional annotation hint.
    ///
    /// - Parameter hint: The hint value, or `nil` if the server declared
    ///   none.
    /// - Returns: `hint`'s `Bool` value rendered as text, or `"<unset>"`.
    private static func describe(hint: Bool?) -> String {
        hint.map(String.init(describing:)) ?? "<unset>"
    }

    /// Renders every icon's `src`, `mimeType`, and `sizes`.
    ///
    /// - Parameter icons: The tool's declared icons.
    /// - Returns: A semicolon-joined summary of every icon, or `"<none>"` if
    ///   `icons` is empty.
    private static func describe(icons: [MCP.Icon]) -> String {
        guard !icons.isEmpty else { return "<none>" }
        return icons.map { icon in
            let mimeType = icon.mimeType ?? "<unspecified mime type>"
            let sizes = icon.sizes?.joined(separator: ",") ?? "any"
            return "\(icon.src) (\(mimeType), sizes: \(sizes))"
        }.joined(separator: "; ")
    }

    /// Renders a `Value` as sorted-key JSON text, for deterministic, diffable
    /// output.
    ///
    /// A small re-implementation of `ToolContentRenderer.jsonString(for:)`,
    /// which is internal to the `FoundationModelsMCP` module and so isn't
    /// reachable from this cross-module support library.
    ///
    /// - Parameter value: The value to render.
    /// - Returns: Sorted-key JSON text, or `value`'s own `description` if
    ///   encoding fails.
    private static func jsonString(for value: Value) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value),
            let string = String(data: data, encoding: .utf8)
        else {
            return String(describing: value)
        }
        return string
    }

    // MARK: - DynamicToolset: snapshot + diff summaries

    /// Renders one ``ToolCatalog`` snapshot's header: its server identity,
    /// epoch, readiness state, and current tool names — the line
    /// `Examples/DynamicToolset` prints for every snapshot it observes from
    /// `MCPServer/catalogUpdates`.
    ///
    /// - Parameter snapshot: The snapshot to summarize.
    /// - Returns: A single summary line.
    public static func summarize(_ snapshot: ToolCatalog) -> String {
        let toolNames = snapshot.tools.map(\.name).sorted().joined(separator: ", ")
        return
            "[\(snapshot.identity.name)] epoch \(snapshot.epoch) (\(describe(state: snapshot.state))): [\(toolNames)]"
    }

    /// Renders an ``MCPServerState`` for ``summarize(_:)``.
    ///
    /// - Parameter state: The state to render.
    /// - Returns: A short, human-readable label.
    private static func describe(state: MCPServerState) -> String {
        switch state {
        case .connecting: return "connecting"
        case .ready: return "ready"
        case .faulted(let reason): return "faulted: \(reason)"
        }
    }

    /// Renders one ``ToolCatalogDiff``: every added, removed, and
    /// fingerprint-changed tool, one line each.
    ///
    /// - Parameter diff: The diff to summarize.
    /// - Returns: One line per changed tool, in added/removed/changed order;
    ///   empty if `diff` describes no change.
    public static func summarize(_ diff: ToolCatalogDiff) -> [String] {
        var lines: [String] = []
        lines.append(contentsOf: diff.added.map { "  + added: \($0.name)" })
        lines.append(contentsOf: diff.removed.map { "  - removed: \($0.name)" })
        lines.append(
            contentsOf: diff.changed.map {
                "  ~ changed: \($0.after.name) (fingerprint \($0.before.fingerprint) -> \($0.after.fingerprint))"
            })
        return lines
    }
}
