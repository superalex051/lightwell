import CleanupKit
import Foundation
import IPCProtocol
import RulesKit
import ScanKit
import Testing
import TestSupport
@testable import AppCore

@Suite("MCP tool handler on a fixture scan", .serialized)
@MainActor
struct ToolHandlerTests {
    @Test func overviewDescribesTheScan() async throws {
        let fixture = try HomeFixture()
        defer { fixture.tearDown() }
        let app = try await AppHarness(fixture: fixture)
        let overview = try app.decode(DiskOverviewResult.self, await app.call(.getDiskOverview))
        #expect(overview.scannedRoot == fixture.root.path)
        #expect(overview.fda == "unknown")
        #expect(overview.scanAgeSeconds >= 0 && overview.scanAgeSeconds < 60)
        #expect(overview.hidden == 0 && overview.otherVolumes == 0, "folder scans have no hidden or other volume rows")
        #expect(overview.snapshotsCount == 0)
        #expect(overview.capacity > 0, "volume numbers come from the volume holding the folder")
    }

    @Test func largestItemsArePagedWithCursors() async throws {
        let fixture = try HomeFixture()
        defer { fixture.tearDown() }
        let app = try await AppHarness(fixture: fixture)
        let first = try app.decode(ToolItemList.self, await app.call(.getLargestItems, ["kind": "file", "limit": 2]))
        #expect(first.items.map(\.path) == ["~/Downloads/old-installer.dmg", "~/Library/Developer/Xcode/DerivedData/App-1/build.o"])
        #expect(first.items.allSatisfy { $0.kind == "file" })
        let cursor = try #require(first.nextCursor)
        let second = try app.decode(ToolItemList.self, await app.call(.getLargestItems, ["kind": "file", "limit": 2, "cursor": .string(cursor)]))
        #expect(second.items.first?.path == "~/Library/Developer/Xcode/DerivedData/App-2/index.db")
        #expect(Set(first.items.map(\.path)).isDisjoint(with: second.items.map(\.path)))

        let derived = try app.decode(ToolItemList.self, await app.call(.getLargestItems, ["path": "~/Library/Developer/Xcode/DerivedData", "scope": "children"]))
        #expect(derived.items.map(\.path) == ["~/Library/Developer/Xcode/DerivedData/App-1", "~/Library/Developer/Xcode/DerivedData/App-2"])
        #expect(derived.items.first?.ruleID == "xcode.deriveddata")
        #expect(derived.items.first?.risk == "safe")
        #expect(derived.nextCursor == nil)

        let big = try app.decode(ToolItemList.self, await app.call(.getLargestItems, ["min_bytes": 30_000, "kind": "file"]))
        #expect(big.items.map(\.path) == ["~/Downloads/old-installer.dmg", "~/Library/Developer/Xcode/DerivedData/App-1/build.o"])
    }

    @Test func largestMatchesABruteForceRanking() async throws {
        let fixture = try HomeFixture { fx in
            for index in 0..<40 { _ = try fx.file("home/Bulk/dir\(index % 7)/f\(index).bin", size: 4096 * (index + 1)) }
        }
        defer { fixture.tearDown() }
        let tree = fixture.tree
        for kind in [ItemKindFilter.any, .file, .directory] {
            let fast = ToolQueries.largest(in: tree, under: tree.root, count: 15, minBytes: 0, kind: kind, descendants: true)
            var all: [NodeID] = []
            var stack = [tree.root]
            while let node = stack.popLast() {
                for child in tree.children(node) {
                    if ToolQueries.matches(tree.flags(child), kind: kind) { all.append(child) }
                    if ToolQueries.descends(tree.flags(child)) { stack.append(child) }
                }
            }
            let slow = all.sorted { tree.size($0) != tree.size($1) ? tree.size($0) > tree.size($1) : $0 < $1 }.prefix(15)
            #expect(fast == Array(slow), "kind \(kind)")
        }
    }

    @Test func listChildrenSortsAndPages() async throws {
        let fixture = try HomeFixture { fx in
            try fx.manyFiles(in: "home/Many", count: 600, size: 4096)
        }
        defer { fixture.tearDown() }
        let app = try await AppHarness(fixture: fixture)
        let byName = try app.decode(ToolItemList.self, await app.call(.listChildren, ["path": "~", "sort": "name"]))
        #expect(byName.items.map { ($0.path as NSString).lastPathComponent } == ["Documents", "Downloads", "Library", "Many", "Pictures", "Projects"])

        var seen: [String] = []
        var cursor: String?
        repeat {
            var args: [String: JSONValue] = ["path": "~/Many", "limit": 200]
            if let cursor { args["cursor"] = .string(cursor) }
            let result = await app.call(.listChildren, .object(args))
            #expect(result.text.utf8.count <= ToolCatalog.maxResultBytes)
            let page = try app.decode(ToolItemList.self, result)
            seen += page.items.map(\.path)
            cursor = page.nextCursor
        } while cursor != nil
        #expect(seen.count == 600)
        #expect(Set(seen).count == 600)
    }

    @Test func staleCursorIsRejected() async throws {
        let fixture = try HomeFixture()
        defer { fixture.tearDown() }
        let app = try await AppHarness(fixture: fixture)
        let page = try app.decode(ToolItemList.self, await app.call(.getLargestItems, ["limit": 1]))
        let cursor = try #require(page.nextCursor)
        fixture.tree.addFile("new.bin", size: 4096, under: fixture.tree.root)
        let stale = await app.call(.getLargestItems, ["limit": 1, "cursor": .string(cursor)])
        #expect(stale.isError)
        #expect(stale.text.contains("older scan"))
    }

    @Test func searchByExtensionGlobAndAge() async throws {
        let fixture = try HomeFixture()
        defer { fixture.tearDown() }
        let old = Date(timeIntervalSince1970: 1_600_000_000)
        let metadata = ItemMetadata(
            modified: { $0.hasSuffix(".dmg") ? old : Date() },
            lastUsed: { _ in nil }, bundleID: { _ in nil }, linkCount: { _ in nil }
        )
        let app = try await AppHarness(fixture: fixture, metadata: metadata)
        let dmg = try app.decode(ToolItemList.self, await app.call(.searchItems, ["extension": ".DMG"]))
        #expect(dmg.items.map(\.path) == ["~/Downloads/old-installer.dmg"])
        let glob = try app.decode(ToolItemList.self, await app.call(.searchItems, ["name_glob": "*.o", "under": "~/Library"]))
        #expect(glob.items.map(\.path) == ["~/Library/Developer/Xcode/DerivedData/App-1/build.o"])
        let aged = try app.decode(ToolItemList.self, await app.call(.searchItems, ["under": "~/Downloads", "older_than_days": 30]))
        #expect(aged.items.map(\.path) == ["~/Downloads/old-installer.dmg"])
    }

    @Test func categorySummaryComesFromTheRules() async throws {
        let fixture = try HomeFixture()
        defer { fixture.tearDown() }
        let app = try await AppHarness(fixture: fixture)
        let summary = try app.decode(CategorySummaryResult.self, await app.call(.getCategorySummary))
        let derived = try #require(summary.categories.first { $0.ruleID == "xcode.deriveddata" })
        #expect(derived.risk == "safe")
        #expect(derived.count == 2)
        #expect(derived.action == "trash")
        #expect(summary.categories.contains { $0.ruleID == "caches.user" })
    }

    @Test func inspectReportsRiskAndProtection() async throws {
        let fixture = try HomeFixture()
        defer { fixture.tearDown() }
        let app = try await AppHarness(fixture: fixture)
        let derived = try app.decode(PathInspectionResult.self, await app.call(.inspectPath, ["path": "~/Library/Developer/Xcode/DerivedData/App-1"]))
        #expect(derived.risk == "safe")
        #expect(derived.ruleID == "xcode.deriveddata")
        #expect(!derived.protected)
        #expect(derived.kind == "directory")

        let keychains = try app.decode(PathInspectionResult.self, await app.call(.inspectPath, ["path": "~/Library/Keychains"]))
        #expect(keychains.protected)
        #expect(keychains.risk == "never")
        #expect(keychains.protectionReason?.isEmpty == false)

        let library = try app.decode(PathInspectionResult.self, await app.call(.inspectPath, ["path": "~/Pictures/Trip.photoslibrary"]))
        #expect(library.risk == "dangerous")
        #expect(!library.protected)
        #expect(library.kind == "package")

        let holder = try app.decode(PathInspectionResult.self, await app.call(.inspectPath, ["path": "~/Documents/Old"]))
        #expect(holder.risk == "dangerous")
        #expect(holder.explanation.contains("Family.photoslibrary"))

        let missing = await app.call(.inspectPath, ["path": "~/Nope"])
        #expect(missing.isError)
        #expect(missing.text.contains("not in the current scan"))
        let relative = await app.call(.inspectPath, ["path": "Library"])
        #expect(relative.isError)
    }

    @Test func proposeQueuesOnlySafeAndReviewItems() async throws {
        let fixture = try HomeFixture()
        defer { fixture.tearDown() }
        let app = try await AppHarness(fixture: fixture)
        let thread = UUID()
        app.model.assistant.newThread()
        let active = try #require(app.model.assistant.active)
        let items: [JSONValue] = [
            ["path": "~/Library/Developer/Xcode/DerivedData/App-1", "reason": "Xcode rebuilds it."],
            ["path": "~/Downloads/old-installer.dmg", "reason": "Installer already used."],
            ["path": "~/Library/Keychains/login.keychain-db", "reason": "bad idea"],
            ["path": "~/Pictures/Trip.photoslibrary", "reason": "big"],
            ["path": "~/Documents/Old", "reason": "old stuff"],
            ["path": "~/Nope", "reason": "not there"],
            ["path": "relative/path", "reason": "bad path"],
            ["path": .string(fixture.root.path), "reason": "everything"],
            ["path": "~/Library/Developer/Xcode/DerivedData/App-1", "reason": "again"],
        ]
        let result = await app.call(.proposeDeletion, ["items": .array(items), "summary": "Build data and an old installer"], thread: active)
        let decoded = try app.decode(ProposeDeletionResult.self, result)
        #expect(decoded.queued.map(\.path) == ["~/Library/Developer/Xcode/DerivedData/App-1", "~/Downloads/old-installer.dmg", "~/Library/Developer/Xcode/DerivedData/App-1"])
        #expect(decoded.queued.first?.risk == "safe")
        #expect(decoded.rejected.map(\.code) == ["protected", "needs_user_choice", "needs_user_choice", "not_in_scan", "invalid_path", "protected"])
        #expect(decoded.note == ToolCatalog.proposalNote)

        let queue = app.model.cleanup.queue
        #expect(queue.count == 2)
        #expect(queue.allSatisfy { !$0.isSelected })
        #expect(queue.allSatisfy { $0.identity != nil })
        #expect(queue.allSatisfy { $0.source.isAssistant })
        #expect(queue.first?.ruleID == "xcode.deriveddata")
        #expect(queue.first?.risk == .safe)
        if case .assistant(let owner, let reason) = queue.first?.source {
            #expect(owner == active)
            #expect(reason == "Xcode rebuilds it.")
        }

        let card = try #require(app.model.assistant.items.compactMap { item -> ProposalBatch? in
            if case .proposal(let batch) = item.kind { batch } else { nil }
        }.first)
        #expect(card.summary == "Build data and an old installer")
        #expect(card.queued.count == 3)
        #expect(card.rejected.count == 6)
        _ = thread

        let listed = try app.decode(CleanupQueueResult.self, await app.call(.getCleanupQueue))
        #expect(listed.items.map(\.path) == ["~/Library/Developer/Xcode/DerivedData/App-1", "~/Downloads/old-installer.dmg"])
        #expect(listed.items.allSatisfy { $0.source == "assistant" && !$0.selected })
        #expect(listed.totalBytes == queue.reduce(0) { $0 + $1.bytes })
    }

    @Test func proposingGuideRuleItemsSuggestsTheCommand() async throws {
        let fixture = try HomeFixture { fx in
            _ = try fx.file("home/Library/Developer/CoreSimulator/Devices/ABC/data.img", size: 8192)
        }
        defer { fixture.tearDown() }
        let app = try await AppHarness(fixture: fixture)
        let result = try app.decode(ProposeDeletionResult.self, await app.call(.proposeDeletion, [
            "items": [["path": "~/Library/Developer/CoreSimulator/Devices/ABC", "reason": "old simulator"]],
            "summary": "Simulators",
        ]))
        #expect(result.queued.isEmpty)
        #expect(result.rejected.map(\.code) == ["use_command"])
        #expect(app.model.cleanup.queue.isEmpty)
    }

    @Test func noScanGivesGuidance() async throws {
        let model = AppModel(settings: AppSettings())
        model.connect(assistantServices: nil, snapshots: .disabled, metadata: .none)
        let handler = try #require(model.toolHandler)
        let overview = await handler.handle(name: "get_disk_overview", arguments: .object([:]), thread: UUID())
        #expect(overview.isError)
        #expect(overview.text == ToolHandler.noScanText)
        let queue = await handler.handle(name: "get_cleanup_queue", arguments: .null, thread: UUID())
        #expect(!queue.isError)
        let unknown = await handler.handle(name: "rm_rf", arguments: .object([:]), thread: UUID())
        #expect(unknown.isError)
        let bad = await handler.handle(name: "list_children", arguments: .object([:]), thread: UUID())
        #expect(bad.isError)
    }
}
