import AppKit
import Foundation
import Synchronization

public enum VolumeKind: String, Sendable, Hashable, Codable, CaseIterable {
    case internalDisk
    case external
    case removable
    case network
    case diskImage
    case unknown
}

/// One mounted, user-facing volume. Frozen contract (PLAN 4.3).
public struct VolumeInfo: Identifiable, Sendable, Hashable, Codable {
    public var url: URL
    public var name: String
    public var kind: VolumeKind
    /// File system type name, e.g. "apfs", "smbfs".
    public var fsType: String
    public var capacity: UInt64
    public var available: UInt64
    /// `volumeAvailableCapacityForImportantUsage` (includes purgeable space).
    public var availableImportant: UInt64
    public var isReadOnly: Bool
    public var isEncrypted: Bool
    public var isRemovable: Bool
    public var isNetwork: Bool
    public var isSSD: Bool
    public var supportsClones: Bool
    /// Bytes used by other volumes in the same APFS container (`ATTR_VOL_SIZE - (SPACEUSED +
    /// SPACEFREE)`; for the root volume the Data volume's usage is excluded because a scan of
    /// `/` covers it). 0 when unknown or not APFS. Added by WS1.
    public var otherVolumes: UInt64

    public var id: String { url.path }

    public init(
        url: URL,
        name: String,
        kind: VolumeKind,
        fsType: String,
        capacity: UInt64,
        available: UInt64,
        availableImportant: UInt64,
        isReadOnly: Bool = false,
        isEncrypted: Bool = false,
        isRemovable: Bool = false,
        isNetwork: Bool = false,
        isSSD: Bool = true,
        supportsClones: Bool = true,
        otherVolumes: UInt64 = 0
    ) {
        self.url = url
        self.name = name
        self.kind = kind
        self.fsType = fsType
        self.capacity = capacity
        self.available = available
        self.availableImportant = availableImportant
        self.isReadOnly = isReadOnly
        self.isEncrypted = isEncrypted
        self.isRemovable = isRemovable
        self.isNetwork = isNetwork
        self.isSSD = isSSD
        self.supportsClones = supportsClones
        self.otherVolumes = otherVolumes
    }

    private enum CodingKeys: String, CodingKey {
        case url, name, kind, fsType, capacity, available, availableImportant, isReadOnly, isEncrypted
        case isRemovable, isNetwork, isSSD, supportsClones, otherVolumes
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            url: try c.decode(URL.self, forKey: .url),
            name: try c.decode(String.self, forKey: .name),
            kind: try c.decode(VolumeKind.self, forKey: .kind),
            fsType: try c.decode(String.self, forKey: .fsType),
            capacity: try c.decode(UInt64.self, forKey: .capacity),
            available: try c.decode(UInt64.self, forKey: .available),
            availableImportant: try c.decode(UInt64.self, forKey: .availableImportant),
            isReadOnly: try c.decodeIfPresent(Bool.self, forKey: .isReadOnly) ?? false,
            isEncrypted: try c.decodeIfPresent(Bool.self, forKey: .isEncrypted) ?? false,
            isRemovable: try c.decodeIfPresent(Bool.self, forKey: .isRemovable) ?? false,
            isNetwork: try c.decodeIfPresent(Bool.self, forKey: .isNetwork) ?? false,
            isSSD: try c.decodeIfPresent(Bool.self, forKey: .isSSD) ?? true,
            supportsClones: try c.decodeIfPresent(Bool.self, forKey: .supportsClones) ?? true,
            otherVolumes: try c.decodeIfPresent(UInt64.self, forKey: .otherVolumes) ?? 0
        )
    }
}

/// Mounted volumes and mount/unmount updates. Frozen contract (PLAN 4.3).
///
/// Volumes come from `FileManager.mountedVolumeURLs` (hidden volumes skipped, so APFS siblings
/// such as Data, Preboot or VM are folded into the user-facing volume of their group) with
/// `URLResourceKey` values, DiskArbitration (disk images) and the I/O Registry (SSD).
public enum VolumeCatalog {
    private static let keys: [URLResourceKey] = [
        .volumeNameKey, .volumeLocalizedNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
        .volumeAvailableCapacityForImportantUsageKey, .volumeIsReadOnlyKey, .volumeIsEncryptedKey,
        .volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsInternalKey, .volumeIsLocalKey,
        .volumeSupportsFileCloningKey, .volumeTypeNameKey, .volumeIsBrowsableKey, .volumeIsRootFileSystemKey,
    ]

    public static func current() -> [VolumeInfo] {
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        var result: [VolumeInfo] = []
        for url in urls {
            if let info = volumeInfo(for: url) { result.append(info) }
        }
        // Root volume first, then by name.
        return result.sorted { a, b in
            if (a.url.path == "/") != (b.url.path == "/") { return a.url.path == "/" }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// The volume info for one mounted volume URL, or `nil` for volumes that are not user facing.
    static func volumeInfo(for url: URL) -> VolumeInfo? {
        guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
        let path = url.path
        if values.volumeIsBrowsable == false { return nil }
        if path.hasPrefix(VolumeProbe.dataVolumePath + "/") || path.hasPrefix("/System/Volumes/") { return nil }
        let fileSystem = VolumeProbe.fileSystem(at: path)
        let isNetwork = !(values.volumeIsLocal ?? fileSystem?.isLocal ?? true)
        let isInternal = values.volumeIsInternal ?? false
        let isRemovable = (values.volumeIsRemovable ?? false) || (values.volumeIsEjectable ?? false)
        var isDiskImage = false
        var isSSD = !isNetwork
        if let device = fileSystem?.deviceName, !isNetwork {
            if let description = VolumeProbe.diskDescription(deviceName: device),
               let model = description[kDADiskDescriptionDeviceModelKey as String] as? String {
                isDiskImage = model.trimmingCharacters(in: .whitespaces) == "Disk Image"
            }
            if let solid = VolumeProbe.isSolidState(deviceName: device) { isSSD = solid }
        }
        let kind: VolumeKind
        if isNetwork {
            kind = .network
        } else if isDiskImage {
            kind = .diskImage
        } else if isInternal {
            kind = .internalDisk
        } else if isRemovable {
            kind = .removable
        } else if values.volumeIsInternal == false {
            kind = .external
        } else {
            kind = .unknown
        }
        let fsType = (values.volumeTypeName ?? fileSystem?.fsType ?? "").lowercased()
        let other = fsType == "apfs" ? VolumeProbe.otherVolumesBytes(path) : 0
        return VolumeInfo(
            url: URL(fileURLWithPath: path, isDirectory: true),
            name: values.volumeLocalizedName ?? values.volumeName ?? url.lastPathComponent,
            kind: kind,
            fsType: fsType,
            capacity: UInt64(max(values.volumeTotalCapacity ?? 0, 0)),
            available: UInt64(max(values.volumeAvailableCapacity ?? 0, 0)),
            availableImportant: UInt64(max(values.volumeAvailableCapacityForImportantUsage ?? 0, 0)),
            isReadOnly: values.volumeIsReadOnly ?? false,
            isEncrypted: values.volumeIsEncrypted ?? false,
            isRemovable: isRemovable,
            isNetwork: isNetwork,
            isSSD: isSSD,
            supportsClones: values.volumeSupportsFileCloning ?? false,
            otherVolumes: other
        )
    }

    /// The volume containing `url` (its mount point), when it is a user-facing volume.
    public static func volume(containing url: URL) -> VolumeInfo? {
        guard let mount = VolumeProbe.fileSystem(at: url.path)?.mountPoint else { return nil }
        let path = mount == VolumeProbe.dataVolumePath ? "/" : mount
        return volumeInfo(for: URL(fileURLWithPath: path, isDirectory: true))
    }

    /// Yields `current()` now and again after every mount, unmount or rename
    /// (`NSWorkspace` notifications, coalesced over 0.5 s).
    public static func updates() -> AsyncStream<[VolumeInfo]> {
        let (stream, continuation) = AsyncStream.makeStream(of: [VolumeInfo].self, bufferingPolicy: .bufferingNewest(4))
        continuation.yield(current())
        let center = NSWorkspace.shared.notificationCenter
        let queue = DispatchQueue(label: "com.alexluncan.lightwell.volumes")
        let pending = Mutex<Bool>(false)
        let names: [Notification.Name] = [
            NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification,
        ]
        let tokens = ObserverTokens(names.map { name in
            center.addObserver(forName: name, object: nil, queue: nil) { _ in
                let shouldSchedule = pending.withLock { scheduled -> Bool in
                    defer { scheduled = true }
                    return !scheduled
                }
                guard shouldSchedule else { return }
                queue.asyncAfter(deadline: .now() + 0.5) {
                    pending.withLock { $0 = false }
                    continuation.yield(current())
                }
            }
        })
        continuation.onTermination = { _ in
            for token in tokens.tokens { center.removeObserver(token) }
        }
        return stream
    }
}

/// Notification observer tokens moved into a `@Sendable` termination handler.
private final class ObserverTokens: @unchecked Sendable {
    let tokens: [any NSObjectProtocol]
    init(_ tokens: [any NSObjectProtocol]) { self.tokens = tokens }
}
