import Darwin
import Foundation

/// File facts the rule engine needs beyond the scanned tree (ages, marker files). Injected so
/// tests can describe ages without touching real files.
public protocol FileMetadataProviding: Sendable {
    /// Modification date of the item itself (symlinks are not followed).
    func modificationDate(atPath path: String) -> Date?
    /// When the item was added to its folder (Downloads), if the file system knows.
    func addedDate(atPath path: String) -> Date?
    /// Whether an item exists at `path` (symlinks are not followed).
    func itemExists(atPath path: String) -> Bool
}

/// Reads metadata from the real file system with `lstat` and resource values.
public struct LiveFileMetadata: FileMetadataProviding {
    public init() {}

    public func modificationDate(atPath path: String) -> Date? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec) + TimeInterval(st.st_mtimespec.tv_nsec) / 1e9)
    }

    public func addedDate(atPath path: String) -> Date? {
        let url = URL(fileURLWithPath: path)
        return (try? url.resourceValues(forKeys: [.addedToDirectoryDateKey]))?.addedToDirectoryDate
    }

    public func itemExists(atPath path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0
    }
}
