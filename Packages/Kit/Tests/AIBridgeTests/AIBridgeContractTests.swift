import Foundation
import Testing
@testable import AIBridge

@Suite("AIBridge contract")
struct AIBridgeContractTests {
    @Test func parserHandlesSplitLines() {
        var parser = StreamJSONParser()
        #expect(parser.feed(Data(#"{"type":"sys"#.utf8)).isEmpty)
        let events = parser.feed(Data("tem\",\"subtype\":\"hook_started\"}\n".utf8))
        #expect(events == [.unknown(type: "system", subtype: "hook_started")])
    }

    @Test func locatorRejectsMissingOverride() async {
        await #expect(throws: ClaudeLocatorError.self) {
            _ = try await ClaudeLocator.locate(override: URL(fileURLWithPath: "/nonexistent/claude"))
        }
    }
}
