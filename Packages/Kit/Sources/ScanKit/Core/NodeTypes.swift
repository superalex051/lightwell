import Foundation

/// Index of a node in a scan tree. `UInt32.max` is reserved as "no node".
public typealias NodeID = UInt32

/// Per-node flags stored in the arena (fits in 16 bits).
public struct NodeFlags: OptionSet, Sendable, Hashable, Codable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let directory = NodeFlags(rawValue: 1 << 0)
    public static let package = NodeFlags(rawValue: 1 << 1)
    public static let symlink = NodeFlags(rawValue: 1 << 2)
    /// Inode with more than one link. The primary link (smallest path) carries the bytes.
    public static let hardLink = NodeFlags(rawValue: 1 << 3)
    /// Non-primary link of a hard-linked inode: contributes 0 bytes to ancestors.
    public static let hardLinkSecondary = NodeFlags(rawValue: 1 << 4)
    /// Member of an APFS clone family.
    public static let cloned = NodeFlags(rawValue: 1 << 5)
    /// Could not be read (EACCES / EPERM). Size 0, counted as hidden space.
    public static let restricted = NodeFlags(rawValue: 1 << 6)
    public static let mountPoint = NodeFlags(rawValue: 1 << 7)
    public static let firmlinkSkipped = NodeFlags(rawValue: 1 << 8)
    /// Vanished from disk since the scan (deleted or moved).
    public static let missing = NodeFlags(rawValue: 1 << 9)
    /// The folder's listing did not return in time (hung share, pending privacy prompt); the
    /// watchdog gave up on it. Size 0, counted as hidden space. Added by WS1 (bit 12; bits 10
    /// and 11 are used internally by the arena).
    public static let notResponding = NodeFlags(rawValue: 1 << 12)
}

/// Stable on-disk identity of an item, used to detect changes between scan and deletion.
public struct FileIdentity: Sendable, Hashable, Codable {
    public var device: Int32
    public var inode: UInt64

    public init(device: Int32, inode: UInt64) {
        self.device = device
        self.inode = inode
    }
}

/// Which size a scan reports per file.
public enum SizeMode: String, Sendable, Codable, CaseIterable {
    /// Allocated bytes on disk (default for local volumes).
    case allocated
    /// Logical file length (default for network volumes).
    case logical
}

/// Coarse kind of an item, used in summaries and tool results.
public enum ItemKind: String, Sendable, Codable, CaseIterable {
    case file
    case directory
    case package
    case symlink
    case other

    public init(flags: NodeFlags) {
        if flags.contains(.symlink) {
            self = .symlink
        } else if flags.contains(.package) {
            self = .package
        } else if flags.contains(.directory) {
            self = .directory
        } else {
            self = .file
        }
    }
}
