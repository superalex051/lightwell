import Foundation
import Testing
@testable import IPCProtocol

@Suite("IPCProtocol envelope")
struct IPCProtocolContractTests {
    @Test func jsonValueRoundTripsIntegersExactly() throws {
        let value: JSONValue = ["bytes": .int(9_007_199_254_740_993), "ok": true, "name": "x", "ratio": 0.5, "none": nil]
        let data = try JSONEncoder().encode(value)
        #expect(try JSONDecoder().decode(JSONValue.self, from: data) == value)
    }

    @Test func requestEncodesAsSingleLine() throws {
        let line = try IPC.encodeLine(IPCRequest(id: 1, method: IPC.Method.ping.rawValue))
        #expect(line.last == 0x0A)
        #expect(line.dropLast().contains(0x0A) == false)
    }

    @Test func catalogListsEightTools() {
        #expect(ToolCatalog.all.count == 8)
    }
}
