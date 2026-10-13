import AppKit
import Darwin
import Foundation

/// The user's real Trash (`FileManager.trashItem`). The caller keeps the resulting URL so the
/// item can later be deleted for good on its own.
public struct SystemTrash: TrashProviding {
    public init() {}

    public func trash(_ url: URL) throws -> URL? {
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        return resulting as URL?
    }
}

/// Test double: moves items into `<root>/.test-trash` with an exclusive rename, so tests never
/// touch the real Trash.
public struct FixtureTrash: TrashProviding {
    public static let folderName = ".test-trash"
    public let directory: URL

    public init(root: URL) {
        directory = root.appendingPathComponent(Self.folderName, isDirectory: true)
    }

    public func trash(_ url: URL) throws -> URL? {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
        guard renamex_np(url.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return destination
    }
}

/// Whether an app is running (rule preconditions such as "Xcode must be closed").
public protocol RunningAppChecking: Sendable {
    func isRunning(bundleID: String) -> Bool
}

/// Asks the system which apps are running.
public struct WorkspaceRunningApps: RunningAppChecking {
    public init() {}

    public func isRunning(bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }
}
