import CleanupKit
import Foundation
import IPCProtocol
import RulesKit
import ScanKit
import Testing
import TestSupport
@testable import AppCore

/// Task 9 item 5: an assistant folder proposal never absorbs the user's rows.
@Suite("Assistant proposals keep the user's rows", .serialized)
@MainActor
struct FinalReviewQueueTests {
    // MARK: Item 5: assistant folders never absorb the user's rows

    @Test func assistantFolderProposalKeepsTheUsersRows() async throws {
        let fixture = try HomeFixture()
        defer { fixture.tearDown() }
        let app = try await AppHarness(fixture: fixture)
        let cleanup = app.model.cleanup
        let tree = fixture.tree
        let modules = try fixture.node("home/Projects/web/node_modules")
        guard case .added(let mine) = cleanup.add(tree.summary(of: modules), source: .user) else { Issue.record("not queued"); return }
        #expect(cleanup.queue.first?.isSelected == true)

        let result = try app.decode(ProposeDeletionResult.self, await app.call(.proposeDeletion, [
            "items": [["path": "~/Projects/web", "reason": "old project"]],
            "summary": "Old project",
        ]))
        #expect(result.queued.isEmpty)
        #expect(result.rejected.map(\.code) == ["contains_user_items"])
        #expect(result.rejected.first?.message.contains("~/Projects/web/node_modules") == true, "the model sees which rows are the user's")
        #expect(cleanup.queue.map(\.id) == [mine], "the user's row stays")
        #expect(cleanup.queue.first?.isSelected == true, "with its tick")
        #expect(cleanup.queue.first?.source == .user)
    }

    @Test func assistantFolderAbsorbsOnlyUntickedAssistantRows() {
        func item(_ path: String, _ source: QueueSource, selected: Bool) -> QueueItem {
            QueueItem(path: path, bytes: 10, freesAbout: 10, risk: .review, source: source, isSelected: selected)
        }
        let thread = UUID()
        let assistant = QueueSource.assistant(thread: thread, reason: "r")
        var queue = CleanupQueue()
        queue.add(item("/h/a/one", assistant, selected: false))
        guard case .added = queue.add(item("/h/a", assistant, selected: false)) else { Issue.record("assistant folder refused"); return }
        #expect(queue.items.map(\.path) == ["/h/a"], "an unticked assistant row is absorbed")

        var ticked = CleanupQueue()
        ticked.add(item("/h/b/one", assistant, selected: false))
        let id = ticked.items[0].id
        ticked.setSelected(id, true)
        #expect(ticked.add(item("/h/b", assistant, selected: false)) == .containsUserItems(["/h/b/one"]), "a row the user ticked is the user's")
        #expect(ticked.items.map(\.isSelected) == [true])

        var category = CleanupQueue()
        category.add(item("/h/c/one", .category("caches.user"), selected: false))
        #expect(category.add(item("/h/c", assistant, selected: false)) == .containsUserItems(["/h/c/one"]))

        // The user's own folder still absorbs everything inside it, as before.
        var users = CleanupQueue()
        users.add(item("/h/d/one", assistant, selected: false))
        users.add(item("/h/d/two", .user, selected: true))
        guard case .added = users.add(item("/h/d", .user, selected: true)) else { Issue.record("user folder refused"); return }
        #expect(users.items.map(\.path) == ["/h/d"])
    }
}
