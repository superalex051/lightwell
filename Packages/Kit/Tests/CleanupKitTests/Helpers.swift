import Darwin
import Foundation
@testable import CleanupKit
import RulesKit
import ScanKit
import TestSupport

/// `(dev, ino)` of a fixture item, without following symlinks.
func identity(of url: URL) -> FileIdentity? {
    var info = stat()
    guard lstat(url.path, &info) == 0 else { return nil }
    return FileIdentity(device: info.st_dev, inode: info.st_ino)
}

func exists(_ url: URL) -> Bool {
    var info = stat()
    return lstat(url.path, &info) == 0
}

/// A queue item for a real fixture item, with its real identity.
func queueItem(_ url: URL, risk: Risk = .review, ruleID: String? = nil, bytes: UInt64 = 4096, source: QueueSource = .user) -> QueueItem {
    QueueItem(path: url.path, identity: identity(of: url), bytes: bytes, freesAbout: bytes, risk: risk, ruleID: ruleID, source: source, isSelected: true)
}

struct NoAppsRunning: RunningAppChecking {
    func isRunning(bundleID: String) -> Bool { false }
}

struct AppsRunning: RunningAppChecking {
    let running: Set<String>
    func isRunning(bundleID: String) -> Bool { running.contains(bundleID) }
}

/// Executor in test mode: fixture root as home and allowed root, fixture Trash.
func makeExecutor(_ fx: FixtureBuilder, trash: (any TrashProviding)? = nil, rules: [Rule] = [], apps: any RunningAppChecking = NoAppsRunning()) -> CleanupExecutor {
    CleanupExecutor(
        policy: SafetyPolicy(home: fx.root.path),
        trash: trash ?? FixtureTrash(root: fx.root),
        allowedRoot: fx.root,
        rules: rules,
        runningApps: apps
    )
}

/// Collects every event of a run; the last one is the report.
func runAll(_ executor: CleanupExecutor, _ items: [QueueItem], mode: DeletionMode) async -> (events: [DeletionEvent], report: DeletionReport?) {
    var events: [DeletionEvent] = []
    for await event in executor.run(items, mode: mode) { events.append(event) }
    if case .finished(let report) = events.last { return (events, report) }
    return (events, nil)
}

/// Clears user flags on fixture items only (the executor never does this; tests must, so the
/// fixture can be torn down). Refuses to act outside the fixture area.
func clearFixtureFlags(_ fx: FixtureBuilder) {
    let area = FixtureBuilder.fixtureArea.path + "/"
    let root = fx.root.path
    guard root.hasPrefix(area) else { return }
    lchflags(root, 0)
    guard let walker = FileManager.default.enumerator(atPath: root) else { return }
    for case let relative as String in walker {
        lchflags(root + "/" + relative, 0)
    }
}
