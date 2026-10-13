import Darwin
import Foundation
import ScanKit

/// One item seen by the oracle walk.
public struct OracleEntry: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        case file
        case directory
        case symlink
        case other
    }

    /// Absolute path (may exceed PATH_MAX for very deep fixtures).
    public var path: String
    public var kind: Kind
    public var identity: FileIdentity
    /// `st_blocks * 512`.
    public var allocatedBytes: UInt64
    /// `st_size`.
    public var logicalBytes: UInt64
    public var linkCount: UInt16
    /// Directory that could not be opened (EACCES / EPERM).
    public var isRestricted: Bool
    /// Directory on a different device than the root (not descended).
    public var isMountPoint: Bool
    /// For hard-linked inodes: true only for the link with the smallest path (UTF-8 byte order).
    /// Always true for directories and single-link items.
    public var isPrimary: Bool
}

/// Result of an oracle walk.
public struct OracleResult: Sendable {
    public var root: String
    /// Pre-order: every directory appears before its contents. The root itself is not included.
    public var entries: [OracleEntry]
    /// Sum of `allocatedBytes` over unique inodes (directories excluded unless requested).
    public var totalBytes: UInt64
    /// Aggregated bytes per directory path (root included), same counting rules as `totalBytes`.
    public var bytesByDirectory: [String: UInt64]
    public var restrictedPaths: [String]
    public var mountPoints: [String]

    public var fileCount: Int { entries.lazy.filter { $0.kind == .file }.count }
    public var directoryCount: Int { entries.lazy.filter { $0.kind == .directory }.count }
    public var symlinkCount: Int { entries.lazy.filter { $0.kind == .symlink }.count }

    /// Aggregated bytes for a directory, or the entry's own counted bytes for a file.
    public func bytes(at path: String) -> UInt64? {
        if let total = bytesByDirectory[path] { return total }
        guard let entry = entries.first(where: { $0.path == path }) else { return nil }
        return entry.isPrimary ? entry.allocatedBytes : 0
    }
}

/// Independent reference walker for scanner tests (PLAN 5.1 "oracle equality").
///
/// Rules: `lstat` only (symlinks are never followed and count their own blocks), allocated size
/// = `st_blocks * 512`, every inode counted once (hard links: the smallest path in UTF-8 byte order
/// is primary), directories contribute 0 bytes by default, other devices are not crossed,
/// unreadable directories are recorded as restricted with 0 bytes.
/// APFS clones are NOT detected (each clone counts its full allocation), so compare against a
/// scan with `countClonesOnce == false`.
public enum Oracle {
    public static func walk(_ root: URL, includeDirectoryBlocks: Bool = false) throws -> OracleResult {
        raiseOpenFileLimit()
        let rootPath = root.path
        var rootStat = stat()
        guard lstat(rootPath, &rootStat) == 0 else {
            throw FixtureError.posix(call: "lstat", path: rootPath, errno: errno)
        }
        guard rootStat.st_mode & S_IFMT == S_IFDIR else {
            // A symlinked root is refused, matching every nested level (never followed).
            throw FixtureError.posix(call: "lstat (root is not a directory)", path: rootPath, errno: ENOTDIR)
        }
        let rootFD = open(rootPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard rootFD >= 0 else { throw FixtureError.posix(call: "open", path: rootPath, errno: errno) }
        defer { close(rootFD) }

        var entries: [OracleEntry] = []
        visit(dirFD: rootFD, path: rootPath, device: rootStat.st_dev, into: &entries)

        // Hard-link primaries: smallest path per (dev, ino) among non-directories.
        var primaryIndex: [FileIdentity: Int] = [:]
        for (index, entry) in entries.enumerated() where entry.kind != .directory {
            if let existing = primaryIndex[entry.identity] {
                if entry.path.utf8.lexicographicallyPrecedes(entries[existing].path.utf8) {
                    primaryIndex[entry.identity] = index
                }
            } else {
                primaryIndex[entry.identity] = index
            }
        }
        for index in entries.indices where entries[index].kind != .directory {
            entries[index].isPrimary = primaryIndex[entries[index].identity] == index
        }

        var bytesByDirectory: [String: UInt64] = [rootPath: includeDirectoryBlocks ? UInt64(rootStat.st_blocks) * 512 : 0]
        for entry in entries where entry.kind == .directory {
            bytesByDirectory[entry.path] = 0
        }
        var total: UInt64 = bytesByDirectory[rootPath] ?? 0
        for entry in entries {
            let counted: UInt64
            if entry.kind == .directory {
                counted = includeDirectoryBlocks ? entry.allocatedBytes : 0
            } else {
                counted = entry.isPrimary ? entry.allocatedBytes : 0
            }
            guard counted > 0 else { continue }
            total += counted
            var parent = (entry.path as NSString).deletingLastPathComponent
            while parent.count >= rootPath.count {
                bytesByDirectory[parent, default: 0] += counted
                if parent == rootPath { break }
                parent = (parent as NSString).deletingLastPathComponent
            }
        }

        return OracleResult(
            root: rootPath,
            entries: entries,
            totalBytes: total,
            bytesByDirectory: bytesByDirectory,
            restrictedPaths: entries.filter(\.isRestricted).map(\.path),
            mountPoints: entries.filter(\.isMountPoint).map(\.path)
        )
    }

    /// Iterative depth-first walk; keeps one descriptor open per level (no recursion, so very deep
    /// fixtures do not overflow small test-thread stacks).
    private static func visit(dirFD rootFD: Int32, path rootPath: String, device: dev_t, into entries: inout [OracleEntry]) {
        struct Frame {
            var fd: Int32
            var path: String
            /// (name, index of the directory's entry) still to descend into, popped from the end.
            var pendingDirs: [(String, Int)]
            var ownsFD: Bool
        }

        func list(_ fd: Int32, path: String) -> [(String, Int)] {
            var names = DirectoryListing.entries(of: fd).map(\.0)
            names.sort { $0.utf8.lexicographicallyPrecedes($1.utf8) }
            var dirs: [(String, Int)] = []
            for name in names {
                var st = stat()
                guard fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
                let childPath = path == "/" ? "/" + name : path + "/" + name
                let kind: OracleEntry.Kind
                switch st.st_mode & S_IFMT {
                case S_IFREG: kind = .file
                case S_IFDIR: kind = .directory
                case S_IFLNK: kind = .symlink
                default: kind = .other
                }
                entries.append(OracleEntry(
                    path: childPath,
                    kind: kind,
                    identity: FileIdentity(device: st.st_dev, inode: UInt64(st.st_ino)),
                    allocatedBytes: UInt64(max(st.st_blocks, 0)) * 512,
                    logicalBytes: UInt64(max(st.st_size, 0)),
                    linkCount: st.st_nlink,
                    isRestricted: false,
                    isMountPoint: kind == .directory && st.st_dev != device,
                    isPrimary: true
                ))
                if kind == .directory && st.st_dev == device {
                    dirs.append((name, entries.count - 1))
                }
            }
            return dirs.reversed()
        }

        var stack = [Frame(fd: rootFD, path: rootPath, pendingDirs: list(rootFD, path: rootPath), ownsFD: false)]
        while !stack.isEmpty {
            guard let (name, index) = stack[stack.count - 1].pendingDirs.popLast() else {
                let frame = stack.removeLast()
                if frame.ownsFD { close(frame.fd) }
                continue
            }
            let parentFD = stack[stack.count - 1].fd
            let childFD = openat(parentFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard childFD >= 0 else {
                entries[index].isRestricted = (errno == EACCES || errno == EPERM)
                continue
            }
            let childPath = entries[index].path
            stack.append(Frame(fd: childFD, path: childPath, pendingDirs: list(childFD, path: childPath), ownsFD: true))
        }
    }
}

/// Deep fixtures keep one descriptor open per level; lift the soft limit toward the hard limit.
func raiseOpenFileLimit(to wanted: rlim_t = 4096) {
    var limit = rlimit()
    guard getrlimit(RLIMIT_NOFILE, &limit) == 0, limit.rlim_cur < wanted else { return }
    limit.rlim_cur = min(wanted, limit.rlim_max)
    setrlimit(RLIMIT_NOFILE, &limit)
}
