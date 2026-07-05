import Foundation
import Testing

/// Proves the acceptance criterion that `README.md`'s quick-start listing is
/// the actual `Examples/EchoTool/EchoTool.swift` source, not a hand-copied
/// snippet that can silently drift out of sync with it.
///
/// Locates both files relative to this test file's own path (rather than
/// assuming a working directory), extracts the fenced code block `README.md`
/// wraps between its `ECHOTOOL-SNIPPET` HTML-comment markers, and asserts it
/// is character-for-character identical to `EchoTool.swift`'s contents.
@Suite("ReadmeQuickStart")
struct ReadmeQuickStartTests {

    /// The repository root, three directories above this test file
    /// (`Tests/FoundationModelsMCPTests/` → `Tests/` → repo root).
    private static var repositoryRootURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static var readmeURL: URL {
        repositoryRootURL.appendingPathComponent("README.md", isDirectory: false)
    }

    private static var echoToolURL: URL {
        repositoryRootURL
            .appendingPathComponent("Examples", isDirectory: true)
            .appendingPathComponent("EchoTool", isDirectory: true)
            .appendingPathComponent("EchoTool.swift", isDirectory: false)
    }

    /// The HTML comment marking the start of the embedded snippet, on its own
    /// line, immediately followed by the opening ` ```swift ` fence.
    private static let snippetStartMarker = "<!-- ECHOTOOL-SNIPPET:START -->\n```swift\n"

    /// The closing fence, immediately followed by the HTML comment marking
    /// the end of the embedded snippet.
    ///
    /// Deliberately has no leading `\n` of its own: the snippet's last line
    /// (`}`) already ends with the newline that terminates it in the source
    /// file, and that same newline is the one separating it from this fence
    /// in `README.md` — consuming a second one here would make the extracted
    /// snippet one newline short of `EchoTool.swift`'s own trailing newline.
    private static let snippetEndMarker = "```\n<!-- ECHOTOOL-SNIPPET:END -->"

    private struct MarkerNotFound: Error, CustomStringConvertible {
        var description: String {
            "README.md is missing the ECHOTOOL-SNIPPET:START/END marker pair around its quick-start code fence"
        }
    }

    /// Extracts the exact text between the opening and closing snippet
    /// markers in `readme`.
    ///
    /// - Parameter readme: The full contents of `README.md`.
    /// - Returns: The fenced block's contents, excluding the fence markers
    ///   and the surrounding HTML comments.
    /// - Throws: ``MarkerNotFound`` if either marker is absent.
    private static func extractSnippet(from readme: String) throws -> String {
        guard let startRange = readme.range(of: snippetStartMarker),
            let endRange = readme.range(
                of: snippetEndMarker, range: startRange.upperBound..<readme.endIndex)
        else {
            throw MarkerNotFound()
        }
        return String(readme[startRange.upperBound..<endRange.lowerBound])
    }

    @Test("README.md's quick-start snippet is exactly Examples/EchoTool/EchoTool.swift")
    func quickStartMatchesEchoToolSource() throws {
        let readme = try String(contentsOf: Self.readmeURL, encoding: .utf8)
        let echoToolSource = try String(contentsOf: Self.echoToolURL, encoding: .utf8)

        let snippet = try Self.extractSnippet(from: readme)

        #expect(snippet == echoToolSource)
    }
}
