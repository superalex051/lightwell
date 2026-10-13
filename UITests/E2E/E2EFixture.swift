import Darwin
import Foundation

/// Files for the E2E scenarios (PLAN 5.3). Everything lives under
/// `$TMPDIR/lightwell-fixtures/<uuid>/`; deletable items sit in `<fixture>/home`, because in UI test
/// mode the app treats that folder as the home folder and protects everything else.
struct E2EFixture {
    let root: URL
    /// Unique folder under home/Documents, so Reveal opens a Finder window nobody else has open.
    let revealFolder: String

    var name: String { root.lastPathComponent }
    var home: URL { root.appendingPathComponent("home", isDirectory: true) }
    var trash: URL { root.appendingPathComponent(".test-trash", isDirectory: true) }

    func url(_ relative: String) -> URL { root.appendingPathComponent(relative) }
    func exists(_ relative: String) -> Bool { FileManager.default.fileExists(atPath: url(relative).path) }

    /// Relative path and size of every file in the standard tree.
    static func files(revealFolder: String) -> [(String, Int)] {
        [
            ("home/Downloads/old-installer.dmg", 6_000_000),
            ("home/Downloads/notes-archive.zip", 3_000_000),
            ("home/Library/Keychains/login.keychain-db", 200_000),
            ("home/Library/Developer/Xcode/DerivedData/App-1/build.o", 5_000_000),
            ("home/Library/Developer/Xcode/DerivedData/App-2/index.db", 4_000_000),
            ("home/Library/Caches/com.example.app/cache.db", 3_000_000),
            ("home/Library/Logs/old-session.log", 1_500_000),
            ("home/Documents/\(revealFolder)/report.pdf", 2_000_000),
            ("home/Documents/\(revealFolder)/draft.txt", 1_000_000),
        ]
    }

    /// Creates the standard tree in a fresh folder under `area`.
    static func make(in area: URL, name: String = UUID().uuidString) throws -> E2EFixture {
        let root = area.appendingPathComponent(name, isDirectory: true)
        let reveal = "Reports-" + UUID().uuidString.prefix(8).lowercased()
        let fixture = E2EFixture(root: root, revealFolder: reveal)
        for (path, size) in files(revealFolder: reveal) {
            try fixture.write(path, bytes: size)
        }
        return fixture
    }

    /// Writes `bytes` of non-zero data (never sparse, so allocation equals size rounded to blocks).
    func write(_ relative: String, bytes: Int) throws {
        let target = url(relative)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0xA5, count: bytes).write(to: target)
    }

    /// Allocated bytes under `relative` (or the whole fixture), counted like the scanner's oracle:
    /// lstat, `st_blocks * 512` for files and symlinks, directories count 0, each inode once.
    /// Skips the app's own folders in the fixture: `.lightwell-app` (UI test scratch, excluded from
    /// scans) and `.test-trash` (the fixture Trash).
    func allocatedBytes(_ relative: String? = nil) -> UInt64 {
        let start = relative.map(url) ?? root
        let skip = Set([".lightwell-app", ".test-trash"].map { url($0).standardizedFileURL.path })
        var seen = Set<UInt64>()
        var total: UInt64 = 0
        func visit(_ path: String) {
            if skip.contains(path) { return }
            var info = stat()
            guard lstat(path, &info) == 0 else { return }
            if info.st_mode & S_IFMT == S_IFDIR {
                for child in (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? [] {
                    visit((path as NSString).appendingPathComponent(child))
                }
                return
            }
            guard seen.insert(UInt64(info.st_ino)).inserted else { return }
            total += UInt64(info.st_blocks) * 512
        }
        visit(start.standardizedFileURL.path)
        return total
    }

    func delete() {
        guard root.path.contains("/lightwell-fixtures/") else { return }
        try? FileManager.default.removeItem(at: root)
    }
}

/// Files outside the fixture (a sibling folder) that no test may touch (PLAN 5.3 "Guard").
/// They reuse fixture names, so a path mix-up in the app would land on them.
struct SentinelGuard {
    struct Record: Equatable {
        var size: Int64
        var inode: UInt64
        var modified: Int
        var contents: Data
    }

    let root: URL
    private let records: [String: Record]

    static func make(beside fixture: URL) throws -> SentinelGuard {
        let root = fixture.deletingLastPathComponent().appendingPathComponent(fixture.lastPathComponent + "-sentinel", isDirectory: true)
        let files = [
            "home/Downloads/old-installer.dmg",
            "home/Library/Caches/com.example.app/cache.db",
            "home/Library/Developer/Xcode/DerivedData/App-1/build.o",
            "home/Library/Keychains/login.keychain-db",
            "outside.txt",
        ]
        for (index, path) in files.enumerated() {
            let target = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: UInt8(0x30 + index), count: 64_000 + index).write(to: target)
        }
        return SentinelGuard(root: root, records: snapshot(root))
    }

    private init(root: URL, records: [String: Record]) {
        self.root = root
        self.records = records
    }

    private static func snapshot(_ root: URL) -> [String: Record] {
        var result: [String: Record] = [:]
        let base = root.standardizedFileURL.path
        guard let walker = FileManager.default.enumerator(atPath: base) else { return result }
        while let relative = walker.nextObject() as? String {
            let path = (base as NSString).appendingPathComponent(relative)
            var info = stat()
            guard lstat(path, &info) == 0 else { continue }
            let isFile = info.st_mode & S_IFMT == S_IFREG
            result[relative] = Record(
                size: Int64(info.st_size),
                inode: UInt64(info.st_ino),
                modified: info.st_mtimespec.tv_sec * 1_000_000_000 + info.st_mtimespec.tv_nsec,
                contents: isFile ? (FileManager.default.contents(atPath: path) ?? Data()) : Data()
            )
        }
        return result
    }

    /// Paths that were added, removed or changed since `make`.
    func changes() -> [String] {
        let now = Self.snapshot(root)
        var changed: [String] = []
        for (path, record) in records where now[path] != record { changed.append(path) }
        for path in now.keys where records[path] == nil { changed.append("+" + path) }
        return changed.sorted()
    }

    func delete() {
        guard root.path.contains("/lightwell-fixtures/"), root.lastPathComponent.hasSuffix("-sentinel") else { return }
        try? FileManager.default.removeItem(at: root)
    }
}

/// The app's byte formatter (VizKit `ByteFormat`): decimal units, exactly three significant digits.
/// Repeated here because the UI test bundle does not link the package.
enum E2EBytes {
    static func string(_ bytes: UInt64) -> String {
        guard bytes >= 1000 else { return "\(bytes) bytes" }
        let units = ["KB", "MB", "GB", "TB", "PB", "EB"]
        var value = Double(bytes) / 1000
        var unit = 0
        while value >= 999.5, unit < units.count - 1 {
            value /= 1000
            unit += 1
        }
        return "\(value.formatted(.number.precision(.significantDigits(3)))) \(units[unit])"
    }
}
