import Darwin
import Foundation

/// Errors thrown while building fixtures.
public enum FixtureError: Error, CustomStringConvertible, Sendable {
    case escapesRoot(String)
    case posix(call: String, path: String, errno: Int32)
    /// The fixture area is a symlink, not a directory, or not owned by the current user.
    case unsafeFixtureArea(String)

    public var description: String {
        switch self {
        case .escapesRoot(let rel): "relative path escapes the fixture root: \(rel)"
        case .unsafeFixtureArea(let path): "refusing to use the fixture area (symlink, not a directory or not ours): \(path)"
        case .posix(let call, let path, let code): "\(call) failed for \(path): \(String(cString: strerror(code)))"
        }
    }
}

/// Builds throwaway file trees under `$TMPDIR/lightwell-fixtures/<uuid>/` for tests.
///
/// Every path argument is relative to `root` and may not escape it. A sibling sentinel directory
/// (`<uuid>-sentinel`) is created alongside; check `sentinelChanges()` in teardown to prove nothing
/// outside the fixture was touched. Call `tearDown()` when done (also attempted in `deinit`).
///
/// ```swift
/// let fx = try FixtureBuilder()
/// defer { fx.tearDown() }
/// try fx.file("a/b.bin", size: 4096)
/// ```
public final class FixtureBuilder: @unchecked Sendable {
    /// `$TMPDIR/lightwell-fixtures`, symlinks resolved (so it starts with `/private/var/...`).
    public static var fixtureArea: URL {
        let tmp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        return tmp.appendingPathComponent("lightwell-fixtures", isDirectory: true)
    }

    /// Names that exercise Unicode handling: decomposed accent (NFD), emoji, newline, leading dot,
    /// surrounding spaces, CJK.
    public static let unicodeNames: [String] = [
        "Cafe\u{0301} menu.txt",
        "\u{1F4E6} parcel",
        "line\nbreak.txt",
        ".hidden file",
        "  spaced  ",
        "\u{65E5}\u{672C}\u{8A9E}.txt",
    ]

    public let id: UUID
    /// Real path of the fixture root (symlinks resolved).
    public let root: URL
    /// Sibling directory with sentinel files that tests must never touch.
    public let sentinel: URL

    private let lock = NSLock()
    /// Path of the fixture area this builder was created in (verified at init).
    private let areaPath: String
    private var sentinelBaseline: [String: SentinelState] = [:]
    private var tornDown = false

    public init() throws {
        id = UUID()
        let area = Self.fixtureArea
        areaPath = area.path
        try FileManager.default.createDirectory(at: area, withIntermediateDirectories: true)
        guard let areaFD = Self.openArea(area.path) else { throw FixtureError.unsafeFixtureArea(area.path) }
        defer { close(areaFD) }
        Self.sweepStaleFixtures(areaFD: areaFD, now: Date())
        root = area.appendingPathComponent(id.uuidString, isDirectory: true)
        sentinel = area.appendingPathComponent("\(id.uuidString)-sentinel", isDirectory: true)
        for name in [id.uuidString, "\(id.uuidString)-sentinel"] {
            guard mkdirat(areaFD, name, 0o755) == 0 else {
                throw FixtureError.posix(call: "mkdirat", path: area.path + "/" + name, errno: errno)
            }
        }
        try FileManager.default.createDirectory(at: sentinel.appendingPathComponent("nested"), withIntermediateDirectories: false)
        try Data(repeating: 0x5A, count: 8192).write(to: sentinel.appendingPathComponent("keep.bin"))
        try Data("do not touch\n".utf8).write(to: sentinel.appendingPathComponent("keep.txt"))
        try Data(repeating: 0x33, count: 1000).write(to: sentinel.appendingPathComponent("nested/keep2.bin"))
        sentinelBaseline = Self.snapshot(sentinel)
    }

    deinit {
        tearDown()
    }

    /// Fixtures older than this are considered leaked by a crashed test run. Generous on purpose:
    /// fixture mtimes are set once, so a shorter limit could catch a long but live run.
    public static let staleFixtureAge: TimeInterval = 24 * 3600

    /// Opens a fixture area safely: `O_NOFOLLOW | O_DIRECTORY`, then requires a real directory owned
    /// by the current user. Returns nil (and opens nothing) otherwise.
    static func openArea(_ path: String) -> Int32? {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { return nil }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFDIR, st.st_uid == geteuid() else {
            close(fd)
            return nil
        }
        return fd
    }

    /// Removes leaked fixture directories from `area` (default `fixtureArea`). Only direct children
    /// that are real directories (not symlinks), named `<UUID>` or `<UUID>-sentinel`, and last
    /// modified more than `staleFixtureAge` ago are removed. The area itself must pass `openArea`
    /// (not a symlink, a directory, owned by us), otherwise nothing happens. Everything is resolved
    /// relative to that one descriptor, so no path is ever looked up again.
    public static func sweepStaleFixtures(now: Date = Date(), area: URL = fixtureArea) {
        guard let areaFD = openArea(area.path) else { return }
        defer { close(areaFD) }
        sweepStaleFixtures(areaFD: areaFD, now: now)
    }

    private static func sweepStaleFixtures(areaFD: Int32, now: Date) {
        for (name, _) in DirectoryListing.entries(of: areaFD) {
            let base = name.hasSuffix("-sentinel") ? String(name.dropLast("-sentinel".count)) : name
            guard UUID(uuidString: base) != nil else { continue }
            var st = stat()
            guard fstatat(areaFD, name, &st, AT_SYMLINK_NOFOLLOW) == 0, st.st_mode & S_IFMT == S_IFDIR else { continue }
            let modified = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
            guard now.timeIntervalSince(modified) > staleFixtureAge else { continue }
            removeEntry(parentFD: areaFD, name: name)
        }
    }

    // MARK: Paths

    /// Absolute URL for a path relative to the root. Rejects `..` components and absolute paths.
    public func url(_ relative: String) throws -> URL {
        if relative.isEmpty { return root }
        let components = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !relative.hasPrefix("/"), !components.contains("..") else {
            throw FixtureError.escapesRoot(relative)
        }
        return root.appendingPathComponent(relative)
    }

    /// Absolute path string for a relative path.
    public func path(_ relative: String) throws -> String { try url(relative).path }

    private func ensureParent(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    // MARK: Builders

    /// Creates a directory (and intermediates).
    @discardableResult
    public func dir(_ relative: String) throws -> URL {
        let target = try url(relative)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        return target
    }

    /// Creates a regular file of exactly `size` bytes, filled with non-zero data so it is fully allocated.
    @discardableResult
    public func file(_ relative: String, size: Int, byte: UInt8 = 0xA5) throws -> URL {
        let target = try url(relative)
        try ensureParent(target)
        let fd = open(target.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else { throw FixtureError.posix(call: "open", path: target.path, errno: errno) }
        defer { close(fd) }
        try Self.fill(fd: fd, size: size, byte: byte, path: target.path)
        return target
    }

    private static func fill(fd: Int32, size: Int, byte: UInt8, path: String) throws {
        let chunk = [UInt8](repeating: byte, count: min(max(size, 1), 1 << 20))
        var remaining = size
        while remaining > 0 {
            let count = min(remaining, chunk.count)
            let written = chunk.withUnsafeBytes { write(fd, $0.baseAddress, count) }
            guard written == count else { throw FixtureError.posix(call: "write", path: path, errno: errno) }
            remaining -= count
        }
    }

    /// Creates `count` files named `file-00000.bin`... of `size` bytes each inside `relative`.
    public func manyFiles(in relative: String, count: Int, size: Int) throws {
        try dir(relative)
        for index in 0..<count {
            try file("\(relative)/file-\(String(format: "%05d", index)).bin", size: size)
        }
    }

    /// Creates `levels` nested directories `d0/d1/...` under `relative`, with `bottom.bin` of
    /// `fileSize` bytes at the bottom. Uses `mkdirat`/`openat`, so the total path may exceed PATH_MAX.
    /// Returns the deepest directory.
    @discardableResult
    public func deepPath(_ relative: String, levels: Int, fileSize: Int = 4096) throws -> URL {
        raiseOpenFileLimit()
        var current = try dir(relative)
        var fd = open(current.path, O_RDONLY | O_DIRECTORY)
        guard fd >= 0 else { throw FixtureError.posix(call: "open", path: current.path, errno: errno) }
        defer { close(fd) }
        for level in 0..<levels {
            let name = "d\(level)"
            current = current.appendingPathComponent(name)
            guard mkdirat(fd, name, 0o755) == 0 || errno == EEXIST else {
                throw FixtureError.posix(call: "mkdirat", path: current.path, errno: errno)
            }
            let next = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard next >= 0 else { throw FixtureError.posix(call: "openat", path: current.path, errno: errno) }
            close(fd)
            fd = next
        }
        if fileSize > 0 {
            let file = openat(fd, "bottom.bin", O_WRONLY | O_CREAT | O_TRUNC, 0o644)
            guard file >= 0 else { throw FixtureError.posix(call: "openat", path: current.path + "/bottom.bin", errno: errno) }
            defer { close(file) }
            try Self.fill(fd: file, size: fileSize, byte: 0xA5, path: current.path + "/bottom.bin")
        }
        return current
    }

    /// Creates a hard link at `relative` pointing to the existing `target` (both relative).
    @discardableResult
    public func hardLink(_ relative: String, to target: String) throws -> URL {
        let link = try url(relative)
        let source = try url(target)
        try ensureParent(link)
        guard Darwin.link(source.path, link.path) == 0 else {
            throw FixtureError.posix(call: "link", path: link.path, errno: errno)
        }
        return link
    }

    /// Creates an APFS clone of `source` at `relative` (`copyfile` with `COPYFILE_CLONE_FORCE`).
    /// Throws if the volume does not support clones.
    @discardableResult
    public func clone(_ relative: String, of source: String) throws -> URL {
        let destination = try url(relative)
        let origin = try url(source)
        try ensureParent(destination)
        guard copyfile(origin.path, destination.path, nil, copyfile_flags_t(COPYFILE_CLONE_FORCE)) == 0 else {
            throw FixtureError.posix(call: "copyfile(CLONE_FORCE)", path: destination.path, errno: errno)
        }
        return destination
    }

    /// Creates a symlink at `relative` whose content is `destination` verbatim
    /// (relative like `../x`, or absolute such as the sentinel directory).
    @discardableResult
    public func symlink(_ relative: String, to destination: String) throws -> URL {
        let link = try url(relative)
        try ensureParent(link)
        guard Darwin.symlink(destination, link.path) == 0 else {
            throw FixtureError.posix(call: "symlink", path: link.path, errno: errno)
        }
        return link
    }

    /// Creates a sparse file with logical size `logicalSize` and (almost) nothing allocated.
    @discardableResult
    public func sparseFile(_ relative: String, logicalSize: Int64) throws -> URL {
        let target = try url(relative)
        try ensureParent(target)
        let fd = open(target.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else { throw FixtureError.posix(call: "open", path: target.path, errno: errno) }
        defer { close(fd) }
        guard ftruncate(fd, off_t(logicalSize)) == 0 else {
            throw FixtureError.posix(call: "ftruncate", path: target.path, errno: errno)
        }
        return target
    }

    /// Creates a minimal `.app` bundle: Info.plist, an executable of `executableSize` bytes and a resource.
    @discardableResult
    public func appBundle(_ relative: String, executableSize: Int = 64 * 1024, resourceSize: Int = 16 * 1024) throws -> URL {
        precondition(relative.hasSuffix(".app"), "appBundle path must end in .app")
        let app = try dir(relative)
        let name = app.deletingPathExtension().lastPathComponent
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>CFBundleIdentifier</key><string>test.fixture.\(name.filter(\.isLetter))</string>
        <key>CFBundleExecutable</key><string>\(name)</string>
        <key>CFBundlePackageType</key><string>APPL</string>
        </dict></plist>
        """
        try dir("\(relative)/Contents/MacOS")
        try Data(plist.utf8).write(to: app.appendingPathComponent("Contents/Info.plist"))
        try file("\(relative)/Contents/MacOS/\(name)", size: executableSize)
        try file("\(relative)/Contents/Resources/Assets.car", size: resourceSize)
        return app
    }

    /// Creates a generic package directory (for example `.bundle`, `.framework`) with one file inside.
    @discardableResult
    public func package(_ relative: String, contentSize: Int = 32 * 1024) throws -> URL {
        let package = try dir(relative)
        try file("\(relative)/Contents/payload.bin", size: contentSize)
        return package
    }

    /// Creates a file of `size` bytes and sets the user immutable flag (`uchg`, UF_IMMUTABLE),
    /// so unlinking it fails until the flag is cleared. Teardown clears it.
    @discardableResult
    public func lockedFile(_ relative: String, size: Int) throws -> URL {
        let target = try file(relative, size: size)
        guard chflags(target.path, UInt32(UF_IMMUTABLE)) == 0 else {
            throw FixtureError.posix(call: "chflags", path: target.path, errno: errno)
        }
        return target
    }

    /// Creates a directory with some content and then `chmod 000` so it cannot be read.
    /// Permissions are restored in `tearDown()`.
    @discardableResult
    public func restrictedDir(_ relative: String, contentSize: Int = 4096) throws -> URL {
        let target = try dir(relative)
        if contentSize > 0 { try file("\(relative)/secret.bin", size: contentSize) }
        guard chmod(target.path, 0) == 0 else { throw FixtureError.posix(call: "chmod", path: target.path, errno: errno) }
        return target
    }

    // MARK: Sentinel

    public struct SentinelState: Hashable, Sendable {
        public var size: Int64
        public var inode: UInt64
        public var mode: UInt16
        public var mtimeSeconds: Int
        public var mtimeNanos: Int
    }

    private static func snapshot(_ dir: URL) -> [String: SentinelState] {
        var result: [String: SentinelState] = [:]
        guard let enumerator = FileManager.default.enumerator(atPath: dir.path) else { return result }
        while let rel = enumerator.nextObject() as? String {
            var st = stat()
            guard lstat(dir.appendingPathComponent(rel).path, &st) == 0 else { continue }
            result[rel] = SentinelState(
                size: Int64(st.st_size), inode: UInt64(st.st_ino), mode: st.st_mode,
                mtimeSeconds: st.st_mtimespec.tv_sec, mtimeNanos: st.st_mtimespec.tv_nsec
            )
        }
        return result
    }

    /// Relative paths in the sentinel directory that were added, removed or modified since setup.
    /// Empty means nothing outside the fixture was touched.
    public func sentinelChanges() -> [String] {
        let now = Self.snapshot(sentinel)
        let keys = Set(now.keys).union(sentinelBaseline.keys)
        return keys.filter { now[$0] != sentinelBaseline[$0] }.sorted()
    }

    // MARK: Teardown

    /// Deletes the fixture root and its sentinel (restoring permissions and clearing flags on the
    /// way). Idempotent. The area is reopened with the same guard as `init`; if it is no longer a
    /// real directory owned by us, nothing is deleted.
    public func tearDown() {
        let alreadyDone = lock.withLock { () -> Bool in
            defer { tornDown = true }
            return tornDown
        }
        guard !alreadyDone, let areaFD = Self.openArea(areaPath) else { return }
        defer { close(areaFD) }
        Self.removeEntry(parentFD: areaFD, name: id.uuidString)
        Self.removeEntry(parentFD: areaFD, name: "\(id.uuidString)-sentinel")
    }

    /// Removes the entry `name` of the directory open at `parentFD`, and everything below it, with
    /// `*at` calls only, iteratively (handles paths deeper than PATH_MAX, mode 000 directories and
    /// uchg flags). Never follows symlinks and never resolves a path string.
    private static func removeEntry(parentFD: Int32, name: String) {
        precondition(!name.isEmpty && !name.contains("/") && name != "." && name != "..")
        raiseOpenFileLimit()
        func unlinkClearingFlags(_ dirFD: Int32, _ child: String) {
            guard unlinkat(dirFD, child, 0) != 0, errno == EPERM else { return }
            // uchg/schg set: clear the flags through a descriptor relative to the parent
            // (O_SYMLINK opens a link itself, never its target), then retry.
            let itemFD = openat(dirFD, child, O_RDONLY | O_SYMLINK | O_NONBLOCK)
            if itemFD >= 0 {
                fchflags(itemFD, 0)
                close(itemFD)
            }
            unlinkat(dirFD, child, 0)
        }
        fchmodat(parentFD, name, 0o755, AT_SYMLINK_NOFOLLOW)
        let topFD = openat(parentFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard topFD >= 0 else {
            // Not a directory (or a symlink): remove just the entry itself.
            unlinkClearingFlags(parentFD, name)
            return
        }
        fchflags(topFD, 0)
        struct Frame {
            var fd: Int32
            var name: String
            var pendingDirs: [String]
        }
        func makeFrame(_ fd: Int32, name: String) -> Frame {
            var dirs: [String] = []
            for (child, type) in DirectoryListing.entries(of: fd) {
                if type == DT_DIR {
                    dirs.append(child)
                } else {
                    unlinkClearingFlags(fd, child)
                }
            }
            return Frame(fd: fd, name: name, pendingDirs: dirs)
        }
        var stack = [makeFrame(topFD, name: name)]
        while !stack.isEmpty {
            if let child = stack[stack.count - 1].pendingDirs.popLast() {
                let dirFD = stack[stack.count - 1].fd
                fchmodat(dirFD, child, 0o755, AT_SYMLINK_NOFOLLOW)
                let childFD = openat(dirFD, child, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                if childFD >= 0 {
                    fchflags(childFD, 0)
                    stack.append(makeFrame(childFD, name: child))
                } else {
                    unlinkat(dirFD, child, AT_REMOVEDIR)
                }
            } else {
                let frame = stack.removeLast()
                close(frame.fd)
                unlinkat(stack.last?.fd ?? parentFD, frame.name, AT_REMOVEDIR)
            }
        }
    }
}

/// Reads directory entries from a descriptor without disturbing it.
enum DirectoryListing {
    /// Names (excluding `.` and `..`) and `d_type` of every entry of the directory open at `fd`.
    static func entries(of fd: Int32) -> [(String, UInt8)] {
        let dupFD = dup(fd)
        guard dupFD >= 0 else { return [] }
        lseek(dupFD, 0, SEEK_SET)
        guard let handle = fdopendir(dupFD) else {
            close(dupFD)
            return []
        }
        defer { closedir(handle) }
        rewinddir(handle)
        var result: [(String, UInt8)] = []
        while let entry = readdir(handle) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
            }
            if name != "." && name != ".." { result.append((name, entry.pointee.d_type)) }
        }
        return result
    }
}
