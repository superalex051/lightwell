import Foundation
import ScanKit
import Synchronization
import Testing
@testable import RulesKit
import TestSupport

@Suite("RuleEngine.categories cancellation")
struct CategoryCancellationTests {
    /// A home with many folders, so the walk polls the cancellation check several times.
    static func wideTree() -> InMemoryTree {
        let tree = CategoryTests.homeTree()
        let projects = tree.node(atPath: virtualHome + "/Projects")!
        for index in 0..<(RuleEngine.cancellationCheckInterval * 4) {
            let folder = tree.addDirectory("p\(index)", under: projects)
            tree.addFile("f", size: 1, under: folder)
        }
        return tree
    }

    @Test func notCancelledMatchesThePlainWalk() throws {
        let tree = Self.wideTree()
        let engine = RuleEngine(home: virtualHome, metadata: CategoryTests.metadata(), now: { fixedNow })
        let plain = engine.categories(in: tree)
        let polled = try #require(engine.categories(in: tree, isCancelled: { false }))
        #expect(polled == plain)
        #expect(!plain.isEmpty)
    }

    @Test func cancelledWalkStopsEarlyWithNil() {
        let tree = Self.wideTree()
        let engine = RuleEngine(home: virtualHome, metadata: CategoryTests.metadata(), now: { fixedNow })
        let polls = Atomic<Int>(0)
        let result = engine.categories(in: tree, isCancelled: {
            polls.wrappingAdd(1, ordering: .relaxed)
            return true
        })
        #expect(result == nil)
        #expect(polls.load(ordering: .relaxed) == 1, "the walk stops at the first poll")
    }

    @Test func cancellationInsideATaskIsSeen() async {
        let tree = Self.wideTree()
        let engine = RuleEngine(home: virtualHome, metadata: CategoryTests.metadata(), now: { fixedNow })
        let task = Task.detached { () -> [CategoryResult]? in
            withUnsafeCurrentTask { $0?.cancel() }
            return engine.categories(in: tree, isCancelled: { Task.isCancelled })
        }
        let result = await task.value
        #expect(result == nil)
    }
}
