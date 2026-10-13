import Darwin

/// Object types from `sys/vnode.h` (`enum vtype`).
enum ObjectType {
    static let regular: UInt32 = 1
    static let directory: UInt32 = 2
    static let symlink: UInt32 = 5
}

/// One directory entry as returned by `getattrlistbulk`.
struct ListedEntry {
    /// Offset and length of the name (no trailing NUL) in the lister's name scratch.
    var nameStart: Int
    var nameLength: Int
    var objectType: UInt32
    var device: Int32
    var fileID: UInt64
    var linkCount: UInt32
    var mountStatus: UInt32
    var totalSize: UInt64
    var allocSize: UInt64
    var privateSize: UInt64
    var cloneID: UInt64
    var hasCloneInfo: Bool
    /// `ATTR_CMN_ERROR`: non-zero when the entry's attributes could not be read (the scanner keeps
    /// such an entry, empty, flagged restricted).
    var error: UInt32

    var isDirectory: Bool { objectType == ObjectType.directory }
    var isSymlink: Bool { objectType == ObjectType.symlink }
    /// Mount point or automount trigger: never entered (except the Data volume when scanning `/`).
    var isMountBoundary: Bool { isDirectory && (mountStatus & 0x3) != 0 }

    func size(_ mode: SizeMode) -> UInt64 {
        isDirectory ? 0 : (mode == .allocated ? allocSize : totalSize)
    }

    /// Bytes shared with other clones (allocated minus private).
    var sharedBytes: UInt64 {
        guard hasCloneInfo, objectType == ObjectType.regular, allocSize > privateSize else { return 0 }
        return allocSize - privateSize
    }
}

/// Thin wrapper around `getattrlistbulk` with the attribute set of PLAN 2.4.
struct BulkLister {
    /// Per-worker buffer size: 64 KB means fewer syscalls than the classic 4 KB.
    static let bufferSize = 64 * 1024

    private static let cmnReturnedAttrs: UInt32 = 0x8000_0000
    private static let cmnName: UInt32 = 0x0000_0001
    private static let cmnDevID: UInt32 = 0x0000_0002
    private static let cmnObjType: UInt32 = 0x0000_0008
    private static let cmnFileID: UInt32 = 0x0200_0000
    private static let cmnError: UInt32 = 0x2000_0000
    private static let dirLinkCount: UInt32 = 0x0000_0001
    private static let dirMountStatus: UInt32 = 0x0000_0004
    private static let fileLinkCount: UInt32 = 0x0000_0001
    private static let fileTotalSize: UInt32 = 0x0000_0002
    private static let fileAllocSize: UInt32 = 0x0000_0004
    private static let extPrivateSize: UInt32 = 0x0000_0008
    private static let extCloneID: UInt32 = 0x0000_0100
    private static let optPackInvalAttrs: UInt64 = 0x0000_0008
    private static let optAttrCmnExtended: UInt64 = 0x0000_0020

    let wantClones: Bool
    private let options: UInt64
    private var attributes: attrlist

    init(wantClones: Bool) {
        self.wantClones = wantClones
        var list = attrlist()
        list.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        list.commonattr = Self.cmnReturnedAttrs | Self.cmnName | Self.cmnDevID | Self.cmnObjType | Self.cmnFileID | Self.cmnError
        list.dirattr = Self.dirLinkCount | Self.dirMountStatus
        list.fileattr = Self.fileLinkCount | Self.fileTotalSize | Self.fileAllocSize
        var options = Self.optPackInvalAttrs
        if wantClones {
            list.forkattr = Self.extPrivateSize | Self.extCloneID
            options |= Self.optAttrCmnExtended
        }
        attributes = list
        self.options = options
    }

    /// Lists every entry of the open directory `fd`, appending to `entries` and `names`.
    /// `heartbeat` runs after every batch; returning false stops early.
    /// Returns 0, or the errno that ended the listing.
    func list(
        fd: Int32,
        buffer: UnsafeMutableRawBufferPointer,
        entries: inout [ListedEntry],
        names: inout [UInt8],
        heartbeat: () -> Bool
    ) -> Int32 {
        var attributes = attributes
        while true {
            let count = getattrlistbulk(fd, &attributes, buffer.baseAddress, buffer.count, options)
            if count < 0 { return errno }
            if count == 0 { return 0 }
            parse(buffer: UnsafeRawPointer(buffer.baseAddress!), bufferSize: buffer.count, count: Int(count), entries: &entries, names: &names)
            if !heartbeat() { return 0 }
        }
    }

    /// Parses `count` packed entries. Every read is checked against the entry's length and the
    /// buffer end; malformed entries are skipped.
    private func parse(buffer: UnsafeRawPointer, bufferSize: Int, count: Int, entries: inout [ListedEntry], names: inout [UInt8]) {
        let bufferEnd = buffer + bufferSize
        var entryStart = buffer
        for _ in 0..<count {
            guard entryStart + 4 <= bufferEnd else { return }
            let length = Int(entryStart.loadUnaligned(as: UInt32.self))
            guard length >= 4, entryStart + length <= bufferEnd else { return }
            defer { entryStart += length }
            let entryEnd = entryStart + length
            var cursor = entryStart + 4
            func take<T>(_ type: T.Type) -> T? {
                let width = MemoryLayout<T>.size
                guard cursor + width <= entryEnd else { return nil }
                let value = cursor.loadUnaligned(as: T.self)
                cursor += width
                return value
            }
            guard let returnedCommon = take(UInt32.self) else { continue }
            cursor += MemoryLayout<attribute_set_t>.size - 4
            guard let error = take(UInt32.self) else { continue }
            let nameRef = cursor
            guard let nameOffset = take(Int32.self), let nameLength = take(UInt32.self) else { continue }
            guard returnedCommon & Self.cmnName != 0, returnedCommon & Self.cmnObjType != 0, nameLength > 0 else { continue }
            guard let device = take(Int32.self), let type = take(UInt32.self), let fileID = take(UInt64.self) else { continue }
            var linkCount: UInt32 = 1
            var mountStatus: UInt32 = 0
            var total: Int64 = 0
            var alloc: Int64 = 0
            if type == ObjectType.directory {
                guard let links = take(UInt32.self), let status = take(UInt32.self) else { continue }
                linkCount = links
                mountStatus = status
            } else {
                guard let links = take(UInt32.self), let totalSize = take(Int64.self), let allocSize = take(Int64.self) else { continue }
                linkCount = links
                total = totalSize
                alloc = allocSize
            }
            var privateSize: Int64 = alloc
            var cloneID: UInt64 = 0
            var hasCloneInfo = false
            if wantClones, let privateValue = take(Int64.self), let cloneValue = take(UInt64.self) {
                privateSize = privateValue
                cloneID = cloneValue
                hasCloneInfo = true
            }
            // Name bytes without the trailing NUL, inside the entry.
            let namePointer = nameRef + Int(nameOffset)
            guard namePointer >= entryStart, namePointer + Int(nameLength) <= entryEnd else { continue }
            let nameBytesPointer = namePointer.assumingMemoryBound(to: UInt8.self)
            var nameBytes = Int(nameLength)
            while nameBytes > 0 && nameBytesPointer[nameBytes - 1] == 0 { nameBytes -= 1 }
            guard nameBytes > 0 else { continue }
            let nameStart = names.count
            names.append(contentsOf: UnsafeBufferPointer(start: nameBytesPointer, count: nameBytes))
            entries.append(ListedEntry(
                nameStart: nameStart,
                nameLength: nameBytes,
                objectType: type,
                device: device,
                fileID: fileID,
                linkCount: max(linkCount, 1),
                mountStatus: mountStatus,
                totalSize: UInt64(max(total, 0)),
                allocSize: UInt64(max(alloc, 0)),
                privateSize: UInt64(max(privateSize, 0)),
                cloneID: cloneID,
                hasCloneInfo: hasCloneInfo,
                error: error
            ))
        }
    }
}

/// Paths at least this long are opened piecewise. Well below `PATH_MAX` because the kernel
/// limit applies after symlinks in the prefix expand (for example `/var` to `/private/var`).
let directOpenLimit = 512

/// Opens a directory for listing. Long paths are opened piecewise with `openat`.
/// `followFinal` follows a symlink in the last component (used for the scan root only).
func openDirectory(_ path: [UInt8], followFinal: Bool) -> Int32 {
    let flags = O_RDONLY | O_DIRECTORY | O_CLOEXEC | (followFinal ? 0 : O_NOFOLLOW)
    let limit = directOpenLimit
    if path.count < limit {
        return withCString(path) { open($0, flags) }
    }
    // Split at slashes into pieces shorter than PATH_MAX and walk them with openat.
    var pieces: [[UInt8]] = []
    var current: [UInt8] = []
    for component in path.split(separator: 0x2F, omittingEmptySubsequences: true) {
        if !current.isEmpty && current.count + component.count + 1 >= limit {
            pieces.append(current)
            current = []
        }
        if !current.isEmpty || pieces.isEmpty && path.first == 0x2F {
            current.append(0x2F)
        }
        current.append(contentsOf: component)
    }
    if !current.isEmpty { pieces.append(current) }
    var fd: Int32 = AT_FDCWD
    for (index, piece) in pieces.enumerated() {
        let isLast = index == pieces.count - 1
        let pieceFlags = isLast ? flags : (O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        let next = withCString(piece) { openat(fd, $0, pieceFlags) }
        let saved = errno
        if fd != AT_FDCWD { close(fd) }
        guard next >= 0 else {
            errno = saved
            return -1
        }
        fd = next
    }
    return fd
}

@inline(__always)
func withCString<T>(_ bytes: [UInt8], _ body: (UnsafePointer<CChar>) -> T) -> T {
    var terminated = bytes
    terminated.append(0)
    return terminated.withUnsafeBufferPointer { buffer in
        buffer.baseAddress!.withMemoryRebound(to: CChar.self, capacity: buffer.count) { body($0) }
    }
}

/// `lstat` for a byte path (falls back to the parent directory for paths beyond `PATH_MAX`).
func lstatBytes(_ path: [UInt8], _ result: inout stat) -> Int32 {
    if path.count < directOpenLimit {
        return withCString(path) { lstat($0, &result) }
    }
    guard let slash = path.lastIndex(of: 0x2F) else { return -1 }
    let parent = Array(path[..<slash])
    let name = Array(path[(slash + 1)...])
    let fd = openDirectory(parent, followFinal: false)
    guard fd >= 0 else { return -1 }
    defer { close(fd) }
    return withCString(name) { fstatat(fd, $0, &result, AT_SYMLINK_NOFOLLOW) }
}
