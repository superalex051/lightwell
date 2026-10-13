import Darwin
import Foundation
import RulesKit
import ScanKit

/// Items this app moved to the Trash (PLAN 2.7 step 5). Space is freed only when the Trash is
/// emptied; this list lets the user delete exactly these items for good without emptying the rest
/// of their Trash.
public struct RecentlyTrashed: Sendable, Codable, Hashable {
    /// Folder names that count as a Trash: the user's and a volume's. The test double's folder
    /// counts only when that `FixtureTrash` is passed in explicitly.
    static let trashFolderNames: Set<String> = [".Trash", ".Trashes"]

    public private(set) var records: [TrashedRecord]

    public init(records: [TrashedRecord] = []) {
        self.records = records
    }

    public var totalBytes: UInt64 { records.reduce(0) { $0 + $1.bytes } }

    /// Remembers every trashed item of `report`, with the identity of the item at its new place.
    public mutating func record(_ report: DeletionReport, date: Date = Date()) {
        for success in report.succeeded {
            guard let url = success.trashedURL else { continue }
            var info = stat()
            let identity = lstat(url.path, &info) == 0 ? FileIdentity(device: info.st_dev, inode: info.st_ino) : nil
            records.append(TrashedRecord(originalPath: success.path, trashedURL: url, bytes: success.bytes, date: date, identity: identity))
        }
    }

    /// Drops records whose item is gone (the Trash was emptied or the item was put back).
    public mutating func pruneMissing() {
        records.removeAll { record in
            var info = stat()
            return lstat(record.trashedURL.path, &info) != 0
        }
    }

    /// Deletes the chosen trashed items for good. Each one must still be inside a Trash folder
    /// (and inside `allowedRoot` when set) and must have the identity recorded when it was
    /// trashed; locked items are left alone. Succeeded and vanished records are removed.
    /// `testTrash` (tests only) makes that fixture Trash folder count as a Trash.
    public mutating func deletePermanently(_ ids: Set<UUID>, allowedRoot: URL? = nil, testTrash: FixtureTrash? = nil) -> DeletionReport {
        let started = Date()
        let root: String?? = allowedRoot.map { FileOperations.canonicalRoot($0) }
        let testTrashPath = testTrash.flatMap { CanonicalPath.realpathString($0.directory.path) }
        var succeeded: [DeletionSuccess] = []
        var failed: [DeletionFailure] = []
        var drop: Set<UUID> = []
        for record in records where ids.contains(record.id) {
            switch Self.delete(record, allowedRoot: root, testTrashPath: testTrashPath) {
            case nil:
                succeeded.append(DeletionSuccess(itemID: record.id, path: record.trashedURL.path, bytes: record.bytes))
                drop.insert(record.id)
            case let problem?:
                failed.append(DeletionFailure(itemID: record.id, path: record.trashedURL.path, kind: problem.kind, block: problem.block, detail: problem.detail))
                if problem.kind == .notFound { drop.insert(record.id) }
            }
        }
        records.removeAll { drop.contains($0.id) }
        return DeletionReport(mode: .permanent, succeeded: succeeded, failed: failed, startedAt: started, finishedAt: Date())
    }

    private static func delete(_ record: TrashedRecord, allowedRoot: String??, testTrashPath: String?) -> FileProblem? {
        let opened: OpenedItem
        switch FileOperations.open(path: record.trashedURL.path, allowedRoot: allowedRoot) {
        case .success(let value): opened = value
        case .failure(let problem): return problem
        }
        let ancestors = opened.canonicalPath.split(separator: "/").dropLast().map(String.init)
        let inTestTrash = testTrashPath.map { opened.canonicalPath.hasPrefix($0 + "/") } ?? false
        guard inTestTrash || ancestors.contains(where: trashFolderNames.contains) else { return FileProblem(.notInTrash) }
        guard let expected = record.identity else { return FileProblem(.blocked, block: .notInScan, detail: "no identity") }
        guard opened.identity == expected else { return FileProblem(.changedSinceScan, block: .changedSinceScan) }
        return FileOperations.removePermanently(opened)
    }
}
