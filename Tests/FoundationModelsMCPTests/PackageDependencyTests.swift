import Foundation
import Testing

/// Proves the acceptance criterion that the shipped `FoundationModelsMCP`
/// library target's dependency closure does not include `MCPTestServer`.
///
/// `MCPTestServer` is a test-fixture-only utility target (see
/// `Sources/MCPTestServer/ScriptedServer.swift`) meant for
/// `FoundationModelsMCPTests` and future `Examples/` executables — never for
/// the shipped library. There's no SwiftPM API to introspect a resolved
/// target graph from within a test binary, so this reads `Package.swift`
/// itself and asserts, at the source level, that the `FoundationModelsMCP`
/// target's `dependencies:` array never mentions `MCPTestServer`. That's a
/// deliberately narrow, textual check rather than a full CI dependency-graph
/// gate (out of scope for this task), but it fails loudly the moment anyone
/// adds `"MCPTestServer"` to that one target's dependency list.
@Suite("PackageDependency")
struct PackageDependencyTests {

    /// Locates the repository's `Package.swift`, three directories above
    /// this test file (`Tests/FoundationModelsMCPTests/` → `Tests/` →
    /// repo root).
    private static var packageManifestURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Package.swift", isDirectory: false)
    }

    /// Extracts the full, balanced-parenthesis source text of the first
    /// `.target(` or `.executableTarget(` call whose `name:` argument is
    /// exactly `targetName`, from `source`.
    ///
    /// Matching on `name: "<targetName>",` (comma and closing quote
    /// included) avoids `"FoundationModelsMCP"` accidentally matching the
    /// `"FoundationModelsMCPTests"` target. Parenthesis balancing (rather
    /// than a fixed line count) makes this robust to reformatting, as long
    /// as the manifest stays syntactically valid Swift.
    ///
    /// - Parameters:
    ///   - targetName: The exact target name to locate.
    ///   - source: The full `Package.swift` source text.
    /// - Returns: The target call's source text, from its opening
    ///   `.target(`/`.executableTarget(` through its matching `)`.
    private static func targetDeclaration(named targetName: String, in source: String) throws
        -> String
    {
        // Restrict the search to the `targets:` section so this doesn't
        // match the *product* declaration's `name: "FoundationModelsMCP",`
        // (products are declared earlier in the manifest, under
        // `products:`, and share the library target's name).
        guard let targetsSectionStart = source.range(of: "targets:") else {
            throw TargetNotFound(targetName: targetName)
        }
        let targetsSection = source[targetsSectionStart.lowerBound...]

        guard let nameRange = targetsSection.range(of: "name: \"\(targetName)\",") else {
            throw TargetNotFound(targetName: targetName)
        }

        let precedingText = source[source.startIndex..<nameRange.lowerBound]
        let openerCandidates = [".target(", ".executableTarget("]
        let openRange = openerCandidates
            .compactMap { precedingText.range(of: $0, options: .backwards) }
            .max { $0.lowerBound < $1.lowerBound }

        guard let openRange else {
            throw TargetNotFound(targetName: targetName)
        }

        var depth = 0
        var cursor = openRange.lowerBound
        var sawOpenParen = false
        while cursor < source.endIndex {
            let character = source[cursor]
            if character == "(" {
                depth += 1
                sawOpenParen = true
            } else if character == ")" {
                depth -= 1
            }
            cursor = source.index(after: cursor)
            if sawOpenParen && depth == 0 {
                break
            }
        }

        return String(source[openRange.lowerBound..<cursor])
    }

    private struct TargetNotFound: Error, CustomStringConvertible {
        let targetName: String
        var description: String { "No target declaration found for \"\(targetName)\" in Package.swift" }
    }

    @Test("FoundationModelsMCP library target's dependency list never mentions MCPTestServer")
    func libraryTargetExcludesTestServer() throws {
        let source = try String(contentsOf: Self.packageManifestURL, encoding: .utf8)
        let declaration = try Self.targetDeclaration(named: "FoundationModelsMCP", in: source)

        #expect(!declaration.contains("MCPTestServer"))
    }

    @Test("the library product only exposes the FoundationModelsMCP target")
    func libraryProductExposesOnlyLibraryTarget() throws {
        let source = try String(contentsOf: Self.packageManifestURL, encoding: .utf8)
        guard let productsRange = source.range(of: "products:"),
            let targetsRange = source.range(of: "targets:")
        else {
            Issue.record("Could not locate products:/targets: sections in Package.swift")
            return
        }

        let productsSection = source[productsRange.upperBound..<targetsRange.lowerBound]
        #expect(!productsSection.contains("MCPTestServer"))
    }

    // MARK: - Examples never import the test target

    /// The `Examples/` targets that are still declared literally in
    /// `Package.swift` (a bare `.target(name: "...", ...)` /
    /// `.executableTarget(name: "...", ...)` call), and so can be checked by
    /// ``targetDeclaration(named:in:)``'s textual `name: "<targetName>",`
    /// search.
    ///
    /// `EchoTool`/`FileAssistant`/`ToolPicking`/`RemoteHTTP` are
    /// *not* declared this way — they're generated from `exampleTargetSpecs`
    /// mapped through one shared `.executableTarget()` call, so there is no
    /// `name: "EchoTool",` text to find. Those four are covered instead by
    /// ``exampleTargetSpecsDeclaresExpectedNames()`` and
    /// ``exampleTargetsMapUsesSharedDependencies()`` below.
    private static let exampleTargetNames = [
        "ExampleSupport"
    ]

    @Test(
        "every literally-declared Examples/ target's dependency list never mentions MCPTestServer",
        arguments: exampleTargetNames
    )
    func exampleTargetExcludesTestServer(targetName: String) throws {
        let source = try String(contentsOf: Self.packageManifestURL, encoding: .utf8)
        let declaration = try Self.targetDeclaration(named: targetName, in: source)

        #expect(!declaration.contains("MCPTestServer"))
    }

    @Test("the shared exampleTargetDependencies constant (every Examples/ executableTarget's dependency list) never mentions MCPTestServer")
    func exampleTargetDependenciesConstantExcludesTestServer() throws {
        // `EchoTool`/`FileAssistant`/`ToolPicking`/`RemoteHTTP` each pass
        // `dependencies: exampleTargetDependencies` rather than spelling out
        // their dependency list inline, so ``exampleTargetExcludesTestServer(targetName:)``
        // above — which only inspects each target's own declaration text —
        // would not catch "MCPTestServer" added to that *shared* constant
        // instead of to an individual target. This checks the constant's own
        // declaration directly, closing that gap.
        let source = try String(contentsOf: Self.packageManifestURL, encoding: .utf8)
        guard let constantStart = source.range(of: "let exampleTargetDependencies"),
            let closingBracket = source[constantStart.upperBound...].range(of: "]")
        else {
            Issue.record("Could not locate the exampleTargetDependencies constant in Package.swift")
            return
        }

        let constantDeclaration = source[constantStart.lowerBound..<closingBracket.upperBound]
        #expect(!constantDeclaration.contains("MCPTestServer"))
    }

    /// The four `Examples/` executable targets generated from
    /// `exampleTargetSpecs` (rather than four hand-duplicated
    /// `.executableTarget()` blocks — see `Package.swift`).
    private static let generatedExampleTargetNames = [
        "EchoTool", "FileAssistant", "ToolPicking", "RemoteHTTP",
    ]

    @Test("exampleTargetSpecs declares exactly the four generated Examples/ targets")
    func exampleTargetSpecsDeclaresExpectedNames() throws {
        let source = try String(contentsOf: Self.packageManifestURL, encoding: .utf8)
        guard let specsStart = source.range(of: "let exampleTargetSpecs"),
            let closingBracket = source[specsStart.upperBound...].range(of: "\n]")
        else {
            Issue.record("Could not locate the exampleTargetSpecs constant in Package.swift")
            return
        }

        let specsDeclaration = source[specsStart.lowerBound..<closingBracket.upperBound]
        for name in Self.generatedExampleTargetNames {
            #expect(
                specsDeclaration.contains("\"\(name)\""),
                "exampleTargetSpecs is missing an entry for \"\(name)\"")
        }
    }

    @Test(
        "the exampleTargets map wires every generated target to the shared exampleTargetDependencies constant, never MCPTestServer directly"
    )
    func exampleTargetsMapUsesSharedDependencies() throws {
        let source = try String(contentsOf: Self.packageManifestURL, encoding: .utf8)
        guard let mapStart = source.range(of: "let exampleTargets: [Target]"),
            let closingBrace = source[mapStart.upperBound...].range(of: "\n}")
        else {
            Issue.record("Could not locate the exampleTargets map in Package.swift")
            return
        }

        let mapDeclaration = source[mapStart.lowerBound..<closingBrace.upperBound]
        #expect(mapDeclaration.contains("dependencies: exampleTargetDependencies"))
        #expect(!mapDeclaration.contains("MCPTestServer"))
    }

    /// Locates the repository's `Examples/` directory, two directories above
    /// this test file (`Tests/FoundationModelsMCPTests/` → `Tests/` → repo
    /// root → `Examples/`).
    private static var examplesDirectoryURL: URL {
        Self.packageManifestURL
            .deletingLastPathComponent()
            .appendingPathComponent("Examples", isDirectory: true)
    }

    /// Every `.swift` file under ``examplesDirectoryURL``, found recursively.
    ///
    /// - Returns: Each file's URL.
    private static func exampleSwiftFileURLs() throws -> [URL] {
        guard
            let enumerator = FileManager.default.enumerator(
                at: examplesDirectoryURL, includingPropertiesForKeys: nil)
        else {
            throw ExamplesDirectoryNotFound()
        }
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    private struct ExamplesDirectoryNotFound: Error, CustomStringConvertible {
        var description: String { "Could not enumerate the Examples/ directory" }
    }

    @Test("no file under Examples/ imports the MCPTestServer test-fixture target")
    func examplesNeverImportMCPTestServer() throws {
        for url in try Self.exampleSwiftFileURLs() {
            let contents = try String(contentsOf: url, encoding: .utf8)
            #expect(
                !contents.contains("import MCPTestServer"),
                "\(url.lastPathComponent) must not import the MCPTestServer test-fixture target"
            )
        }
    }

    @Test("no file under Examples/ uses @testable import")
    func examplesNeverUseTestableImport() throws {
        for url in try Self.exampleSwiftFileURLs() {
            let contents = try String(contentsOf: url, encoding: .utf8)
            #expect(
                !contents.contains("@testable import"),
                "\(url.lastPathComponent) must not use @testable import (examples never import the test target)"
            )
        }
    }
}
