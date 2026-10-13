import XCTest

/// Self-test of the sentinel guard every E2E test ends with: it must report a changed, an added
/// and a removed file, and nothing when the folder is untouched. No app launch.
final class SentinelGuardTests: XCTestCase {
    private var sentinels: [SentinelGuard] = []

    override func tearDown() {
        sentinels.forEach { $0.delete() }
        sentinels = []
    }

    private func makeGuard() throws -> SentinelGuard {
        let fixture = E2ETestCase.fixtureArea.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sentinel = try SentinelGuard.make(beside: fixture)
        sentinels.append(sentinel)
        return sentinel
    }

    func testUntouchedFolderReportsNothing() throws {
        let sentinel = try makeGuard()
        XCTAssertEqual(sentinel.changes(), [])
    }

    func testModifiedFileIsReported() throws {
        let sentinel = try makeGuard()
        let file = sentinel.root.appendingPathComponent("outside.txt")
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0x21]))
        try handle.close()
        XCTAssertTrue(sentinel.changes().contains("outside.txt"), "\(sentinel.changes())")
    }

    func testSameSizeRewriteIsReported() throws {
        let sentinel = try makeGuard()
        let file = sentinel.root.appendingPathComponent("home/Downloads/old-installer.dmg")
        let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int)
        try Data(repeating: 0x7E, count: size).write(to: file)
        XCTAssertTrue(sentinel.changes().contains("home/Downloads/old-installer.dmg"), "\(sentinel.changes())")
    }

    func testAddedAndRemovedFilesAreReported() throws {
        let sentinel = try makeGuard()
        try Data([1, 2, 3]).write(to: sentinel.root.appendingPathComponent("home/Downloads/new.bin"))
        try FileManager.default.removeItem(at: sentinel.root.appendingPathComponent("home/Library/Keychains/login.keychain-db"))
        let changes = sentinel.changes()
        XCTAssertTrue(changes.contains("+home/Downloads/new.bin"), "\(changes)")
        XCTAssertTrue(changes.contains("home/Library/Keychains/login.keychain-db"), "\(changes)")
    }
}
