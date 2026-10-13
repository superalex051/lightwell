import Foundation
import Testing
import TestSupport
@testable import ScanKit

@Suite("ScanKit contract")
struct ScanKitContractTests {
    @Test func scannerFinishesOnAnEmptyFolder() async throws {
        let fx = try FixtureBuilder()
        defer { fx.tearDown() }
        let scanner = Scanner(ScanOptions(root: fx.root))
        var finished: ScanTree?
        for await event in scanner.start() {
            if case .finished(let tree) = event { finished = tree }
        }
        let tree = try #require(finished)
        #expect(tree.path(tree.root) == fx.root.path)
        #expect(tree.children(tree.root).isEmpty)
    }

    @Test func spaceSummaryClampsPurgeable() {
        let volume = VolumeInfo(url: URL(fileURLWithPath: "/"), name: "Disk", kind: .internalDisk, fsType: "apfs", capacity: 100, available: 40, availableImportant: 30)
        let summary = SpaceSummary.compute(volume, scanned: 50)
        #expect(summary.purgeable == 0)
        #expect(summary.used == 60)
        #expect(summary.hidden == 10)
    }
}
