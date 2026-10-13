import CleanupKit
import Foundation

extension AddResult {
    /// One-line feedback for the person who pressed Add to Cleanup.
    var message: String {
        switch self {
        case .added: String(localized: "Added to the cleanup queue.", table: "UI")
        case .alreadyQueued: String(localized: "Already in the cleanup queue.", table: "UI")
        case .coveredByParent(let parent):
            String(localized: "Already covered by \((parent as NSString).lastPathComponent) in the queue.", table: "UI")
        case .blocked(let reason): reason.message
        case .needsUserChoice: String(localized: "This one needs your own decision, so it was not queued for you.", table: "UI")
        case .containsUserItems: String(localized: "Not queued, because it holds items you chose yourself.", table: "UI")
        }
    }

    /// Like `message`, except that a refusal the store marks as retryable (the item changed while
    /// it was being checked, in a live session) asks to try again instead of to rescan.
    func message(retryable: Bool) -> String {
        if retryable, case .blocked(.changedSinceScan) = self {
            return String(localized: "This item changed while it was being checked. Try again.", table: "UI")
        }
        return message
    }

    var isSuccess: Bool {
        if case .added = self { return true }
        return false
    }
}
