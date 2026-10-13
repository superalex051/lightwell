import Foundation
import Testing
import TestSupport
@testable import ScanKit

/// Runs a scan to completion and returns the tree (or records the failure).
func scanTree(
    _ root: URL, workers: Int? = 4, countClonesOnce: Bool = false, sizeMode: SizeMode? = nil,
    excluded: [String] = [], sourceLocation: SourceLocation = #_sourceLocation
) async throws -> ScanTree {
    let scanner = Scanner(ScanOptions(root: root, workers: workers, sizeMode: sizeMode, countClonesOnce: countClonesOnce, excludedPaths: excluded))
    var tree: ScanTree?
    var failure: ScanError?
    for await event in scanner.start() {
        switch event {
        case .finished(let finished): tree = finished
        case .failed(let error): failure = error
        case .progress: break
        }
    }
    if let failure { Issue.record("scan failed: \(failure)", sourceLocation: sourceLocation) }
    return try #require(tree, sourceLocation: sourceLocation)
}

/// Asserts that the scanner tree equals the oracle walk exactly (sizes per item and directory,
/// item count, restricted and symlink flags, hard-link primaries).
func expectMatchesOracle(_ tree: ScanTree, _ oracle: OracleResult, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(tree.size(tree.root) == oracle.totalBytes, "root total", sourceLocation: sourceLocation)
    #expect(Int(tree.descendantCount(tree.root)) == oracle.entries.count, "item count", sourceLocation: sourceLocation)
    var mismatches: [String] = []
    for entry in oracle.entries {
        guard let id = tree.node(atPath: entry.path) else {
            mismatches.append("missing \(entry.path)")
            continue
        }
        let flags = tree.flags(id)
        let expected: UInt64 = entry.kind == .directory ? (oracle.bytesByDirectory[entry.path] ?? 0) : (entry.isPrimary ? entry.allocatedBytes : 0)
        if tree.size(id) != expected { mismatches.append("size \(entry.path): \(tree.size(id)) != \(expected)") }
        if flags.contains(.restricted) != entry.isRestricted { mismatches.append("restricted \(entry.path)") }
        if flags.contains(.symlink) != (entry.kind == .symlink) { mismatches.append("symlink \(entry.path)") }
        if flags.contains(.directory) != (entry.kind == .directory) { mismatches.append("directory \(entry.path)") }
        if entry.kind != .directory && entry.linkCount > 1 && flags.contains(.hardLinkSecondary) == entry.isPrimary {
            mismatches.append("hard-link primary \(entry.path)")
        }
        if tree.identity(id)?.inode != entry.identity.inode && !entry.isMountPoint { mismatches.append("identity \(entry.path)") }
        if mismatches.count > 20 { break }
    }
    #expect(mismatches.isEmpty, "\(mismatches.prefix(20))", sourceLocation: sourceLocation)
}

/// Structural fingerprint of a subtree: path, size, flags for every node, in path order.
func fingerprint(_ tree: any TreeReading) -> [String] {
    var lines: [String] = []
    var stack = [tree.root]
    while let next = stack.popLast() {
        lines.append("\(tree.path(next))|\(tree.size(next))|\(tree.flags(next).rawValue)|\(tree.descendantCount(next))")
        stack.append(contentsOf: tree.children(next))
    }
    return lines.sorted()
}

/// Waits until `condition` holds or `timeout` passes. Returns the elapsed time when it held.
func waitUntil(timeout: Duration, poll: Duration = .milliseconds(50), _ condition: () -> Bool) async -> Duration? {
    let clock = ContinuousClock()
    let start = clock.now
    while clock.now - start < timeout {
        if condition() { return clock.now - start }
        try? await Task.sleep(for: poll)
    }
    return condition() ? clock.now - start : nil
}
