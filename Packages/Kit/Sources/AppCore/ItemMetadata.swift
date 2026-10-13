import CoreServices
import Darwin
import Foundation
import Synchronization

/// File metadata the tools may show (PLAN 3.7 `inspect_path`, `search_items`). Only names, dates and
/// link counts: never file contents. Spotlight provides the last-used date and bundle id.
public struct ItemMetadata: Sendable {
    public var modified: @Sendable (String) -> Date?
    public var lastUsed: @Sendable (String) -> Date?
    public var bundleID: @Sendable (String) -> String?
    public var linkCount: @Sendable (String) -> Int?

    public init(
        modified: @escaping @Sendable (String) -> Date?,
        lastUsed: @escaping @Sendable (String) -> Date?,
        bundleID: @escaping @Sendable (String) -> String?,
        linkCount: @escaping @Sendable (String) -> Int?
    ) {
        self.modified = modified
        self.lastUsed = lastUsed
        self.bundleID = bundleID
        self.linkCount = linkCount
    }

    /// `lstat` for dates and links (symlinks are never followed), Spotlight for the rest.
    public static let live = ItemMetadata(
        modified: { path in
            var info = stat()
            guard lstat(path, &info) == 0 else { return nil }
            return Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
        },
        lastUsed: { path in spotlightValue(path, kMDItemLastUsedDate) as? Date },
        bundleID: { path in spotlightValue(path, kMDItemCFBundleIdentifier) as? String },
        linkCount: { path in
            var info = stat()
            guard lstat(path, &info) == 0 else { return nil }
            return Int(info.st_nlink)
        }
    )

    /// Nothing known (tests that must not depend on the disk or Spotlight).
    public static let none = ItemMetadata(modified: { _ in nil }, lastUsed: { _ in nil }, bundleID: { _ in nil }, linkCount: { _ in nil })

    private static func spotlightValue(_ path: String, _ key: CFString) -> Any? {
        guard let item = MDItemCreate(kCFAllocatorDefault, path as CFString) else { return nil }
        return MDItemCopyAttribute(item, key)
    }
}

/// Counts local Time Machine snapshots with `tmutil listlocalsnapshots <volume>` (3 s timeout).
/// Cached for five minutes per volume.
public final class SnapshotCounter: Sendable {
    private let cache = Mutex<[String: (date: Date, count: Int)]>([:])
    private let run: @Sendable (String) async -> Int?

    public init(run: @escaping @Sendable (String) async -> Int? = SnapshotCounter.tmutil) {
        self.run = run
    }

    /// A counter that always answers 0 (UI test mode, folder-only contexts).
    public static let disabled = SnapshotCounter(run: { _ in 0 })

    public func count(volumePath: String, now: Date = Date()) async -> Int {
        if let hit = cache.withLock({ $0[volumePath] }), now.timeIntervalSince(hit.date) < 300 { return hit.count }
        let value = await run(volumePath) ?? 0
        cache.withLock { $0[volumePath] = (now, value) }
        return value
    }

    /// Runs tmutil without blocking a cooperative thread: one reader drains stdout on a background
    /// queue until EOF, the termination handler reports the exit, and the result is delivered when
    /// both are done. A 3 s timer terminates a stuck run.
    public static func tmutil(_ volumePath: String) async -> Int? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tmutil")
        process.arguments = ["listlocalsnapshots", volumePath]
        process.environment = ["PATH": "/usr/bin:/bin"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        return await withCheckedContinuation { (continuation: CheckedContinuation<Int?, Never>) in
            let rendezvous = ProcessRendezvous { data, status, timedOut in
                guard !timedOut, status == 0 else {
                    continuation.resume(returning: nil)
                    return
                }
                let text = String(decoding: data, as: UTF8.self)
                continuation.resume(returning: text.split(separator: "\n").filter { $0.contains("com.apple.TimeMachine.") }.count)
            }
            process.terminationHandler = { finished in
                rendezvous.exited(finished.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                rendezvous.failed()
                return
            }
            let reader = output.fileHandleForReading
            DispatchQueue.global(qos: .utility).async {
                rendezvous.output(reader.readDataToEndOfFile())
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                guard process.isRunning else { return }
                rendezvous.markTimedOut()
                process.terminate()
            }
        }
    }
}

/// Joins a child process's exit and its stdout EOF, which arrive on different threads in either
/// order, and calls `deliver` exactly once when both are in (or once on a launch failure).
final class ProcessRendezvous: Sendable {
    private struct State {
        var data: Data?
        var status: Int32?
        var timedOut = false
        var delivered = false
    }

    private let state = Mutex(State())
    private let deliver: @Sendable (Data, Int32, Bool) -> Void

    init(deliver: @escaping @Sendable (Data, Int32, Bool) -> Void) {
        self.deliver = deliver
    }

    func output(_ data: Data) { complete { $0.data = data } }
    func exited(_ status: Int32) { complete { $0.status = status } }
    func markTimedOut() { state.withLock { $0.timedOut = true } }

    /// The process never started: deliver a failure once.
    func failed() {
        complete {
            $0.data = $0.data ?? Data()
            $0.status = $0.status ?? -1
        }
    }

    private func complete(_ change: (inout State) -> Void) {
        // The check for "both in" and the delivered flag change under one lock, so only one caller wins.
        let ready = state.withLock { state -> (Data, Int32, Bool)? in
            change(&state)
            guard !state.delivered, let data = state.data, let status = state.status else { return nil }
            state.delivered = true
            return (data, status, state.timedOut)
        }
        if let (data, status, timedOut) = ready { deliver(data, status, timedOut) }
    }
}
