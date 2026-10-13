import CleanupKit
import Foundation
import IPCProtocol
import RulesKit
import ScanKit
import Testing
import TestSupport
@testable import AppCore

extension InMemoryTree: RemovableTree {}

/// A fixture with a small home folder: rule matches (safe, review), protected and dangerous items,
/// and one file outside the home (blocked by the policy, because the fixture lives in /private/var/folders).
struct HomeFixture {
    let fx: FixtureBuilder
    let home: String
    let tree: InMemoryTree

    init(extra: (FixtureBuilder) throws -> Void = { _ in }) throws {
        fx = try FixtureBuilder()
        _ = try fx.file("home/Library/Developer/Xcode/DerivedData/App-1/build.o", size: 40_960)
        _ = try fx.file("home/Library/Developer/Xcode/DerivedData/App-2/index.db", size: 20_480)
        _ = try fx.file("home/Library/Caches/com.example.app/cache.bin", size: 16_384)
        _ = try fx.file("home/Downloads/old-installer.dmg", size: 65_536)
        _ = try fx.file("home/Downloads/notes.txt", size: 4096)
        _ = try fx.file("home/Library/Keychains/login.keychain-db", size: 4096)
        _ = try fx.file("home/Pictures/Trip.photoslibrary/database/photos.db", size: 8192)
        _ = try fx.file("home/Documents/Old/Family.photoslibrary/originals/a.jpg", size: 8192)
        _ = try fx.file("home/Projects/web/node_modules/pkg/index.js", size: 12_288)
        _ = try fx.file("home/Projects/web/package.json", size: 4096)
        _ = try fx.file("outside.bin", size: 4096)
        try extra(fx)
        home = fx.root.appendingPathComponent("home").path
        tree = try InMemoryTree.snapshot(of: fx.root)
    }

    var root: URL { fx.root }

    func path(_ relative: String) -> String { fx.root.appendingPathComponent(relative).path }

    func node(_ relative: String) throws -> NodeID {
        try #require(tree.node(atPath: path(relative)), "missing \(relative)")
    }

    func services(rules: [Rule] = .bundled) -> ScanServices {
        ScanServices(home: home, rules: rules, liveRefresh: false)
    }

    func tearDown() {
        #expect(fx.sentinelChanges().isEmpty)
        fx.tearDown()
    }
}

/// Polls `condition` on the main actor until it holds or `timeout` passes.
@MainActor
@discardableResult
func waitUntil(timeout: TimeInterval = 15, _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

/// An app model wired like the real one, with a fixture tree injected as a finished session.
@MainActor
struct AppHarness {
    let fixture: HomeFixture
    let model: AppModel
    let session: ScanSessionModel

    init(fixture: HomeFixture, tree: (any TreeReading)? = nil, metadata: ItemMetadata = .none, assistant: AssistantServices? = nil, now: Date? = nil) async throws {
        self.fixture = fixture
        let model = AppModel(
            cleanup: CleanupModel(configuration: .fixture(root: fixture.root, home: fixture.home)),
            settings: AppSettings(assistantConsentAccepted: false),
            home: fixture.home
        )
        model.connect(assistantServices: assistant, snapshots: .disabled, metadata: metadata)
        let session = ScanSessionModel(target: .folder(fixture.root), tree: tree ?? fixture.tree, services: fixture.services())
        model.adopt(session)
        self.model = model
        self.session = session
        let classified = await waitUntil { session.isFinished && !session.isClassifying && !session.categories.isEmpty }
        #expect(classified)
    }

    var handler: ToolHandler { model.toolHandler! }

    func call(_ tool: ToolName, _ arguments: JSONValue = .object([:]), thread: UUID = UUID()) async -> ToolCallResult {
        await handler.handle(name: tool.rawValue, arguments: arguments, thread: thread)
    }

    func decode<T: Decodable>(_ type: T.Type, _ result: ToolCallResult) throws -> T {
        #expect(!result.isError, "tool error: \(result.text)")
        return try JSONDecoder().decode(T.self, from: Data(result.text.utf8))
    }
}

/// Path of the bundled system prompt template in the repository.
var systemPromptTemplateText: String {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("App/Resources/assistant-system-prompt.md")
    return (try? String(contentsOf: url, encoding: .utf8)) ?? AssistantServices.fallbackSystemPrompt
}

/// A tree whose contents can be swapped for a fresh snapshot, reassigning every node id and
/// bumping `structureEpoch`, the way `ScanTree.adopt` does after a full root rescan.
final class EpochTree: RemovableTree, StructureVersioned, @unchecked Sendable {
    private let lock = NSLock()
    private var inner: InMemoryTree
    private var epoch: UInt64 = 0

    init(_ inner: InMemoryTree) {
        self.inner = inner
    }

    var current: InMemoryTree { lock.withLock { inner } }

    /// Swaps in `other` (a snapshot of the same root) and bumps the epoch.
    func adopt(_ other: InMemoryTree) {
        lock.withLock {
            inner = other
            epoch += 1
        }
    }

    var structureEpoch: UInt64 { lock.withLock { epoch } }
    private func valid(_ id: NodeID) -> Bool { id <= current.descendantCount(current.root) }

    var root: NodeID { current.root }
    var generation: UInt64 { current.generation &+ (structureEpoch << 40) }
    func name(_ id: NodeID) -> String { valid(id) ? current.name(id) : "" }
    func path(_ id: NodeID) -> String { valid(id) ? current.path(id) : "" }
    func size(_ id: NodeID) -> UInt64 { valid(id) ? current.size(id) : 0 }
    func flags(_ id: NodeID) -> NodeFlags { valid(id) ? current.flags(id) : [] }
    func parent(_ id: NodeID) -> NodeID? { valid(id) ? current.parent(id) : nil }
    func children(_ id: NodeID) -> [NodeID] { valid(id) ? current.children(id) : [] }
    func descendantCount(_ id: NodeID) -> UInt32 { valid(id) ? current.descendantCount(id) : 0 }
    func node(atPath path: String) -> NodeID? { current.node(atPath: path) }
    func reclaimableBytes(_ id: NodeID, ifAlsoRemoving others: Set<NodeID>) -> UInt64 { valid(id) ? current.reclaimableBytes(id, ifAlsoRemoving: others) : 0 }
    func identity(_ id: NodeID) -> FileIdentity? { valid(id) ? current.identity(id) : nil }
    func removeSubtree(_ id: NodeID) { current.removeSubtree(id) }
}
