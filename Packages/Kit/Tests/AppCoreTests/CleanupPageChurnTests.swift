import CleanupKit
import Foundation
import Observation
import RulesKit
import ScanKit
import Synchronization
import Testing
import TestSupport
@testable import AppCore

/// Live bug (2026-10-13): the Cleanup page re-rendered and reshaped its rows on every refresh of a
/// whole-disk scan (laggy scrolling, rows jumping). These pin what the page reads: a queued row's
/// texts do not depend on the session's categories (cleared by a root rescan, replaced by every
/// throttled re-categorization).
@Suite("Cleanup page under live refresh churn", .serialized)
@MainActor
struct CleanupPageChurnTests {
    final class Flag: Sendable {
        private let value = Atomic<Bool>(false)
        var fired: Bool { value.load(ordering: .relaxed) }
        func fire() { value.store(true, ordering: .relaxed) }
    }

    /// Runs `read` under observation tracking and reports whether a later change touched it.
    static func track(_ read: () -> Void) -> Flag {
        let flag = Flag()
        withObservationTracking(read) { flag.fire() }
        return flag
    }

    @Test func queuedRowTextsSurviveARootRescanUnchanged() async throws {
        let fixture = try HomeFixture()
        defer { fixture.tearDown() }
        let tree = EpochTree(fixture.tree)
        let app = try await AppHarness(fixture: fixture, tree: tree)
        let session = app.session
        let category = try #require(session.categories.first { $0.ruleID == "xcode.deriveddata" })
        app.model.cleanup.add(category: category, tree: tree)
        let item = try #require(app.model.cleanup.queue.first)
        let title = session.sourceTitle(of: item)
        let explanation = session.explanation(of: item)
        #expect(title == category.title)
        #expect(explanation == category.explanation)

        let flag = Self.track {
            _ = session.sourceTitle(of: item)
            _ = session.explanation(of: item)
        }
        // A full root rescan lands: categories are dropped until the next walk.
        tree.adopt(try InMemoryTree.snapshot(of: fixture.root))
        session.restructured()
        #expect(session.categories.isEmpty)
        #expect(session.sourceTitle(of: item) == title, "the row's badge changed while categories were rebuilt")
        #expect(session.explanation(of: item) == explanation)
        #expect(!flag.fired, "the row re-rendered because the session's categories changed")
    }
}
