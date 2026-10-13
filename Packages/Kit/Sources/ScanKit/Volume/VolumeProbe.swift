import CoreFoundation
import Darwin
import DiskArbitration
import Foundation
import IOKit

/// File system facts for a path (from `statfs`).
struct FileSystemInfo: Sendable {
    var fsType: String
    var isLocal: Bool
    var isReadOnly: Bool
    var mountPoint: String
    /// `f_mntfromname`, for example `/dev/disk3s1s1`.
    var deviceName: String
    /// Objects in use (`f_files - f_ffree`), when the file system reports it.
    var objectsInUse: UInt64?
}

/// Low-level volume probes shared by the scanner and the volume catalog.
enum VolumeProbe {
    static func fileSystem(at path: String) -> FileSystemInfo? {
        var info = statfs()
        guard statfs(path, &info) == 0 else { return nil }
        func string<T>(_ tuple: T) -> String {
            withUnsafeBytes(of: tuple) { raw in
                let bytes = raw.prefix { $0 != 0 }
                return String(decoding: bytes, as: UTF8.self)
            }
        }
        let used = info.f_files >= info.f_ffree ? info.f_files - info.f_ffree : 0
        return FileSystemInfo(
            fsType: string(info.f_fstypename),
            isLocal: info.f_flags & UInt32(MNT_LOCAL) != 0,
            isReadOnly: info.f_flags & UInt32(MNT_RDONLY) != 0,
            mountPoint: string(info.f_mntonname),
            deviceName: string(info.f_mntfromname),
            objectsInUse: info.f_files > 0 ? used : nil
        )
    }

    /// `VOL_CAP_INT_CLONE` from `getattrlist(ATTR_VOL_CAPABILITIES)` on the volume of `path`.
    static func supportsClones(at path: String) -> Bool {
        guard let mount = fileSystem(at: path)?.mountPoint else { return false }
        var list = attrlist()
        list.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        list.volattr = 0x8000_0000 | 0x0002_0000 // ATTR_VOL_INFO | ATTR_VOL_CAPABILITIES
        var buffer = [UInt8](repeating: 0, count: 64)
        let result = buffer.withUnsafeMutableBytes { raw in
            getattrlist(mount, &list, raw.baseAddress, raw.count, 0)
        }
        guard result == 0 else { return false }
        return buffer.withUnsafeBytes { raw in
            // u32 length, then vol_capabilities_attr_t { capabilities[4], valid[4] }.
            let interfaces = raw.loadUnaligned(fromByteOffset: 4 + 4, as: UInt32.self)
            let valid = raw.loadUnaligned(fromByteOffset: 4 + 16 + 4, as: UInt32.self)
            let clone: UInt32 = 0x0001_0000
            return interfaces & valid & clone != 0
        }
    }

    /// `ATTR_VOL_SIZE`, `ATTR_VOL_SPACEUSED`, `ATTR_VOL_SPACEFREE` of the volume mounted at `mountPoint`.
    static func spaceAttributes(_ mountPoint: String) -> (size: UInt64, used: UInt64, free: UInt64)? {
        var list = attrlist()
        list.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        // ATTR_VOL_INFO | ATTR_VOL_SIZE | ATTR_VOL_SPACEFREE | ATTR_VOL_SPACEUSED
        list.volattr = 0x8000_0000 | 0x0000_0004 | 0x0000_0008 | 0x0080_0000
        var buffer = [UInt8](repeating: 0, count: 64)
        let result = buffer.withUnsafeMutableBytes { raw in
            getattrlist(mountPoint, &list, raw.baseAddress, raw.count, 0)
        }
        guard result == 0 else { return nil }
        return buffer.withUnsafeBytes { raw in
            let size = raw.loadUnaligned(fromByteOffset: 4, as: Int64.self)
            let free = raw.loadUnaligned(fromByteOffset: 12, as: Int64.self)
            let used = raw.loadUnaligned(fromByteOffset: 20, as: Int64.self)
            return (UInt64(max(size, 0)), UInt64(max(used, 0)), UInt64(max(free, 0)))
        }
    }

    /// Bytes used by other volumes in the same APFS container as the volume at `mountPoint`.
    /// For the root volume the Data volume is part of the scan (firmlinks), so its usage is
    /// not counted as "other".
    static func otherVolumesBytes(_ mountPoint: String) -> UInt64 {
        guard let space = spaceAttributes(mountPoint) else { return 0 }
        var accounted = space.used + space.free
        if mountPoint == "/", let data = fileSystem(at: dataVolumePath), data.mountPoint == dataVolumePath,
           let dataSpace = spaceAttributes(dataVolumePath) {
            accounted += dataSpace.used
        }
        return space.size > accounted ? space.size - accounted : 0
    }

    static let dataVolumePath = "/System/Volumes/Data"

    /// Medium type of the disk behind `deviceName` from the I/O Registry; `nil` when unknown.
    static func isSolidState(deviceName: String) -> Bool? {
        guard deviceName.hasPrefix("/dev/"), let session = DASessionCreate(kCFAllocatorDefault) else { return nil }
        let bsdName = String(deviceName.dropFirst(5))
        guard let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, bsdName) else { return nil }
        let media = DADiskCopyIOMedia(disk)
        guard media != 0 else { return nil }
        defer { IOObjectRelease(media) }
        let options = IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
        guard let property = IORegistryEntrySearchCFProperty(media, kIOServicePlane, "Device Characteristics" as CFString, kCFAllocatorDefault, options),
              let characteristics = property as? [String: Any],
              let medium = characteristics["Medium Type"] as? String
        else { return nil }
        return medium == "Solid State"
    }

    /// DiskArbitration description of the disk behind `deviceName`.
    static func diskDescription(deviceName: String) -> [String: Any]? {
        guard deviceName.hasPrefix("/dev/"), let session = DASessionCreate(kCFAllocatorDefault) else { return nil }
        guard let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, String(deviceName.dropFirst(5))),
              let description = DADiskCopyDescription(disk) as? [String: Any]
        else { return nil }
        return description
    }
}

/// `/usr/share/firmlinks` support (scans of `/`).
enum Firmlinks {
    static let file = "/usr/share/firmlinks"

    /// Parses "source<TAB>target" lines. Targets are relative to the Data volume root.
    static func parse(_ text: String) -> [(source: String, target: String)] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2 else { return nil }
            let source = parts[0].trimmingCharacters(in: .whitespaces)
            let target = parts[1].trimmingCharacters(in: .whitespaces)
            guard source.hasPrefix("/"), !target.isEmpty else { return nil }
            return (source, target)
        }
    }

    /// `(dev, ino)` of every firmlink target inside the Data volume; these are skipped when the
    /// walk of `/` reaches `/System/Volumes/Data`, because they were already seen at their
    /// natural paths.
    static func skipSet(dataVolume: String = VolumeProbe.dataVolumePath, file: String = Firmlinks.file) -> Set<FileIdentity> {
        guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { return [] }
        var result = Set<FileIdentity>()
        for (_, target) in parse(text) {
            var info = stat()
            let path = dataVolume + "/" + target
            if lstat(path, &info) == 0 {
                result.insert(FileIdentity(device: info.st_dev, inode: UInt64(info.st_ino)))
            }
        }
        return result
    }
}
