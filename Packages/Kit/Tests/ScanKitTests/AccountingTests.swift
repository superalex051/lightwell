import Foundation
import Testing
import TestSupport
@testable import ScanKit

/// PLAN 5.1 "Accounting" plus the firmlinks parser and the volume catalog.
@Suite("Accounting and volumes")
struct AccountingTests {
    private func volume(capacity: UInt64, available: UInt64, important: UInt64, other: UInt64 = 0) -> VolumeInfo {
        VolumeInfo(
            url: URL(fileURLWithPath: "/"), name: "Disk", kind: .internalDisk, fsType: "apfs",
            capacity: capacity, available: available, availableImportant: important, otherVolumes: other
        )
    }

    struct Case: Sendable, CustomTestStringConvertible {
        var capacity: UInt64, available: UInt64, important: UInt64, other: UInt64, scanned: UInt64
        var used: UInt64, free: UInt64, purgeable: UInt64, otherVolumes: UInt64, hidden: UInt64
        var testDescription: String { "cap \(capacity) avail \(available) imp \(important) other \(other) scanned \(scanned)" }
    }

    @Test(arguments: [
        // Purgeable = important - free.
        Case(capacity: 1000, available: 200, important: 350, other: 0, scanned: 500, used: 800, free: 200, purgeable: 150, otherVolumes: 0, hidden: 300),
        // Purgeable 0 when important is below free.
        Case(capacity: 1000, available: 200, important: 100, other: 0, scanned: 500, used: 800, free: 200, purgeable: 0, otherVolumes: 0, hidden: 300),
        // important = 0 (unknown) means no purgeable.
        Case(capacity: 1000, available: 200, important: 0, other: 0, scanned: 500, used: 800, free: 200, purgeable: 0, otherVolumes: 0, hidden: 300),
        // Other volumes reduce hidden.
        Case(capacity: 1000, available: 200, important: 200, other: 120, scanned: 500, used: 800, free: 200, purgeable: 0, otherVolumes: 120, hidden: 180),
        // Hidden clamps at 0 when scanned + other exceed used (clones counted in full, for example).
        Case(capacity: 1000, available: 200, important: 200, other: 120, scanned: 900, used: 800, free: 200, purgeable: 0, otherVolumes: 120, hidden: 0),
        // Available above capacity clamps free.
        Case(capacity: 1000, available: 5000, important: 5000, other: 0, scanned: 0, used: 0, free: 1000, purgeable: 4000, otherVolumes: 0, hidden: 0),
        // Other volumes never exceed used.
        Case(capacity: 1000, available: 900, important: 900, other: 500, scanned: 0, used: 100, free: 900, purgeable: 0, otherVolumes: 100, hidden: 0),
    ])
    func spaceSummaryTable(_ c: Case) {
        let summary = SpaceSummary.compute(volume(capacity: c.capacity, available: c.available, important: c.important, other: c.other), scanned: c.scanned)
        #expect(summary.capacity == c.capacity)
        #expect(summary.used == c.used)
        #expect(summary.free == c.free)
        #expect(summary.purgeable == c.purgeable)
        #expect(summary.otherVolumes == c.otherVolumes)
        #expect(summary.scanned == c.scanned)
        #expect(summary.hidden == c.hidden)
    }

    @Test func folderSummaryHasNoHiddenOrFree() {
        let summary = SpaceSummary.folder(scanned: 1234)
        #expect(summary.scanned == 1234)
        #expect(summary.hidden == 0)
        #expect(summary.free == 0)
    }

    @Test func firmlinksParser() {
        let text = "/AppleInternal\tAppleInternal\n/Users\tUsers\n\n# comment line\n/System/Library/Caches\tSystem/Library/Caches\nbroken line\n/usr/local\tusr/local\n"
        let parsed = Firmlinks.parse(text)
        #expect(parsed.map(\.source) == ["/AppleInternal", "/Users", "/System/Library/Caches", "/usr/local"])
        #expect(parsed.map(\.target) == ["AppleInternal", "Users", "System/Library/Caches", "usr/local"])
    }

    @Test func firmlinkSkipSetUsesTheDataVolume() throws {
        let fx = try FixtureBuilder()
        defer { fx.tearDown() }
        try fx.dir("data/Users")
        try fx.dir("data/Library")
        let list = try fx.url("firmlinks")
        try Data("/Users\tUsers\n/Library\tLibrary\n/Missing\tMissing\n".utf8).write(to: list)
        let skip = Firmlinks.skipSet(dataVolume: try fx.path("data"), file: list.path)
        #expect(skip.count == 2)
        var info = stat()
        #expect(lstat(try fx.path("data/Users"), &info) == 0)
        #expect(skip.contains(FileIdentity(device: info.st_dev, inode: UInt64(info.st_ino))))
    }

    @Test func volumeCatalogListsTheStartupVolume() throws {
        let volumes = VolumeCatalog.current()
        let root = try #require(volumes.first)
        #expect(root.url.path == "/")
        #expect(root.capacity > 0)
        #expect(root.capacity >= root.available)
        #expect(root.kind == .internalDisk)
        #expect(root.fsType == "apfs")
        // APFS siblings (Data, Preboot, VM, ...) are folded into the startup volume.
        #expect(!volumes.contains { $0.url.path.hasPrefix("/System/Volumes/") })
        let summary = SpaceSummary.compute(root, scanned: 0)
        #expect(summary.used + summary.free == summary.capacity)
    }

    @Test func volumeContainingAFixture() throws {
        let fx = try FixtureBuilder()
        defer { fx.tearDown() }
        let volume = try #require(VolumeCatalog.volume(containing: fx.root))
        #expect(volume.url.path == "/")
    }

    @Test func volumeInfoDecodesWithoutOtherVolumes() throws {
        let original = VolumeInfo(url: URL(fileURLWithPath: "/"), name: "Disk", kind: .internalDisk, fsType: "apfs", capacity: 10, available: 5, availableImportant: 6, otherVolumes: 3)
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(VolumeInfo.self, from: data) == original)
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "otherVolumes")
        let legacy = try JSONDecoder().decode(VolumeInfo.self, from: try JSONSerialization.data(withJSONObject: object))
        #expect(legacy.otherVolumes == 0)
    }

    @Test func itemSummaryRoundTripsIdentity() throws {
        let item = ItemSummary(nodeID: 3, path: "/a", name: "a", bytes: 1, freesAbout: 1, kind: .file, items: 0, identity: FileIdentity(device: 1, inode: 2))
        let decoded = try JSONDecoder().decode(ItemSummary.self, from: try JSONEncoder().encode(item))
        #expect(decoded == item)
    }

    /// Real root scan (PLAN WS1 acceptance), gated: reads the whole disk.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LIGHTWELL_TEST_REAL_ROOT"] == "1"))
    func realRootScanHasNoFirmlinkDuplicates() async throws {
        let tree = try await scanTree(URL(fileURLWithPath: "/"), workers: nil, countClonesOnce: true)
        if let dataUsers = tree.node(atPath: "/System/Volumes/Data/Users") {
            #expect(tree.flags(dataUsers).contains(.firmlinkSkipped))
            #expect(tree.size(dataUsers) == 0)
        }
        let users = try #require(tree.node(atPath: "/Users"))
        #expect(tree.size(users) > 0)
        let volume = try #require(VolumeCatalog.volume(containing: URL(fileURLWithPath: "/")))
        let summary = SpaceSummary.compute(volume, scanned: tree.size(tree.root))
        let accounted = Double(summary.scanned + summary.hidden + summary.otherVolumes)
        #expect(abs(accounted - Double(summary.used)) <= Double(summary.used) * 0.005)
    }
}
