import Darwin
import Foundation
import RulesKit
import ScanKit

/// Why a file operation stopped. Mapped to `DeletionFailureKind` by the callers.
struct FileProblem: Error, Sendable {
    var kind: DeletionFailureKind
    var block: BlockReason?
    var detail: String?

    init(_ kind: DeletionFailureKind, block: BlockReason? = nil, detail: String? = nil) {
        self.kind = kind
        self.block = block
        self.detail = detail
    }

    static func errno(_ code: Int32, _ call: String) -> FileProblem {
        switch code {
        case ENOENT, ENOTDIR: FileProblem(.notFound, detail: "\(call): errno \(code)")
        case EACCES, EPERM: FileProblem(.permissionDenied, detail: "\(call): errno \(code)")
        case EROFS: FileProblem(.blocked, block: .readOnlyVolume, detail: "\(call): errno \(code)")
        default: FileProblem(.failed, detail: "\(call): errno \(code)")
        }
    }
}

/// An item opened for revalidation: an open descriptor on its real parent directory plus the
/// `lstat` of the item itself, taken relative to that descriptor (no symlink is ever followed).
final class OpenedItem {
    let parentFD: Int32
    let name: String
    /// Real parent path + "/" + name (the item itself is never resolved).
    let canonicalPath: String
    let info: stat

    init(parentFD: Int32, name: String, canonicalPath: String, info: stat) {
        self.parentFD = parentFD
        self.name = name
        self.canonicalPath = canonicalPath
        self.info = info
    }

    deinit { close(parentFD) }

    var isDirectory: Bool { (info.st_mode & S_IFMT) == S_IFDIR }
    var isSymlink: Bool { (info.st_mode & S_IFMT) == S_IFLNK }
    var isLocked: Bool { FileOperations.isLocked(info.st_flags) }
    var identity: FileIdentity { FileIdentity(device: info.st_dev, inode: info.st_ino) }

    /// Read-only file system under the parent directory.
    var isOnReadOnlyVolume: Bool {
        var fs = statfs()
        return fstatfs(parentFD, &fs) == 0 && (fs.f_flags & UInt32(MNT_RDONLY)) != 0
    }
}

enum FileOperations {
    static let lockFlags = UInt32(UF_IMMUTABLE) | UInt32(SF_IMMUTABLE) | UInt32(UF_APPEND) | UInt32(SF_APPEND)

    static func isLocked(_ flags: UInt32) -> Bool { flags & lockFlags != 0 }

    /// Canonical form of an allowed root (realpath). nil when the root cannot be resolved, in
    /// which case callers must refuse everything.
    static func canonicalRoot(_ url: URL) -> String? {
        CanonicalPath.realpathString(url.path)
    }

    /// Opens `path` for revalidation and checks that it sits strictly inside `allowedRoot`.
    ///
    /// - Parameter allowedRoot: `.some(nil)` means a root was configured but could not be resolved
    ///   (everything is refused); `nil` means no restriction.
    static func open(path: String, allowedRoot: String??) -> Result<OpenedItem, FileProblem> {
        guard path.hasPrefix("/"), let comps = CanonicalPath.lexicalComponents(path) else {
            return .failure(FileProblem(.blocked, block: .notInScan, detail: "relative path"))
        }
        guard let name = comps.last else {
            return .failure(FileProblem(.blocked, block: .protectedRoot))
        }
        let parent = CanonicalPath.join(Array(comps.dropLast()))
        guard let realParent = CanonicalPath.realpathString(parent) else {
            return .failure(FileProblem(.notFound, detail: "parent missing"))
        }
        let canonical = (realParent == "/" ? "" : realParent) + "/" + name
        if let allowed = allowedRoot {
            guard let root = allowed, canonical.hasPrefix(root == "/" ? "/" : root + "/"), canonical != root else {
                return .failure(FileProblem(.outsideAllowedRoot))
            }
        }
        let fd = Darwin.open(realParent, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { return .failure(.errno(errno, "open parent")) }
        var info = stat()
        guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            let code = errno
            close(fd)
            return .failure(.errno(code, "lstat"))
        }
        var parentInfo = stat()
        guard fstat(fd, &parentInfo) == 0 else {
            let code = errno
            close(fd)
            return .failure(.errno(code, "fstat parent"))
        }
        // A mount point reports the mounted volume's device; acting on it would reach into that volume.
        if isMountPoint(item: info, parent: parentInfo) {
            close(fd)
            return .failure(FileProblem(.mountPoint))
        }
        return .success(OpenedItem(parentFD: fd, name: name, canonicalPath: canonical, info: info))
    }

    /// An item whose device differs from its parent directory's device is the root of another
    /// mounted volume.
    static func isMountPoint(item: stat, parent: stat) -> Bool {
        item.st_dev != parent.st_dev
    }

    /// Removes the item for good. Symlinks and files are unlinked (a symlink's target is never
    /// touched). Directories are first walked completely without following symlinks; if anything
    /// inside is locked, on another volume, or in a folder we may not change, nothing is deleted.
    /// Flags are never changed.
    static func removePermanently(_ item: OpenedItem) -> FileProblem? {
        if item.isLocked { return FileProblem(.locked) }
        guard faccessat(item.parentFD, ".", W_OK | X_OK, AT_EACCESS) == 0 else {
            return FileProblem(.permissionDenied, detail: "parent not writable")
        }
        guard item.isDirectory else {
            return unlinkat(item.parentFD, item.name, 0) == 0 ? nil : lockAware(errno, "unlink", item.info.st_flags)
        }
        guard faccessat(item.parentFD, item.name, W_OK | X_OK, AT_EACCESS) == 0 else {
            return FileProblem(.permissionDenied, detail: "folder not writable")
        }
        let device = item.info.st_dev
        if let problem = walk(parentFD: item.parentFD, name: item.name, expected: item.info, onEntry: { dirFD, name, st in
            if isLocked(st.st_flags) { return FileProblem(.locked) }
            if (st.st_mode & S_IFMT) == S_IFDIR {
                if st.st_dev != device { return FileProblem(.containsOtherVolume) }
                if faccessat(dirFD, name, W_OK | X_OK | R_OK, AT_EACCESS) != 0 {
                    return FileProblem(.permissionDenied, detail: "subfolder not writable: \(name)")
                }
            }
            return nil
        }, onDirectoryExit: { _, _ in nil }) {
            return problem
        }
        return walk(parentFD: item.parentFD, name: item.name, expected: item.info, onEntry: { dirFD, name, st in
            guard (st.st_mode & S_IFMT) != S_IFDIR else { return nil }
            return unlinkat(dirFD, name, 0) == 0 ? nil : lockAware(errno, "unlink", st.st_flags)
        }, onDirectoryExit: { parentFD, name in
            unlinkat(parentFD, name, AT_REMOVEDIR) == 0 ? nil : .errno(errno, "rmdir")
        })
    }

    private static func lockAware(_ code: Int32, _ call: String, _ flags: UInt32) -> FileProblem {
        code == EPERM && isLocked(flags) ? FileProblem(.locked) : .errno(code, call)
    }

    private struct Frame {
        var fd: Int32
        var parentFD: Int32
        var name: String
        var entries: [String]
        var index = 0
    }

    /// Iterative walk with `openat`/`fstatat` (works past PATH_MAX, never follows symlinks, never
    /// enters a directory on another device). `onEntry` sees every entry before a directory is
    /// entered; `onDirectoryExit` runs after a directory's contents, with its parent descriptor.
    private static func walk(
        parentFD: Int32,
        name: String,
        expected: stat,
        onEntry: (Int32, String, stat) -> FileProblem?,
        onDirectoryExit: (Int32, String) -> FileProblem?
    ) -> FileProblem? {
        _ = raiseOpenFileLimitOnce
        let rootFD = openat(parentFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { return .errno(errno, "open") }
        var rootInfo = stat()
        guard fstat(rootFD, &rootInfo) == 0, rootInfo.st_dev == expected.st_dev, rootInfo.st_ino == expected.st_ino else {
            close(rootFD)
            return FileProblem(.changedSinceScan, block: .changedSinceScan)
        }
        var stack = [Frame(fd: rootFD, parentFD: parentFD, name: name, entries: list(rootFD))]
        func closeAll() { stack.forEach { close($0.fd) } }
        while let top = stack.indices.last {
            if stack[top].index < stack[top].entries.count {
                let entry = stack[top].entries[stack[top].index]
                stack[top].index += 1
                let dirFD = stack[top].fd
                var st = stat()
                guard fstatat(dirFD, entry, &st, AT_SYMLINK_NOFOLLOW) == 0 else {
                    if errno == ENOENT { continue }
                    let problem = FileProblem.errno(errno, "lstat")
                    closeAll()
                    return problem
                }
                if let problem = onEntry(dirFD, entry, st) {
                    closeAll()
                    return problem
                }
                if (st.st_mode & S_IFMT) == S_IFDIR {
                    if st.st_dev != expected.st_dev {
                        closeAll()
                        return FileProblem(.containsOtherVolume)
                    }
                    let fd = openat(dirFD, entry, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard fd >= 0 else {
                        let problem = FileProblem.errno(errno, "open")
                        closeAll()
                        return problem
                    }
                    var opened = stat()
                    guard fstat(fd, &opened) == 0, opened.st_dev == st.st_dev, opened.st_ino == st.st_ino else {
                        close(fd)
                        closeAll()
                        return FileProblem(.changedSinceScan, block: .changedSinceScan, detail: "folder replaced during walk")
                    }
                    stack.append(Frame(fd: fd, parentFD: dirFD, name: entry, entries: list(fd)))
                }
            } else {
                let frame = stack.removeLast()
                close(frame.fd)
                if let problem = onDirectoryExit(frame.parentFD, frame.name) {
                    closeAll()
                    return problem
                }
            }
        }
        return nil
    }

    /// Directory-only pre-walk of a folder before it is moved or deleted (both modes). Looks for
    /// protected patterns that can sit anywhere (`SafetyPolicy.nestedDirectoryClass`): a never
    /// match always refuses; a dangerous match refuses unless `allowDangerous`. Uses `d_type` to
    /// skip files, `fstatat` without following symlinks, never enters another volume, and checks
    /// `isCancelled` every 256 folders.
    ///
    /// Fails closed: a subfolder that cannot be read or opened refuses the item
    /// (`unreadableSubfolder`), and a subfolder on another device (a mount point inside the item)
    /// refuses it too (`containsOtherVolume`). `adjust` lets tests alter a subfolder's `stat`.
    static func findProtectedDirectory(
        in item: OpenedItem,
        allowDangerous: Bool,
        isCancelled: () -> Bool,
        adjust: (_ name: String, _ info: inout stat) -> Void = { _, _ in }
    ) -> FileProblem? {
        guard item.isDirectory else { return nil }
        _ = raiseOpenFileLimitOnce
        let rootFD = openat(item.parentFD, item.name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { return .errno(errno, "open") }
        var rootInfo = stat()
        guard fstat(rootFD, &rootInfo) == 0, rootInfo.st_dev == item.info.st_dev, rootInfo.st_ino == item.info.st_ino else {
            close(rootFD)
            return FileProblem(.changedSinceScan, block: .changedSinceScan)
        }
        struct DirFrame {
            var fd: Int32
            var name: String
            var path: String
            var subdirectories: [String]
            var index = 0
        }
        guard let rootSubdirectories = subdirectories(rootFD) else {
            close(rootFD)
            return FileProblem(.unreadableSubfolder, detail: item.canonicalPath)
        }
        var stack = [DirFrame(fd: rootFD, name: item.name, path: item.canonicalPath, subdirectories: rootSubdirectories)]
        defer { stack.forEach { close($0.fd) } }
        var visited = 0
        while let top = stack.indices.last {
            guard stack[top].index < stack[top].subdirectories.count else {
                close(stack.removeLast().fd)
                continue
            }
            let name = stack[top].subdirectories[stack[top].index]
            stack[top].index += 1
            let path = stack[top].path + "/" + name
            if let found = SafetyPolicy.nestedDirectoryClass(name: name, parentName: stack[top].name) {
                if let block = found.block { return FileProblem(.containsProtected, block: block, detail: path) }
                if !allowDangerous { return FileProblem(.containsProtected, detail: path) }
                continue
            }
            visited += 1
            if visited % 256 == 0 && isCancelled() { return FileProblem(.cancelled) }
            var st = stat()
            guard fstatat(stack[top].fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else {
                if errno == ENOENT { continue }  // vanished since it was listed
                return FileProblem(.unreadableSubfolder, detail: path)
            }
            adjust(name, &st)
            guard (st.st_mode & S_IFMT) == S_IFDIR else { continue }
            guard st.st_dev == item.info.st_dev else {
                return FileProblem(.containsOtherVolume, detail: path)
            }
            let fd = openat(stack[top].fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { return FileProblem(.unreadableSubfolder, detail: path) }
            guard let names = subdirectories(fd) else {
                close(fd)
                return FileProblem(.unreadableSubfolder, detail: path)
            }
            stack.append(DirFrame(fd: fd, name: name, path: path, subdirectories: names))
        }
        return nil
    }

    /// Names of the subdirectories of `fd` (`d_type`, with an `fstatat` fallback for unknown
    /// types). nil when the folder cannot be listed completely.
    private static func subdirectories(_ fd: Int32) -> [String]? {
        let copy = dup(fd)
        guard copy >= 0 else { return nil }
        guard let dir = fdopendir(copy) else {
            close(copy)
            return nil
        }
        defer { closedir(dir) }
        var names: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(dir) else {
                if errno != 0 { return nil }
                break
            }
            let type = entry.pointee.d_type
            guard type == DT_DIR || type == DT_UNKNOWN else { continue }
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            if type == DT_UNKNOWN {
                var st = stat()
                guard fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else {
                    if errno == ENOENT { continue }
                    return nil
                }
                guard (st.st_mode & S_IFMT) == S_IFDIR else { continue }
            }
            names.append(name)
        }
        return names
    }

    private static func list(_ fd: Int32) -> [String] {
        let copy = dup(fd)
        guard copy >= 0 else { return [] }
        guard let dir = fdopendir(copy) else {
            close(copy)
            return []
        }
        defer { closedir(dir) }
        var names: [String] = []
        while let entry = readdir(dir) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            if name != "." && name != ".." { names.append(name) }
        }
        return names
    }

    /// Deep trees keep one descriptor per level open.
    private static let raiseOpenFileLimitOnce: Void = {
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else { return }
        let wanted = min(limit.rlim_max, rlim_t(10_240))
        if limit.rlim_cur < wanted {
            limit.rlim_cur = wanted
            setrlimit(RLIMIT_NOFILE, &limit)
        }
    }()
}
