import Testing

@testable import FoundationModelsMCP
import MCP

/// Proves the package links against both `FoundationModelsMCP` (this library)
/// and the `MCP` product from swift-sdk in the same test binary.
@Suite("Smoke")
struct SmokeTests {
    @Test("package links against FoundationModelsMCP and MCP")
    func linkage() {
        #expect(true)
    }
}
