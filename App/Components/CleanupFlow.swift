import AppCore
import CleanupKit
import Foundation
import Observation
import RulesKit

/// UI state around a cleanup: the session window's notice and the "queue changed during the
/// countdown" check. What may be removed, the acknowledgement, the countdown and the run all live
/// in AppCore's `CleanupModel`; this type only forwards to it.
@Observable
@MainActor
final class CleanupFlow {
    static let countdownSeconds = CleanupModel.countdownSeconds

    let cleanup: CleanupModel
    /// A one-line message for the session window (for example why a countdown stopped).
    var notice: String?

    @ObservationIgnored private var queueAtConfirm: [QueueItem] = []

    init(cleanup: CleanupModel) {
        self.cleanup = cleanup
    }

    var isCountingDown: Bool { cleanup.countdownRemaining != nil }
    var countdownRemaining: Int? { cleanup.countdownRemaining }
    var acknowledged: Set<UUID> { cleanup.acknowledged }

    // MARK: What may be removed

    /// Whether `item` may be ticked at all (by the risk recorded on the item).
    func mayRemove(_ item: QueueItem) -> Bool {
        cleanup.mayRemove(item)
    }

    /// The single "will be removed" set.
    func removalSet(_ cleanup: CleanupModel) -> [QueueItem] {
        cleanup.removalSet
    }

    /// Stops a pending countdown when the queue changes under it.
    func reconcile(_ cleanup: CleanupModel) {
        if isCountingDown, cleanup.queue != queueAtConfirm {
            cancelCountdown(notice: String(localized: "Permanent deletion stopped because the cleanup queue changed. Nothing was deleted.", table: "UI"))
        }
    }

    /// Records (or withdraws) the user's acknowledgement for one dangerous item. Withdrawing also
    /// unticks it; acknowledging an assistant suggestion makes it the user's own item in place.
    func setAcknowledged(_ item: QueueItem, _ value: Bool, cleanup: CleanupModel) {
        cleanup.acknowledge(item.id, value)
    }

    // MARK: Runs

    func moveToTrash(_ items: [QueueItem], cleanup: CleanupModel) {
        cleanup.requestRun(mode: .trash, ids: Set(items.map(\.id)))
    }

    /// Starts the store's countdown for exactly the confirmed items. When it ends, only those run.
    func startPermanentDeletion(_ items: [QueueItem], cleanup: CleanupModel) {
        notice = nil
        cleanup.requestRun(mode: .permanent, ids: Set(items.map(\.id)))
        if cleanup.countdownRemaining != nil { queueAtConfirm = cleanup.queue }
    }

    /// Stops a pending permanent deletion and says so.
    func cancelCountdown(notice: String) {
        guard isCountingDown else { return }
        cleanup.stopCountdown()
        queueAtConfirm = []
        self.notice = notice
    }
}
