import Foundation

/// How a volume's capacity splits up after a scan. Frozen contract (PLAN 4.3).
public struct SpaceSummary: Sendable, Hashable, Codable {
    public var capacity: UInt64
    public var used: UInt64
    public var free: UInt64
    public var purgeable: UInt64
    /// Space used by other APFS volumes in the same container.
    public var otherVolumes: UInt64
    public var scanned: UInt64
    /// Used space the scan could not see (restricted folders, snapshots, system).
    public var hidden: UInt64

    public init(capacity: UInt64, used: UInt64, free: UInt64, purgeable: UInt64, otherVolumes: UInt64, scanned: UInt64, hidden: UInt64) {
        self.capacity = capacity
        self.used = used
        self.free = free
        self.purgeable = purgeable
        self.otherVolumes = otherVolumes
        self.scanned = scanned
        self.hidden = hidden
    }

    /// PLAN 2.4 accounting rules:
    /// free = available (clamped to capacity); used = capacity - free;
    /// purgeable = max(0, availableImportant - free) (info only, 0 when availableImportant is 0);
    /// otherVolumes = space of sibling APFS volumes (`VolumeInfo.otherVolumes`, clamped to used);
    /// hidden = max(0, used - scanned - otherVolumes).
    public static func compute(_ volume: VolumeInfo, scanned: UInt64) -> SpaceSummary {
        let capacity = volume.capacity
        let free = min(volume.available, capacity)
        let purgeable = volume.availableImportant > free ? volume.availableImportant - free : 0
        let used = capacity - free
        let otherVolumes = min(volume.otherVolumes, used)
        let (accounted, overflow) = scanned.addingReportingOverflow(otherVolumes)
        let hidden = !overflow && used > accounted ? used - accounted : 0
        return SpaceSummary(
            capacity: capacity, used: used, free: free, purgeable: purgeable,
            otherVolumes: otherVolumes, scanned: scanned, hidden: hidden
        )
    }

    /// Summary for a folder scan: only the scanned bytes (no free, hidden or other volumes rows).
    public static func folder(scanned: UInt64) -> SpaceSummary {
        SpaceSummary(capacity: 0, used: scanned, free: 0, purgeable: 0, otherVolumes: 0, scanned: scanned, hidden: 0)
    }
}
