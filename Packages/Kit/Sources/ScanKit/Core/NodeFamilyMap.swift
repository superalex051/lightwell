/// Node to clone family map. After a scan it is a sorted array of packed `(node, family)` pairs
/// (8 bytes each, about half of a dictionary); later additions go to a small dictionary and
/// removals leave tombstones.
struct NodeFamilyMap {
    private static let tombstone = FamilyID.max
    /// `node << 32 | family`, sorted by node.
    private var sorted: [UInt64] = []
    private var overflow: [NodeID: FamilyID] = [:]
    private(set) var count = 0

    /// Replaces the contents with `pairs` (`node << 32 | family`, one per node).
    mutating func build(from pairs: inout [UInt64]) {
        pairs.sort()
        sorted = pairs
        pairs = []
        overflow = [:]
        count = sorted.count
    }

    private func index(of node: NodeID) -> Int? {
        var low = 0
        var high = sorted.count
        let key = UInt64(node)
        while low < high {
            let middle = (low + high) / 2
            let value = sorted[middle] >> 32
            if value == key { return middle }
            if value < key { low = middle + 1 } else { high = middle }
        }
        return nil
    }

    subscript(node: NodeID) -> FamilyID? {
        get {
            if !overflow.isEmpty, let family = overflow[node] { return family }
            guard let index = index(of: node) else { return nil }
            let family = FamilyID(truncatingIfNeeded: sorted[index])
            return family == Self.tombstone ? nil : family
        }
        set {
            if let newValue {
                if let index = index(of: node) {
                    if FamilyID(truncatingIfNeeded: sorted[index]) == Self.tombstone { count += 1 }
                    sorted[index] = UInt64(node) << 32 | UInt64(newValue)
                } else {
                    if overflow.updateValue(newValue, forKey: node) == nil { count += 1 }
                }
            } else {
                removeValue(forKey: node)
            }
        }
    }

    @discardableResult
    mutating func removeValue(forKey node: NodeID) -> FamilyID? {
        if let family = overflow.removeValue(forKey: node) {
            count -= 1
            return family
        }
        guard let index = index(of: node) else { return nil }
        let family = FamilyID(truncatingIfNeeded: sorted[index])
        guard family != Self.tombstone else { return nil }
        sorted[index] = UInt64(node) << 32 | UInt64(Self.tombstone)
        count -= 1
        return family
    }

    /// Every node with a family.
    var keys: [NodeID] {
        var result: [NodeID] = []
        result.reserveCapacity(count)
        for value in sorted where FamilyID(truncatingIfNeeded: value) != Self.tombstone { result.append(NodeID(value >> 32)) }
        result.append(contentsOf: overflow.keys)
        return result
    }

    var storageBytes: Int { sorted.capacity * 8 + overflow.capacity * 9 }
}
