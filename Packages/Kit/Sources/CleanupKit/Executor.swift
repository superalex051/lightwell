import Foundation
import RulesKit
import ScanKit
import Synchronization

public enum DeletionMode: String, Sendable, Codable, Hashable {
    case trash
    case permanent
}

/// Moves one item to the Trash. Returns the new location when known.
public protocol TrashProviding: Sendable {
    func trash(_ url: URL) throws -> URL?
}

/// Additive: what went wrong for one item.
public enum DeletionFailureKind: String, Sendable, Codable, Hashable, CaseIterable {
    /// Refused by the SafetyPolicy or a revalidation rule; see `block`.
    case blocked
    /// The item on disk is not the one that was scanned (different device or inode).
    case changedSinceScan
    /// Test mode: the item is outside the allowed root.
    case outsideAllowedRoot
    case notFound
    /// The item (or something inside a folder) has the locked or append-only flag. Never cleared.
    case locked
    case permissionDenied
    /// A rule precondition failed: the app that owns the item is running.
    case appRunning
    /// The volume has no Trash (for example some network volumes).
    case trashUnavailable
    /// Moving an item that is already in the Trash frees nothing.
    case alreadyInTrash
    /// The item is riskier now than when it was queued, so it needs a new review.
    case riskIncreased
    /// A folder contains a mount point; nothing on the other volume is touched.
    case containsOtherVolume
    /// A recently trashed record no longer points into a Trash folder.
    case notInTrash
    /// The item is itself the root of another mounted volume (its device differs from its parent's).
    case mountPoint
    /// A protected or dangerous item sits inside this folder; `detail` holds its path.
    case containsProtected
    /// Dangerous items are never removed on the assistant's suggestion; the user must choose them.
    case needsUserChoice
    /// A folder inside the item could not be read, so it could not be checked for protected items.
    case unreadableSubfolder
    /// The run was stopped before this item.
    case cancelled
    case failed

    /// Short user-facing explanation (CleanupKit string catalog).
    public var message: String {
        switch self {
        case .blocked:
            String(localized: "This item is protected and was left alone.", bundle: .module)
        case .changedSinceScan:
            BlockReason.changedSinceScan.message
        case .outsideAllowedRoot:
            String(localized: "This item is outside the folder this cleanup may change.", bundle: .module)
        case .notFound:
            String(localized: "This item is no longer there. It may have been moved or deleted already.", bundle: .module)
        case .locked:
            String(localized: "This item is locked. Unlock it in its Get Info window in Finder first.", bundle: .module)
        case .permissionDenied:
            String(localized: "You do not have permission to remove this item.", bundle: .module)
        case .appRunning:
            String(localized: "Quit the app that uses this item, then try again.", bundle: .module)
        case .trashUnavailable:
            String(localized: "This disk has no Trash. You can delete the item permanently instead.", bundle: .module)
        case .alreadyInTrash:
            String(localized: "This item is already in the Trash. Delete it permanently to free its space.", bundle: .module)
        case .riskIncreased:
            String(localized: "This item needs a closer look now. Review it again before removing it.", bundle: .module)
        case .containsOtherVolume:
            String(localized: "This folder contains another disk, so it was left alone.", bundle: .module)
        case .notInTrash:
            String(localized: "This item is no longer in the Trash.", bundle: .module)
        case .mountPoint:
            String(localized: "This is where another disk is attached, so it was left alone. Eject the disk instead.", bundle: .module)
        case .containsProtected:
            String(localized: "This folder holds something protected, so it was left alone.", bundle: .module)
        case .needsUserChoice:
            String(localized: "Only you can choose to remove this item. Suggestions from the assistant are not enough.", bundle: .module)
        case .unreadableSubfolder:
            String(localized: "A folder inside this item could not be read, so it was left alone. Giving Lightwell Full Disk Access in System Settings may help.", bundle: .module)
        case .cancelled:
            String(localized: "The cleanup stopped before reaching this item.", bundle: .module)
        case .failed:
            String(localized: "This item could not be removed.", bundle: .module)
        }
    }
}

/// Why one item was not deleted.
public struct DeletionFailure: Sendable, Codable, Hashable {
    public var itemID: UUID
    public var path: String
    /// Additive: the failure category.
    public var kind: DeletionFailureKind
    public var block: BlockReason?
    /// Error description from the file system, if any (not shown verbatim to users).
    public var detail: String?

    public init(itemID: UUID, path: String, kind: DeletionFailureKind? = nil, block: BlockReason? = nil, detail: String? = nil) {
        self.itemID = itemID
        self.path = path
        self.kind = kind ?? (block == nil ? .failed : .blocked)
        self.block = block
        self.detail = detail
    }

    /// User-facing explanation: the block reason when there is one, otherwise the kind's message.
    public var message: String {
        if kind == .blocked, let block { return block.message }
        if kind == .containsProtected, let block { return kind.message + " " + block.message }
        return kind.message
    }
}

/// One item that was deleted or trashed.
public struct DeletionSuccess: Sendable, Codable, Hashable {
    public var itemID: UUID
    public var path: String
    /// The item's reclaimable estimate (`QueueItem.freesAbout`).
    public var bytes: UInt64
    /// Where the item went in the Trash; nil for permanent deletions and removed symlinks.
    public var trashedURL: URL?

    public init(itemID: UUID, path: String, bytes: UInt64, trashedURL: URL? = nil) {
        self.itemID = itemID
        self.path = path
        self.bytes = bytes
        self.trashedURL = trashedURL
    }
}

/// Summary shown after a cleanup run.
public struct DeletionReport: Sendable, Codable, Hashable, Identifiable {
    public var id: UUID
    public var mode: DeletionMode
    public var succeeded: [DeletionSuccess]
    public var failed: [DeletionFailure]
    public var startedAt: Date
    public var finishedAt: Date

    public init(id: UUID = UUID(), mode: DeletionMode, succeeded: [DeletionSuccess], failed: [DeletionFailure], startedAt: Date, finishedAt: Date) {
        self.id = id
        self.mode = mode
        self.succeeded = succeeded
        self.failed = failed
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }

    public var bytesFreed: UInt64 { succeeded.reduce(0) { $0 + $1.bytes } }
    /// Additive: bytes freed right away (deleted permanently or symlinks removed).
    public var bytesFreedNow: UInt64 { succeeded.filter { $0.trashedURL == nil }.reduce(0) { $0 + $1.bytes } }
    /// Additive: bytes moved to the Trash (freed only when the Trash is emptied).
    public var bytesMovedToTrash: UInt64 { succeeded.filter { $0.trashedURL != nil }.reduce(0) { $0 + $1.bytes } }
}

public enum DeletionEvent: Sendable, Hashable {
    case itemStarted(UUID)
    case itemSucceeded(DeletionSuccess)
    case itemFailed(DeletionFailure)
    case finished(DeletionReport)
}

/// A trashed item the app remembers so it can delete it for good without emptying the whole Trash.
public struct TrashedRecord: Sendable, Codable, Hashable, Identifiable {
    public var id: UUID
    public var originalPath: String
    public var trashedURL: URL
    public var bytes: UInt64
    public var date: Date
    /// Additive: identity of the trashed item, revalidated before a permanent deletion.
    public var identity: FileIdentity?

    public init(id: UUID = UUID(), originalPath: String, trashedURL: URL, bytes: UInt64, date: Date, identity: FileIdentity? = nil) {
        self.id = id
        self.originalPath = originalPath
        self.trashedURL = trashedURL
        self.bytes = bytes
        self.date = date
        self.identity = identity
    }
}

/// Executes a confirmed queue. Frozen contract (PLAN 4.3) plus additive init and `cancel()`.
///
/// Per item, in order (PLAN 2.7):
/// 1. Resolve the real parent directory (the item itself is never resolved) and, in test mode,
///    refuse anything not strictly inside `allowedRoot`.
/// 2. `lstat` the item relative to the parent descriptor and compare `(dev, ino)` with
///    `QueueItem.identity`. A nil identity is refused (`notInScan`); a mismatch is refused
///    (`changedSinceScan`). The check is never skipped.
///    An item whose device differs from its parent's (a mount point) is refused (`mountPoint`).
/// 3. Refuse read-only volumes, then run the SafetyPolicy again; a block refuses. Items queued as
///    never are refused; an item that is dangerous now but was queued at a lower risk is refused
///    (`riskIncreased`); dangerous items proposed by the assistant are refused (`needsUserChoice`).
/// 4. Folders: refuse when a protected path of the table lies inside (`containsProtected`), then a
///    directory-only pre-walk refuses on nested Photos libraries, Time Machine backups, device
///    backups and browser profiles. A nested dangerous item passes only when the user queued the
///    folder at dangerous risk (the per-item acknowledgement).
/// 5. Rule preconditions (the owning app must not be running).
/// 6. Locked items (`uchg`, `schg`, append-only) fail as `locked`; flags are never changed.
/// 7. Trash mode moves the item (a symlink is moved as the link, never its target) through
///    `TrashProviding`. Permanent mode unlinks files and links, and removes folders with a walk
///    that never follows symlinks, never enters another volume and first checks that every folder
///    inside may be changed.
///
/// Cancellation (`cancel()` or ending the stream) takes effect between items and during pre-walks.
///
/// A run works on its own dispatch queue, not on Swift's cooperative thread pool: long walks of a
/// large scan (categories, classifications, estimates) can fill that pool, and a cleanup must
/// never wait for them (the run would show as working while nothing happens).
public actor CleanupExecutor {
    public let policy: SafetyPolicy
    public let trash: any TrashProviding
    /// When set (test mode), every path outside this root is refused.
    public let allowedRoot: URL?

    private let worker: ExecutorWorker
    private let current = Mutex<RunControl?>(nil)

    public init(policy: SafetyPolicy, trash: any TrashProviding, allowedRoot: URL?) {
        self.init(policy: policy, trash: trash, allowedRoot: allowedRoot, rules: .bundled, runningApps: WorkspaceRunningApps())
    }

    /// Additive: inject the rules (for preconditions) and the running-app check.
    public init(policy: SafetyPolicy, trash: any TrashProviding, allowedRoot: URL?, rules: [Rule], runningApps: any RunningAppChecking) {
        self.policy = policy
        self.trash = trash
        self.allowedRoot = allowedRoot
        self.worker = ExecutorWorker(
            policy: policy,
            trash: trash,
            allowedRoot: allowedRoot.map { FileOperations.canonicalRoot($0) },
            rulesByID: Dictionary(rules.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
            runningApps: runningApps,
            homeTrash: CanonicalPath.fullyResolvedString(policy.home).map { $0 + "/.Trash" }
        )
    }

    /// Starts a run and returns its events. Nonisolated (additive change): starting a run needs no
    /// hop onto the actor, so it never waits for a free thread of the cooperative pool.
    public nonisolated func run(_ items: [QueueItem], mode: DeletionMode) -> AsyncStream<DeletionEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: DeletionEvent.self)
        let worker = worker
        // One control per run: a new run never clears a cancel meant for an earlier one.
        let control = RunControl()
        current.withLock { $0 = control }
        continuation.onTermination = { _ in control.cancel() }
        DispatchQueue(label: "com.alexluncan.lightwell.cleanup.run", qos: .userInitiated).async {
            worker.execute(items, mode: mode, control: control, emit: { continuation.yield($0) })
            continuation.finish()
        }
        return stream
    }

    /// Stops the most recent run before its next item.
    public nonisolated func cancel() {
        current.withLock { $0 }?.cancel()
    }
}

final class RunControl: Sendable {
    private let cancelled = Mutex(false)

    func cancel() { cancelled.withLock { $0 = true } }
    var isCancelled: Bool { cancelled.withLock { $0 } || Task.isCancelled }
}

struct ExecutorWorker: Sendable {
    let policy: SafetyPolicy
    let trash: any TrashProviding
    /// nil: no restriction. `.some(nil)`: configured but unresolvable, refuse everything.
    let allowedRoot: String??
    let rulesByID: [String: Rule]
    let runningApps: any RunningAppChecking
    let homeTrash: String?

    func execute(_ items: [QueueItem], mode: DeletionMode, control: RunControl, emit: (DeletionEvent) -> Void) {
        let started = Date()
        var succeeded: [DeletionSuccess] = []
        var failed: [DeletionFailure] = []
        for item in items {
            if control.isCancelled {
                let failure = DeletionFailure(itemID: item.id, path: item.path, kind: .cancelled)
                failed.append(failure)
                emit(.itemFailed(failure))
                continue
            }
            emit(.itemStarted(item.id))
            switch process(item, mode: mode, control: control) {
            case .success(let success):
                succeeded.append(success)
                emit(.itemSucceeded(success))
            case .failure(let problem):
                let failure = DeletionFailure(itemID: item.id, path: item.path, kind: problem.kind, block: problem.block, detail: problem.detail)
                failed.append(failure)
                emit(.itemFailed(failure))
            }
        }
        emit(.finished(DeletionReport(mode: mode, succeeded: succeeded, failed: failed, startedAt: started, finishedAt: Date())))
    }

    func process(_ item: QueueItem, mode: DeletionMode, control: RunControl = RunControl()) -> Result<DeletionSuccess, FileProblem> {
        let opened: OpenedItem
        switch FileOperations.open(path: item.path, allowedRoot: allowedRoot) {
        case .success(let value): opened = value
        case .failure(let problem): return .failure(problem)
        }
        guard let expected = item.identity else {
            return .failure(FileProblem(.blocked, block: .notInScan, detail: "no identity"))
        }
        guard opened.identity == expected else {
            return .failure(FileProblem(.changedSinceScan, block: .changedSinceScan))
        }
        if opened.isOnReadOnlyVolume {
            return .failure(FileProblem(.blocked, block: .readOnlyVolume))
        }
        let classification = policy.check(path: opened.canonicalPath, isDirectory: opened.isDirectory, volume: nil)
        if let block = classification.block {
            return .failure(FileProblem(.blocked, block: block))
        }
        if item.risk == .never {
            return .failure(FileProblem(.blocked, detail: "queued as never"))
        }
        if classification.risk == .dangerous && item.risk < .dangerous {
            return .failure(FileProblem(.riskIncreased))
        }
        if item.source.isAssistant && (classification.risk >= .dangerous || item.risk >= .dangerous) {
            return .failure(FileProblem(.needsUserChoice))
        }
        // The user's per-item acknowledgement: queued by the user at dangerous risk.
        let acknowledged = item.risk == .dangerous && !item.source.isAssistant
        if opened.isDirectory {
            if let nested = policy.protectedDescendant(of: opened.canonicalPath), nested.isBlocked || !acknowledged {
                return .failure(FileProblem(.containsProtected, block: nested.classification.block, detail: nested.path))
            }
            if let problem = FileOperations.findProtectedDirectory(in: opened, allowDangerous: acknowledged, isCancelled: { control.isCancelled }) {
                return .failure(problem)
            }
        }
        if let ruleID = item.ruleID, let rule = rulesByID[ruleID] {
            for bundleID in rule.requiredQuitApps where runningApps.isRunning(bundleID: bundleID) {
                return .failure(FileProblem(.appRunning, detail: bundleID))
            }
        }
        if opened.isLocked {
            return .failure(FileProblem(.locked))
        }

        if mode == .permanent {
            if let problem = FileOperations.removePermanently(opened) { return .failure(problem) }
            return .success(DeletionSuccess(itemID: item.id, path: item.path, bytes: item.freesAbout))
        }
        if isInsideTrash(opened.canonicalPath) {
            return .failure(FileProblem(.alreadyInTrash))
        }
        do {
            // isDirectory comes from lstat: a symlink is never given a trailing slash, so the link
            // itself is moved and its target is never touched.
            let url = URL(fileURLWithPath: opened.canonicalPath, isDirectory: opened.isDirectory)
            let resulting = try trash.trash(url)
            if let resulting, opened.isSymlink {
                var moved = stat()
                guard lstat(resulting.path, &moved) == 0, moved.st_dev == opened.info.st_dev, moved.st_ino == opened.info.st_ino else {
                    return .failure(FileProblem(.failed, detail: "trash moved a different item than the link"))
                }
            }
            return .success(DeletionSuccess(itemID: item.id, path: item.path, bytes: item.freesAbout, trashedURL: resulting))
        } catch {
            return .failure(Self.problem(fromTrashError: error, flags: opened.info.st_flags))
        }
    }

    func isInsideTrash(_ canonical: String) -> Bool {
        if let homeTrash, canonical.lowercased().hasPrefix(homeTrash.lowercased() + "/") { return true }
        return canonical.split(separator: "/").dropLast().contains { $0 == ".Trashes" }
    }

    static func problem(fromTrashError error: any Error, flags: UInt32) -> FileProblem {
        let ns = error as NSError
        let detail = "\(ns.domain) \(ns.code)"
        if ns.domain == NSCocoaErrorDomain {
            switch ns.code {
            case NSFeatureUnsupportedError: return FileProblem(.trashUnavailable, detail: detail)
            case NSFileNoSuchFileError, NSFileReadNoSuchFileError: return FileProblem(.notFound, detail: detail)
            case NSFileWriteNoPermissionError, NSFileReadNoPermissionError:
                return FileProblem(FileOperations.isLocked(flags) ? .locked : .permissionDenied, detail: detail)
            case NSFileWriteVolumeReadOnlyError: return FileProblem(.blocked, block: .readOnlyVolume, detail: detail)
            default: break
            }
            if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
                return problem(fromTrashError: underlying, flags: flags)
            }
        }
        if ns.domain == NSPOSIXErrorDomain {
            switch Int32(ns.code) {
            case EXDEV, ENOTSUP: return FileProblem(.trashUnavailable, detail: detail)
            default: return .errno(Int32(ns.code), "trash")
            }
        }
        return FileProblem(.failed, detail: detail)
    }
}
