import Foundation

// Mutations (PLAN 2.4): removeSubtree, replaceChildren, markMissing, and the shallow refresh
// used by `TreeRefresher`. All run under the write lock, keep ancestor sizes exact, re-apply
// hard-link and clone dedupe for the groups they touch, and bump `generation`.

extension ScanTree {
    /// Removes `id` and its descendants, updating ancestor sizes. Bumps `generation`.
    /// A removed hard-link primary (or clone primary) hands its bytes to a remaining member.
    /// The root cannot be removed.
    public func removeSubtree(_ id: NodeID) {
        lock.write {
            guard id != 0, isValid(id), !isRemoved(id) else { return }
            let old = node(id)
            let parentID = old.parent
            var parentNode = node(parentID)
            let first = Int(parentNode.firstChild)
            let count = Int(parentNode.childCount)
            var found = false
            for offset in 0..<count {
                if found {
                    arena.childIndex[first + offset - 1] = arena.childIndex[first + offset]
                } else if arena.childIndex[first + offset] == id {
                    found = true
                }
            }
            if found {
                parentNode.childCount -= 1
                arena.nodes[Int(parentID)] = parentNode
            }
            var hardLinkKeys = Set<FileIdentity>()
            var cloneKeys = Set<FamilyID>()
            markRemovedSubtree(id, hardLinkKeys: &hardLinkKeys, cloneKeys: &cloneKeys)
            var dirty = Set<NodeID>()
            propagate(from: parentID, size: -Int64(bitPattern: old.size), descendants: -(Int64(old.descendants) + 1), dirty: &dirty)
            reconcile(hardLinks: hardLinkKeys, clones: cloneKeys, dirty: &dirty)
            resort(dirty)
            bumpGeneration()
        }
    }

    /// Flags `id` as missing (vanished from disk): its size (and its descendants' sizes) go to 0,
    /// ancestors are updated, shared storage is handed to remaining members. Bumps `generation`.
    public func markMissing(_ id: NodeID) {
        lock.write {
            guard isValid(id), !isRemoved(id) else { return }
            let old = node(id)
            var hardLinkKeys = Set<FileIdentity>()
            var cloneKeys = Set<FamilyID>()
            var stack = [id]
            while let next = stack.popLast() {
                var current = node(next)
                if current.flags & NodeFlags.directory.rawValue != 0 {
                    stack.append(contentsOf: childIDs(next))
                } else if current.flags & (NodeFlags.hardLink.rawValue | NodeFlags.cloned.rawValue) != 0 {
                    unregisterShared(next, hardLinkKeys: &hardLinkKeys, cloneKeys: &cloneKeys)
                    current = node(next)
                }
                current.size = 0
                arena.nodes[Int(next)] = current
            }
            arena.nodes[Int(id)].flags |= NodeFlags.missing.rawValue
            var dirty = Set<NodeID>()
            if id != 0 {
                dirty.insert(old.parent)
                propagate(from: old.parent, size: -Int64(bitPattern: old.size), descendants: 0, dirty: &dirty)
            }
            reconcile(hardLinks: hardLinkKeys, clones: cloneKeys, dirty: &dirty)
            resort(dirty)
            bumpGeneration()
        }
    }

    /// Flags folder `id` as not responding (its listing did not return in time). Bumps
    /// `generation`. The next successful refresh of the folder clears it.
    func markNotResponding(_ id: NodeID) {
        lock.write {
            guard isValid(id), !isRemoved(id) else { return }
            if arena.nodes[Int(id)].flags & NodeFlags.notResponding.rawValue == 0 {
                arena.nodes[Int(id)].flags |= NodeFlags.notResponding.rawValue
            }
            if !unresponsiveNodes.contains(id) { unresponsiveNodes.append(id) }
            bumpGeneration()
        }
    }

    /// Replaces the children of `id` with the children of the root of `subtree` (a fresh scan of
    /// the same directory). Bumps `generation`.
    public func replaceChildren(of id: NodeID, with subtree: ScanTree) {
        guard subtree !== self else { return }
        let sourceChildren = subtree.lock.read { subtree.childIDs(0) }
        let sourceRootFlags = subtree.lock.read { subtree.node(0).flags }
        lock.write {
            guard isValid(id), !isRemoved(id), node(id).flags & NodeFlags.directory.rawValue != 0 else { return }
            let old = node(id)
            var hardLinkKeys = Set<FileIdentity>()
            var cloneKeys = Set<FamilyID>()
            for child in childIDs(id) {
                markRemovedSubtree(child, hardLinkKeys: &hardLinkKeys, cloneKeys: &cloneKeys)
            }
            let grafted = sourceChildren.map {
                graft(from: subtree, node: $0, under: id, hardLinkKeys: &hardLinkKeys, cloneKeys: &cloneKeys)
            }
            installChildren(grafted, of: id)
            let restrictedBit = NodeFlags.restricted.rawValue
            if sourceRootFlags & restrictedBit != 0 {
                arena.nodes[Int(id)].flags |= restrictedBit
            } else {
                arena.nodes[Int(id)].flags &= ~restrictedBit
            }
            arena.nodes[Int(id)].flags &= ~(NodeFlags.missing.rawValue | NodeFlags.notResponding.rawValue)
            finishDirectoryChange(id, old: old, hardLinkKeys: hardLinkKeys, cloneKeys: cloneKeys)
        }
    }

    // MARK: Shallow refresh (TreeRefresher)

    /// Entry indexes of `listing` that are directories without a match among the current
    /// children of `id` (by name and file id, or by file id alone for renames). These need a
    /// full scan before `applyShallowRefresh`.
    func unmatchedDirectories(of id: NodeID, listing: [ListedEntry], names: [UInt8]) -> [Int] {
        lock.read {
            guard isValid(id), !isRemoved(id) else { return [] }
            var byName: [[UInt8]: NodeID] = [:]
            var byFileID: [UInt64: NodeID] = [:]
            for child in childIDs(id) {
                byName[Array(nameBytes(child))] = child
                if node(child).flags & NodeFlags.directory.rawValue != 0 { byFileID[inodeOf(child)] = child }
            }
            var result: [Int] = []
            for (index, entry) in listing.enumerated() where entry.isDirectory && !entry.isMountBoundary {
                let name = Array(names[entry.nameStart..<(entry.nameStart + entry.nameLength)])
                if let match = byName[name], inodeOf(match) == entry.fileID,
                   node(match).flags & NodeFlags.directory.rawValue != 0 { continue }
                if byFileID[entry.fileID] != nil { continue }
                result.append(index)
            }
            return result
        }
    }

    /// Applies a fresh one-level listing of directory `id`: unchanged children keep their ids and
    /// subtrees, changed files get new sizes, new directories are grafted from `subtrees`
    /// (keyed by listing index), vanished children are removed. Bumps `generation`.
    func applyShallowRefresh(
        of id: NodeID,
        listing: [ListedEntry],
        names: [UInt8],
        subtrees: [Int: ScanTree],
        restricted: Bool,
        inDataVolume: Bool
    ) {
        lock.write {
            guard isValid(id), !isRemoved(id), node(id).flags & NodeFlags.directory.rawValue != 0 else { return }
            let old = node(id)
            let oldChildren = childIDs(id)
            var byName: [[UInt8]: NodeID] = [:]
            var byFileID: [UInt64: NodeID] = [:]
            for child in oldChildren {
                byName[Array(nameBytes(child))] = child
                if node(child).flags & NodeFlags.directory.rawValue != 0 { byFileID[inodeOf(child)] = child }
            }
            if subtrees.isEmpty, listing.count == oldChildren.count,
               (old.flags & NodeFlags.restricted.rawValue != 0) == restricted,
               old.flags & (NodeFlags.missing.rawValue | NodeFlags.notResponding.rawValue) == 0,
               listingMatchesChildren(listing, names: names, byName: byName) {
                return // Nothing changed: keep the generation (and paging cursors) valid.
            }
            var hardLinkKeys = Set<FileIdentity>()
            var cloneKeys = Set<FamilyID>()
            var used = Set<NodeID>()
            var newChildren: [NodeID] = []
            newChildren.reserveCapacity(listing.count)
            for (index, entry) in listing.enumerated() {
                let name = Array(names[entry.nameStart..<(entry.nameStart + entry.nameLength)])
                if let match = byName[name], !used.contains(match), inodeOf(match) == entry.fileID,
                   (node(match).flags & NodeFlags.directory.rawValue != 0) == entry.isDirectory {
                    used.insert(match)
                    if !entry.isDirectory {
                        updateFile(match, from: entry, hardLinkKeys: &hardLinkKeys, cloneKeys: &cloneKeys)
                    }
                    newChildren.append(match)
                    continue
                }
                if entry.isDirectory, !entry.isMountBoundary, subtrees[index] == nil,
                   let renamed = byFileID[entry.fileID], !used.contains(renamed) {
                    used.insert(renamed)
                    rename(renamed, to: name)
                    newChildren.append(renamed)
                    continue
                }
                if let subtree = subtrees[index] {
                    let grafted = graft(from: subtree, node: 0, under: id, hardLinkKeys: &hardLinkKeys, cloneKeys: &cloneKeys)
                    rename(grafted, to: name)
                    newChildren.append(grafted)
                } else {
                    newChildren.append(makeLeaf(entry, name: name, parent: id, inDataVolume: inDataVolume, hardLinkKeys: &hardLinkKeys, cloneKeys: &cloneKeys))
                }
            }
            for child in oldChildren where !used.contains(child) {
                markRemovedSubtree(child, hardLinkKeys: &hardLinkKeys, cloneKeys: &cloneKeys)
            }
            installChildren(newChildren, of: id)
            let restrictedBit = NodeFlags.restricted.rawValue
            if restricted {
                arena.nodes[Int(id)].flags |= restrictedBit
            } else {
                arena.nodes[Int(id)].flags &= ~restrictedBit
            }
            arena.nodes[Int(id)].flags &= ~(NodeFlags.missing.rawValue | NodeFlags.notResponding.rawValue)
            finishDirectoryChange(id, old: old, hardLinkKeys: hardLinkKeys, cloneKeys: cloneKeys)
        }
    }

    // MARK: Helpers (caller holds the write lock)

    /// True when every listed entry matches an existing child with the same file id, kind,
    /// full size and sharing facts.
    private func listingMatchesChildren(_ listing: [ListedEntry], names: [UInt8], byName: [[UInt8]: NodeID]) -> Bool {
        for entry in listing {
            let name = Array(names[entry.nameStart..<(entry.nameStart + entry.nameLength)])
            guard let match = byName[name], inodeOf(match) == entry.fileID else { return false }
            let flags = node(match).flags
            guard (flags & NodeFlags.directory.rawValue != 0) == entry.isDirectory else { return false }
            if entry.isDirectory {
                guard (flags & NodeFlags.mountPoint.rawValue != 0) == entry.isMountBoundary else { return false }
                continue
            }
            let fileBits = NodeFlags.symlink.rawValue | NodeFlags.hardLink.rawValue | NodeFlags.cloned.rawValue
            guard flags & fileBits == fileFlags(entry), fullSizeUnlocked(match) == entry.size(sizeMode) else { return false }
            if let (_, member) = cloneMember(match), member.privateBytes != min(entry.privateSize, entry.allocSize) { return false }
        }
        return true
    }

    /// Size of a file before dedupe.
    func fullSizeUnlocked(_ id: NodeID) -> UInt64 {
        let current = node(id)
        if current.flags & NodeFlags.hardLink.rawValue != 0, let group = hardLinks[identityUnlocked(id)] { return group.alloc }
        if let (_, member) = cloneMember(id) { return member.alloc }
        return current.size
    }

    /// Writes a new child block for `id`.
    private func installChildren(_ children: [NodeID], of id: NodeID) {
        var current = node(id)
        if children.isEmpty {
            current.firstChild = 0
            current.childCount = 0
        } else {
            let start = arena.childIndex.reserve(children.count)
            for (offset, child) in children.enumerated() { arena.childIndex[start + offset] = child }
            current.firstChild = UInt32(start)
            current.childCount = UInt32(children.count)
        }
        arena.nodes[Int(id)] = current
    }

    /// Recomputes `id` from its children, pushes the difference to its ancestors, re-applies
    /// dedupe for touched groups, re-sorts and bumps the generation.
    private func finishDirectoryChange(_ id: NodeID, old: Node, hardLinkKeys: Set<FileIdentity>, cloneKeys: Set<FamilyID>) {
        arena.finalizeDirectory(id, scratch: &sortScratch)
        let updated = node(id)
        var dirty = Set<NodeID>()
        if id != 0 {
            dirty.insert(old.parent)
            propagate(
                from: old.parent,
                size: Int64(bitPattern: updated.size &- old.size),
                descendants: Int64(updated.descendants) - Int64(old.descendants),
                dirty: &dirty
            )
        }
        reconcile(hardLinks: hardLinkKeys, clones: cloneKeys, dirty: &dirty)
        resort(dirty)
        bumpGeneration()
    }

    /// Flags every node of the subtree as removed and drops shared members from the side tables.
    func markRemovedSubtree(_ id: NodeID, hardLinkKeys: inout Set<FileIdentity>, cloneKeys: inout Set<FamilyID>) {
        var stack = [id]
        let sharedBits = NodeFlags.hardLink.rawValue | NodeFlags.cloned.rawValue
        while let next = stack.popLast() {
            let current = node(next)
            if current.flags & NodeFlags.directory.rawValue != 0 {
                stack.append(contentsOf: childIDs(next))
            } else if current.flags & sharedBits != 0 || cloneOf[next] != nil {
                unregisterShared(next, hardLinkKeys: &hardLinkKeys, cloneKeys: &cloneKeys)
            }
            arena.nodes[Int(next)].flags |= NodeBits.removed
        }
    }

    private func rename(_ id: NodeID, to name: [UInt8]) {
        let same = name.withUnsafeBufferPointer { bytesEqual(nameBytes(id), $0) }
        guard !same else { return }
        let ref = nameWriter.write(name, into: arena.names)
        arena.nodes[Int(id)].nameRef = ref
        arena.nodes[Int(id)].nameLength = UInt16(min(name.count, Int(UInt16.max)))
    }

    /// Updates a kept file from a fresh listing entry (size, symlink, link count, clone facts).
    private func updateFile(_ id: NodeID, from entry: ListedEntry, hardLinkKeys: inout Set<FileIdentity>, cloneKeys: inout Set<FamilyID>) {
        unregisterShared(id, hardLinkKeys: &hardLinkKeys, cloneKeys: &cloneKeys)
        var current = node(id)
        let clearBits = NodeFlags.hardLink.rawValue | NodeFlags.hardLinkSecondary.rawValue | NodeFlags.cloned.rawValue
            | NodeFlags.symlink.rawValue | NodeFlags.missing.rawValue
        current.flags &= ~clearBits
        current.flags |= fileFlags(entry)
        current.size = entry.size(sizeMode)
        arena.nodes[Int(id)] = current
        registerEntry(id, entry, hardLinkKeys: &hardLinkKeys, cloneKeys: &cloneKeys)
    }

    private func fileFlags(_ entry: ListedEntry) -> UInt16 {
        var flags: UInt16 = 0
        if entry.isSymlink { flags |= NodeFlags.symlink.rawValue }
        if entry.linkCount > 1 { flags |= NodeFlags.hardLink.rawValue }
        if entry.sharedBytes > 0 { flags |= NodeFlags.cloned.rawValue }
        return flags
    }

    private func registerEntry(_ id: NodeID, _ entry: ListedEntry, hardLinkKeys: inout Set<FileIdentity>, cloneKeys: inout Set<FamilyID>) {
        guard !entry.isDirectory else { return }
        let identity = FileIdentity(device: entry.device, inode: entry.fileID)
        let clone: (key: CloneKey, privateBytes: UInt64)? = entry.sharedBytes > 0
            ? (CloneKey(device: entry.device, cloneID: entry.cloneID), entry.privateSize) : nil
        registerShared(id, identity: identity, linkCount: entry.linkCount, alloc: entry.size(sizeMode), clone: clone,
                       hardLinkKeys: &hardLinkKeys, cloneKeys: &cloneKeys)
    }

    /// Creates a childless node for a listing entry.
    private func makeLeaf(
        _ entry: ListedEntry, name: [UInt8], parent: NodeID, inDataVolume: Bool,
        hardLinkKeys: inout Set<FileIdentity>, cloneKeys: inout Set<FamilyID>
    ) -> NodeID {
        let id = NodeID(arena.reserveNodes(1))
        var flags: UInt16 = 0
        if entry.error != 0 {
            flags |= NodeFlags.restricted.rawValue
            if entry.isDirectory { flags |= NodeFlags.directory.rawValue }
        } else if entry.isDirectory {
            flags |= NodeFlags.directory.rawValue
            if isPackageName(name[...]) { flags |= NodeFlags.package.rawValue }
            if entry.isMountBoundary {
                flags |= NodeFlags.mountPoint.rawValue
            } else if inDataVolume && firmlinkSkip.contains(FileIdentity(device: entry.device, inode: entry.fileID)) {
                flags |= NodeFlags.firmlinkSkipped.rawValue
            }
        } else {
            flags |= fileFlags(entry)
        }
        let ref = nameWriter.write(name, into: arena.names)
        flags |= arena.storeInode(id, entry.fileID)
        arena.nodes[Int(id)] = Node(
            size: entry.error != 0 ? 0 : entry.size(sizeMode), parent: parent, firstChild: 0, childCount: 0, nameRef: ref,
            descendants: 0, nameLength: UInt16(min(name.count, Int(UInt16.max))), flags: flags
        )
        if entry.error == 0 {
            if entry.device != deviceOf(parent) { deviceExceptions[id] = entry.device }
            registerEntry(id, entry, hardLinkKeys: &hardLinkKeys, cloneKeys: &cloneKeys)
        }
        return id
    }

    /// Copies the subtree at `sourceID` of `source` under `parent`. Shared files are re-registered
    /// at their full size; the caller reconciles the returned keys.
    func graft(
        from source: ScanTree, node sourceID: NodeID, under parent: NodeID,
        hardLinkKeys: inout Set<FileIdentity>, cloneKeys: inout Set<FamilyID>
    ) -> NodeID {
        source.lock.read {
            let rootCopy = NodeID(arena.reserveNodes(1))
            copyNode(from: source, sourceID, to: rootCopy, parent: parent, hardLinkKeys: &hardLinkKeys, cloneKeys: &cloneKeys)
            var queue: [(NodeID, NodeID)] = [(sourceID, rootCopy)]
            var directories: [NodeID] = []
            while let (sourceDir, targetDir) = queue.popLast() {
                let sourceNode = source.node(sourceDir)
                guard sourceNode.flags & NodeFlags.directory.rawValue != 0 else { continue }
                directories.append(targetDir)
                let count = Int(sourceNode.childCount)
                guard count > 0 else { continue }
                let base = arena.reserveNodes(count)
                let indexBase = arena.childIndex.reserve(count)
                for offset in 0..<count {
                    let sourceChild = source.arena.childIndex[Int(sourceNode.firstChild) + offset]
                    let target = NodeID(base + offset)
                    copyNode(from: source, sourceChild, to: target, parent: targetDir, hardLinkKeys: &hardLinkKeys, cloneKeys: &cloneKeys)
                    arena.childIndex[indexBase + offset] = target
                    queue.append((sourceChild, target))
                }
                arena.nodes[Int(targetDir)].firstChild = UInt32(indexBase)
                arena.nodes[Int(targetDir)].childCount = UInt32(count)
            }
            for directory in directories.reversed() {
                arena.finalizeDirectory(directory, scratch: &sortScratch)
            }
            return rootCopy
        }
    }

    private func copyNode(
        from source: ScanTree, _ sourceID: NodeID, to target: NodeID, parent: NodeID,
        hardLinkKeys: inout Set<FileIdentity>, cloneKeys: inout Set<FamilyID>
    ) {
        var copy = source.node(sourceID)
        let ref = nameWriter.write(UnsafeRawBufferPointer(source.nameBytes(sourceID)), into: arena.names)
        copy.nameRef = ref
        copy.parent = parent
        copy.firstChild = 0
        copy.childCount = 0
        copy.flags &= ~(NodeBits.removed | NodeBits.inodeHigh | NodeFlags.hardLinkSecondary.rawValue)
        let identity = source.identityUnlocked(sourceID)
        copy.flags |= arena.storeInode(target, identity.inode)
        // Folders that stalled in the subscan stay listed as not responding.
        if copy.flags & NodeFlags.notResponding.rawValue != 0 { unresponsiveNodes.append(target) }
        if identity.device != deviceOf(parent) { deviceExceptions[target] = identity.device }
        if copy.flags & NodeFlags.directory.rawValue == 0 {
            var linkCount: UInt32 = 1
            var alloc = copy.size
            if copy.flags & NodeFlags.hardLink.rawValue != 0, let group = source.hardLinks[identity] {
                linkCount = group.linkCount
                alloc = group.alloc
            }
            var clone: (key: CloneKey, privateBytes: UInt64)?
            if let (family, member) = source.cloneMember(sourceID) {
                clone = (source.cloneFamilies[Int(family)].key, member.privateBytes)
                alloc = member.alloc
            }
            copy.size = alloc
            if linkCount > 1 || clone != nil {
                arena.nodes[Int(target)] = copy
                registerShared(target, identity: identity, linkCount: linkCount, alloc: alloc, clone: clone,
                               hardLinkKeys: &hardLinkKeys, cloneKeys: &cloneKeys)
                return
            }
        }
        arena.nodes[Int(target)] = copy
    }
}
