import Testing
@testable import AppCore
import ScanKit

@Suite("AppCore preview stores")
@MainActor
struct AppCoreContractTests {
    @Test func previewScanReachesExplore() throws {
        let model = AppModel.preview()
        #expect(model.activeSession == nil)
        let session = model.startScan(.volume(PreviewData.volume))
        #expect(session.state == .finished)
        let tree = try #require(session.tree)
        #expect(tree.children(tree.root).count >= 3)
        #expect(!session.categories.isEmpty)
        let users = try #require(tree.node(atPath: "/Users"))
        session.navigate(to: users)
        #expect(session.breadcrumb.count == 2)
        session.goBack()
        #expect(session.current == tree.root)
        session.goForward()
        #expect(session.current == users)
    }

    @Test func previewCleanupRunSimulatesWithoutFiles() async {
        let model = AppModel.preview()
        let selected = model.cleanup.selectedCount
        await model.cleanup.run(mode: .trash)
        #expect(model.cleanup.lastReport?.succeeded.count == selected)
        #expect(model.cleanup.queue.allSatisfy { !$0.isSelected })
    }

    @Test func previewChatHasProposalAndTools() {
        let items = PreviewData.chat
        #expect(items.contains { if case .proposal = $0.kind { true } else { false } })
        #expect(items.contains { if case .tool = $0.kind { true } else { false } })
    }

    @Test func previewTreeMatchesPathsOnComponentBoundaries() {
        let tree = PreviewTree(rootPath: "/x", entries: [.folder("a", [.file("b", 5)]), .file("yz", 1)])
        #expect(tree.node(atPath: "/x") == tree.root)
        #expect(tree.node(atPath: "/x/a/b").map(tree.name) == "b")
        #expect(tree.node(atPath: "/xyz") == nil)
        #expect(tree.node(atPath: "/xa/b") == nil)
        #expect(tree.children(tree.root).map(tree.name) == ["a", "yz"])

        let volume = PreviewTree(rootPath: "/", entries: [.folder("Users", [])])
        #expect(volume.node(atPath: "/Users").map(volume.name) == "Users")
    }
}

