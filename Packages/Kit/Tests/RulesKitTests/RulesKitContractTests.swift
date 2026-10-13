import Foundation
import Testing
@testable import RulesKit

@Suite("RulesKit contract")
struct RulesKitContractTests {
    @Test func riskIsOrdered() {
        #expect(Risk.safe < .review)
        #expect(Risk.review < .dangerous)
        #expect(Risk.dangerous < .never)
    }

    @Test func blockReasonsHaveMessages() {
        for reason in BlockReason.allCases {
            #expect(!reason.message.isEmpty)
        }
    }

    @Test func bundledRulesLoadAndValidate() throws {
        // Throws (and fails the test) on a missing, undecodable or invalid rules.json.
        let loaded = try RuleLoader.loadBundled()
        #expect(loaded.count >= 40)
        #expect(RuleValidator.validate(loaded).isEmpty)
        let bundled: [Rule] = .bundled
        #expect(bundled == loaded)
    }
}
