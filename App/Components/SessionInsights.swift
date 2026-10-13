import AppCore
import Foundation
import RulesKit
import ScanKit

/// The screens' view of a scan session's lookups, mapped to the app's colour type. All lookups
/// and caches live in AppCore (`ScanSessionModel`: indexed categories, memoized families, the
/// breakdown per generation); this only translates `SpaceFamily` to `SpaceCategory`.
@MainActor
struct SessionInsights {
    let session: ScanSessionModel
    let tree: any TreeReading

    init?(session: ScanSessionModel) {
        guard let tree = session.tree else { return nil }
        self.session = session
        self.tree = tree
        Self.observeRevisions(of: session)
    }

    /// Reads the revisions, so the calling view's body redraws when the tree or the colours change.
    /// Views that get insights passed in (the list, the inspector) call it in their own body:
    /// tree lookups are not observable, and SwiftUI skips a child whose inputs look unchanged.
    static func observeRevisions(of session: ScanSessionModel) {
        _ = session.treeRevision
        _ = session.mapRevision
        _ = session.classificationRevision
    }

    /// The knowledge-base category that lists `node` or one of its ancestors.
    func category(covering node: NodeID) -> CategoryResult? {
        session.category(covering: node)
    }

    /// Whether `node` may be added to the cleanup queue (protected items and the scan root may not).
    func canQueue(_ node: NodeID) -> Bool {
        session.canQueue(node)
    }

    /// Colour family of `node`: its own category, otherwise the nearest ancestor's.
    func color(of node: NodeID) -> SpaceCategory? {
        session.family(of: node).map(SpaceCategory.init(family:))
    }

    /// Bytes per colour family under the scan root.
    var breakdown: [SpaceCategory: UInt64] {
        var totals: [SpaceCategory: UInt64] = [:]
        for (family, bytes) in session.breakdown() {
            totals[SpaceCategory(family: family), default: 0] += bytes
        }
        return totals
    }
}
