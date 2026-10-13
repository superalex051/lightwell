import CleanupKit
import Foundation
import RulesKit
import ScanKit
import Testing
import TestSupport
@testable import AppCore

@Suite("Classification cache across rescans, async add of large folders", .serialized)
@MainActor
struct FixRoundTwoTests {
    @Test func fullRescanWithANewTreeNeverReusesOldClassifications() async throws {
        let fixture = try HomeFixture()
        defer { fixture.tearDown() }
        let model = EndToEndTests.liveModel(fixture)
        defer { model.shutdown() }
        let session = model.startScan(.folder(fixture.root))
        #expect(await waitUntil { session.state == .finished })
        let first = try #require(session.tree)
        let canonical = ScanSessionModel.canonicalRoot(fixture.root)
        let keychains = try #require(first.node(atPath: canonical + "/home/Library/Keychains"))
        session.selection = keychains
        #expect(session.cachedClassification(of: keychains)?.block != nil, "classified and cached on the first tree")

        // New content shifts what each id names; a full rescan installs a new tree object.
        _ = try fixture.fx.file("Aaa/first/early.bin", size: 4096)
        session.rescan(nil)
        #expect(await waitUntil { session.state == .finished && session.tree !== first })
        let second = try #require(session.tree)
        #expect(session.cachedClassification(of: keychains) == nil, "nothing cached for the old tree is reused")
        let expected = session.engine?.classify(path: second.path(keychains), resolveSymlinks: false).block
        #expect(session.classification(of: keychains)?.block == expected)
    }

    @Test func addingALargeFolderWalksOffTheMainActor() async throws {
        let fixture = try HomeFixture()
        defer { fixture.tearDown() }
        let tree = fixture.tree
        let home = try fixture.node("home")
        var inode: UInt64 = 70_000_000
        let big = tree.addDirectory("Big", under: home, identity: FileIdentity(device: 1, inode: inode))
        for index in 0..<3_000 {
            inode += 1
            let folder = tree.addDirectory("d\(index)", under: big, identity: FileIdentity(device: 1, inode: inode))
            inode += 1
            tree.addFile("f.bin", size: 4096, under: folder, identity: FileIdentity(device: 1, inode: inode))
        }
        inode += 1
        let library = tree.addDirectory("Holiday.photoslibrary", under: big, flags: .package, identity: FileIdentity(device: 1, inode: inode))
        inode += 1
        tree.addFile("db", size: 4096, under: library, identity: FileIdentity(device: 1, inode: inode))
        _ = tree.size(tree.root)
        let app = try await AppHarness(fixture: fixture)
        #expect(app.session.cachedClassification(of: big) == nil, "not classified yet")

        let result = await app.model.cleanup.queue(tree.summary(of: big), source: .user)
        guard case .added = result else { Issue.record("not added: \(result)"); return }
        let item = try #require(app.model.cleanup.queue.first)
        #expect(item.risk == .dangerous)
        #expect(!item.isSelected)
        #expect(app.model.cleanup.nestedDangerousPaths(of: item) == [tree.path(library)])
        // A protected folder is still refused through the async path.
        let keychains = try fixture.node("home/Library/Keychains")
        guard case .blocked = await app.model.cleanup.queue(tree.summary(of: keychains), source: .user) else { Issue.record("Keychains queued"); return }
    }

    @Test func uiTestScratchLivesInsideTheFixtureAndIsNotScanned() async throws {
        let fixture = try HomeFixture()
        defer { fixture.tearDown() }
        let options = AppLaunchOptions(isUITestMode: true, fixtureRoot: fixture.root, fakeClaude: nil)
        let model = AppModel.live(launchOptions: options, defaults: UserDefaults(suiteName: "com.alexluncan.lightwell.tests.unused")!)
        let scratch = AppModel.uiTestScratch(for: URL(fileURLWithPath: ScanSessionModel.canonicalRoot(fixture.root)))
        #expect(scratch.deletingLastPathComponent().path == ScanSessionModel.canonicalRoot(fixture.root))
        try FileManager.default.createDirectory(at: scratch.appendingPathComponent("assistant"), withIntermediateDirectories: true)
        _ = FileManager.default.createFile(atPath: scratch.appendingPathComponent("assistant/threads.json").path, contents: Data(repeating: 1, count: 9000))
        #expect(model.scanServices().excludedPaths.contains(scratch.path))
        let session = model.startScan(.folder(fixture.root))
        #expect(await waitUntil { session.state == .finished })
        let tree = try #require(session.tree)
        #expect(tree.node(atPath: scratch.path) == nil, "the app's own files are not part of the scan")
        model.shutdown()
        #expect(!FileManager.default.fileExists(atPath: scratch.path), "removed when the app quits")
    }
}
