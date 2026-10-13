import Foundation

// Hard links and clones (PLAN 2.4 accounting rules).
//
// While scanning, every file contributes its full size. `installSharing` then builds the side
// tables and `reconcile` moves each shared file to its deduped contribution:
// - hard links: the link with the smallest path (UTF-8 byte order) carries the inode's bytes,
//   the others contribute 0 and carry `hardLinkSecondary`;
// - clones (when `countClonesOnce`): every member contributes its private bytes and the primary
//   (smallest path) also carries the family's shared bytes once.
// Deltas are applied to the member and all of its ancestors; touched directories are re-sorted.

extension Arena {
    /// Sorts the child block of `id` by size (largest first), ties by name bytes.
    func sortChildren(of id: NodeID, scratch: inout [UInt32]) {
        let parent = nodes[Int(id)]
        let count = Int(parent.childCount)
        guard count > 1 else { return }
        let first = Int(parent.firstChild)
        scratch.removeAll(keepingCapacity: true)
        for offset in 0..<count { scratch.append(childIndex[first + offset]) }
        scratch.sort { a, b in
            let left = nodes[Int(a)], right = nodes[Int(b)]
            if left.size != right.size { return left.size > right.size }
            return bytesPrecede(nameBytes(left), nameBytes(right))
        }
        for offset in 0..<count { childIndex[first + offset] = scratch[offset] }
    }

    /// Recomputes size and descendant count of directory `id` from its children, then sorts them.
    func finalizeDirectory(_ id: NodeID, scratch: inout [UInt32]) {
        var parent = nodes[Int(id)]
        let first = Int(parent.firstChild)
        var total: UInt64 = 0
        var descendants: UInt32 = 0
        for offset in 0..<Int(parent.childCount) {
            let child = nodes[Int(childIndex[first + offset])]
            total &+= child.size
            descendants &+= child.descendants &+ 1
        }
        parent.size = total
        parent.descendants = descendants
        nodes[Int(id)] = parent
        sortChildren(of: id, scratch: &scratch)
    }
}

extension ScanTree {
    // MARK: Delta propagation (caller holds the write lock)

    /// Adds the deltas to `start` and every ancestor. Each touched node's parent is recorded in
    /// `dirty` because its child block may need re-sorting.
    func propagate(from start: NodeID, size: Int64, descendants: Int64, dirty: inout Set<NodeID>) {
        guard size != 0 || descendants != 0 else { return }
        var cursor = start
        while cursor != noNode {
            var current = arena.nodes[Int(cursor)]
            current.size = UInt64(bitPattern: Int64(bitPattern: current.size) &+ size)
            current.descendants = UInt32(truncatingIfNeeded: Int64(current.descendants) &+ descendants)
            arena.nodes[Int(cursor)] = current
            if cursor == 0 { break }
            dirty.insert(current.parent)
            cursor = current.parent
        }
    }

    /// Changes the contribution of file `id` to `newSize`, updating its ancestors.
    func setContribution(_ id: NodeID, _ newSize: UInt64, dirty: inout Set<NodeID>) {
        let current = arena.nodes[Int(id)]
        guard current.size != newSize else { return }
        let delta = Int64(bitPattern: newSize &- current.size)
        propagate(from: id, size: delta, descendants: 0, dirty: &dirty)
    }

    func resort(_ dirty: Set<NodeID>) {
        for id in dirty where id != noNode && isValid(id) && !isRemoved(id) {
            arena.sortChildren(of: id, scratch: &sortScratch)
        }
    }

    // MARK: Side tables

    /// Builds the side tables from scan records and applies dedupe. Called once after a scan or
    /// a synthetic build, before the tree is published. Clone records live in a lazily mapped
    /// buffer that the caller drops afterwards; the tables are sized exactly (two passes).
    ///
    /// Clone families with a single member in the tree are kept too: their shared bytes are held
    /// by a clone outside the tree, so removing that member frees only its private bytes.
    func installSharing(
        hardLinkRecords: [HardLinkRecord],
        cloneRecords: ChunkedBuffer<CloneRecord>,
        deviceExceptions exceptions: [(NodeID, Int32)]
    ) {
        lock.write {
            for (id, device) in exceptions { deviceExceptions[id] = device }
            var groups = Set<FileIdentity>()
            for record in hardLinkRecords {
                hardLinks[record.identity, default: HardLinkGroup(linkCount: record.linkCount, alloc: record.alloc, members: [])]
                    .members.append(record.node)
                if hardLinks[record.identity]!.members.count > 1 { groups.insert(record.identity) }
            }

            // Pass 1: members per clone key.
            let count = cloneRecords.count
            func member(_ record: CloneRecord) -> CloneMember? {
                CloneMember(node: record.node, alloc: arena.nodes[Int(record.node)].size, privateBytes: record.privateBytes)
            }
            var counts: [CloneKey: Int] = [:]
            for index in 0..<count {
                let record = cloneRecords[index]
                if member(record) != nil { counts[record.key, default: 0] += 1 }
            }
            var familyCount = 0
            var memberCount = 0
            for (_, members) in counts {
                familyCount += 1
                memberCount += members
            }
            cloneFamilies.reserveCapacity(familyCount)
            cloneFamilyIndex.reserveCapacity(familyCount)
            var pairs: [UInt64] = []
            pairs.reserveCapacity(memberCount)
            for (key, members) in counts {
                var list: [CloneMember] = []
                list.reserveCapacity(members)
                cloneFamilyIndex[key] = FamilyID(cloneFamilies.count)
                cloneFamilies.append(CloneFamily(key: key, members: list))
            }
            counts = [:]
            // Pass 2: fill the families.
            for index in 0..<count {
                let record = cloneRecords[index]
                guard let family = cloneFamilyIndex[record.key], let info = member(record) else { continue }
                cloneFamilies[Int(family)].members.append(info)
                pairs.append(UInt64(record.node) << 32 | UInt64(family))
            }
            cloneOf.build(from: &pairs)
            // Single-member hard-link groups need no change: the lone link carries its full size.
            var dirty = Set<NodeID>()
            reconcile(hardLinks: groups, clones: [], allClones: true, dirty: &dirty)
            resort(dirty)
        }
    }

    /// Registers file `id` in the side tables (graft or refresh), recording the touched groups.
    func registerShared(
        _ id: NodeID, identity: FileIdentity, linkCount: UInt32, alloc: UInt64,
        clone: (key: CloneKey, privateBytes: UInt64)?,
        hardLinkKeys: inout Set<FileIdentity>, cloneKeys: inout Set<FamilyID>
    ) {
        if linkCount > 1 {
            hardLinks[identity, default: HardLinkGroup(linkCount: linkCount, alloc: alloc, members: [])].members.append(id)
            hardLinks[identity]!.linkCount = linkCount
            hardLinks[identity]!.alloc = alloc
            hardLinkKeys.insert(identity)
        }
        if let clone, let member = CloneMember(node: id, alloc: alloc, privateBytes: clone.privateBytes) {
            let family: FamilyID
            if let existing = cloneFamilyIndex[clone.key] {
                family = existing
            } else {
                family = FamilyID(cloneFamilies.count)
                cloneFamilies.append(CloneFamily(key: clone.key, members: []))
                cloneFamilyIndex[clone.key] = family
            }
            cloneFamilies[Int(family)].members.append(member)
            cloneOf[id] = family
            cloneKeys.insert(family)
        }
    }

    /// Removes file `id` from the side tables, recording the groups that still have members.
    func unregisterShared(_ id: NodeID, hardLinkKeys: inout Set<FileIdentity>, cloneKeys: inout Set<FamilyID>) {
        let flags = arena.nodes[Int(id)].flags
        if flags & NodeFlags.hardLink.rawValue != 0 {
            let identity = identityUnlocked(id)
            if var group = hardLinks[identity] {
                group.members.removeAll { $0 == id }
                if group.members.isEmpty {
                    hardLinks[identity] = nil
                    hardLinkKeys.remove(identity)
                } else {
                    hardLinks[identity] = group
                    hardLinkKeys.insert(identity)
                }
            }
        }
        if let family = cloneOf.removeValue(forKey: id) {
            cloneFamilies[Int(family)].members.removeAll { $0.node == id }
            if cloneFamilies[Int(family)].members.isEmpty {
                cloneFamilyIndex[cloneFamilies[Int(family)].key] = nil
                cloneKeys.remove(family)
            } else {
                cloneKeys.insert(family)
            }
        }
    }

    private func smallestPath(_ ids: [NodeID]) -> NodeID {
        guard ids.count > 1 else { return ids[0] }
        var best = ids[0]
        var bestPath = pathBytesUnlocked(best)
        for id in ids.dropFirst() {
            let candidate = pathBytesUnlocked(id)
            if candidate.lexicographicallyPrecedes(bestPath) {
                best = id
                bestPath = candidate
            }
        }
        return best
    }

    /// Recomputes primaries and contributions for the given hard-link groups and clone families.
    /// `allClones` reconciles every clone family (after a scan) without building a set of them.
    func reconcile(hardLinks groupKeys: Set<FileIdentity>, clones familyKeys: Set<FamilyID>, allClones: Bool = false, dirty: inout Set<NodeID>) {
        guard !groupKeys.isEmpty || !familyKeys.isEmpty || allClones else { return }
        var groups = groupKeys
        var families = familyKeys
        if !allClones {
            for key in groupKeys {
                for member in hardLinks[key]?.members ?? [] {
                    if let family = cloneOf[member] { families.insert(family) }
                }
            }
        }
        let familyList: [FamilyID] = allClones ? (0..<cloneFamilies.count).map { FamilyID($0) } : Array(families)
        for family in familyList {
            for member in cloneFamilies[Int(family)].members where arena.nodes[Int(member.node)].flags & NodeFlags.hardLink.rawValue != 0 {
                let identity = identityUnlocked(member.node)
                if hardLinks[identity] != nil { groups.insert(identity) }
            }
        }

        // Hard links first, then clone families (their value wins for clone members).
        let secondaryBit = NodeFlags.hardLinkSecondary.rawValue
        for key in groups {
            guard let group = hardLinks[key], !group.members.isEmpty else { continue }
            let primary = smallestPath(group.members)
            for member in group.members {
                var current = arena.nodes[Int(member)]
                current.flags |= NodeFlags.hardLink.rawValue
                if member == primary {
                    current.flags &= ~secondaryBit
                } else {
                    current.flags |= secondaryBit
                }
                arena.nodes[Int(member)] = current
                setContribution(member, member == primary ? group.alloc : 0, dirty: &dirty)
            }
        }
        for family in familyList {
            let members = cloneFamilies[Int(family)].members
            let eligible = members.filter { arena.nodes[Int($0.node)].flags & secondaryBit == 0 }
            guard !eligible.isEmpty else { continue }
            if countClonesOnce {
                let shared = eligible.lazy.map(\.shared).max() ?? 0
                let primary = smallestPath(eligible.map(\.node))
                for member in eligible {
                    setContribution(member.node, member.privateBytes + (member.node == primary ? shared : 0), dirty: &dirty)
                }
            } else {
                for member in eligible { setContribution(member.node, member.alloc, dirty: &dirty) }
            }
        }
    }

    // MARK: Reclaimable estimate

    public func reclaimableBytes(_ id: NodeID, ifAlsoRemoving others: Set<NodeID>) -> UInt64 {
        lock.read { reclaimableUnlocked(id, others: others) }
    }

    func reclaimableUnlocked(_ id: NodeID, others: Set<NodeID>) -> UInt64 {
        guard isValid(id), !isRemoved(id) else { return 0 }
        let target = node(id)
        let sharedBits = NodeFlags.hardLink.rawValue | NodeFlags.cloned.rawValue
        let isDirectory = target.flags & NodeFlags.directory.rawValue != 0
        if !isDirectory && target.flags & sharedBits == 0 { return target.size }
        if hardLinks.isEmpty && cloneFamilies.isEmpty && isDirectory { return target.size }

        // Shared files inside the subtree of `id`.
        var shared: [NodeID] = []
        if !isDirectory {
            shared = [id]
        } else {
            let memberCount = cloneOf.count + hardLinks.reduce(0) { $0 + $1.value.members.count }
            if Int(target.descendants) < memberCount * 16 {
                var stack = [id]
                while let next = stack.popLast() {
                    let current = node(next)
                    if current.flags & NodeFlags.directory.rawValue != 0 {
                        for offset in 0..<Int(current.childCount) {
                            stack.append(arena.childIndex[Int(current.firstChild) + offset])
                        }
                    } else if current.flags & sharedBits != 0 {
                        shared.append(next)
                    }
                }
            } else {
                var seen = Set<NodeID>()
                for group in hardLinks.values {
                    for member in group.members where isWithin(member, id) && seen.insert(member).inserted { shared.append(member) }
                }
                for member in cloneOf.keys where isWithin(member, id) && seen.insert(member).inserted { shared.append(member) }
            }
        }
        guard !shared.isEmpty else { return target.size }

        let removal = others.filter { isValid($0) && !isRemoved($0) }
        func isRemoving(_ member: NodeID) -> Bool {
            var cursor = member
            while true {
                if cursor == id || removal.contains(cursor) { return true }
                if cursor == 0 || cursor == noNode { return false }
                cursor = node(cursor).parent
            }
        }

        var counted: UInt64 = 0
        var freed: UInt64 = 0
        var seenInodes = Set<FileIdentity>()
        var seenFamilies = Set<FamilyID>()
        for member in shared {
            let current = node(member)
            counted &+= current.size
            var hardLinkAlloc: UInt64?
            if current.flags & NodeFlags.hardLink.rawValue != 0, let group = hardLinks[identityUnlocked(member)] {
                // An inode is freed only when every one of its links goes.
                guard group.members.count >= Int(group.linkCount),
                      group.members.allSatisfy(isRemoving),
                      seenInodes.insert(identityUnlocked(member)).inserted
                else { continue }
                hardLinkAlloc = group.alloc
            }
            if let (familyID, info) = cloneMember(member) {
                let family = cloneFamilies[Int(familyID)]
                freed &+= info.privateBytes
                // Shared bytes go only when every member goes. A lone member in the tree shares
                // its extents with a clone elsewhere, so it frees its private bytes only.
                if family.members.count > 1, family.members.allSatisfy({ isRemoving($0.node) }),
                   seenFamilies.insert(familyID).inserted {
                    freed &+= family.shared
                }
            } else if current.flags & NodeFlags.cloned.rawValue != 0 {
                // Shares storage with a clone we have no details for: nothing certain is freed.
            } else {
                freed &+= hardLinkAlloc ?? current.size
            }
        }
        let result = Int64(bitPattern: target.size) - Int64(bitPattern: counted) + Int64(bitPattern: freed)
        return UInt64(max(result, 0))
    }
}
