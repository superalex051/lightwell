import Foundation
@testable import RulesKit
import TestSupport

/// A home that does not exist on disk (paths are only strings; nothing is read or written).
let virtualHome = "/Users/lightwell-test-home"

/// File metadata described in memory, keyed by absolute path.
struct FakeMetadata: FileMetadataProviding {
    var modified: [String: Date] = [:]
    var added: [String: Date] = [:]
    var existing: Set<String> = []

    func modificationDate(atPath path: String) -> Date? { modified[path] }
    func addedDate(atPath path: String) -> Date? { added[path] }
    func itemExists(atPath path: String) -> Bool { existing.contains(path) }
}

let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)

func daysAgo(_ days: Double) -> Date { fixedNow.addingTimeInterval(-days * 86_400) }

func expand(_ path: String, home: String) -> String { CanonicalPath.expandTilde(path, home: home) }

/// The same path written three ways: as is, behind the Data volume firmlink, and upper-cased.
func variants(_ absolute: String) -> [String] {
    [absolute, "/System/Volumes/Data" + (absolute == "/" ? "" : absolute), absolute.uppercased()]
}

/// Runs `body` with a fixture home (`<fixture>/home`, real directory) and tears it down after.
func withFixtureHome(_ body: (FixtureBuilder, String) throws -> Void) throws {
    let fx = try FixtureBuilder()
    defer { fx.tearDown() }
    let home = try fx.dir("home").path
    try body(fx, home)
}
