import Testing
@testable import MCPServerKit

@Suite("MCPServerKit contract stubs")
struct MCPServerKitContractTests {
    @Test func helperHasVersion() {
        #expect(!MCPHelperMain.version.isEmpty)
    }
}
