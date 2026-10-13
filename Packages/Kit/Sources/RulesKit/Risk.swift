import Foundation

/// How risky it is to remove an item. Ordered: safe < review < dangerous < never.
public enum Risk: String, Codable, Comparable, Sendable, CaseIterable {
    case safe
    case review
    case dangerous
    case never

    private var rank: Int {
        switch self {
        case .safe: 0
        case .review: 1
        case .dangerous: 2
        case .never: 3
        }
    }

    public static func < (lhs: Risk, rhs: Risk) -> Bool { lhs.rank < rhs.rank }
}

/// Why an item cannot be queued or deleted.
public enum BlockReason: String, Codable, Sendable, CaseIterable {
    case systemPath
    case protectedRoot
    case userData
    case cloudSynced
    case backup
    case readOnlyVolume
    case notInScan
    case changedSinceScan
    case specialItem
    case scanRoot

    /// Short user-facing explanation (RulesKit string catalog).
    public var message: String {
        switch self {
        case .systemPath:
            String(localized: "This belongs to macOS or to an installed app, so it is never removed.", bundle: .module)
        case .protectedRoot:
            String(localized: "This folder holds other important folders, so it stays.", bundle: .module)
        case .userData:
            String(localized: "This holds personal data such as passwords or messages.", bundle: .module)
        case .cloudSynced:
            String(localized: "This is synced with the cloud. Removing it here removes it everywhere.", bundle: .module)
        case .backup:
            String(localized: "This is a backup. Manage it in the app that made it.", bundle: .module)
        case .readOnlyVolume:
            String(localized: "This disk is read only.", bundle: .module)
        case .notInScan:
            String(localized: "This item is not part of the current scan.", bundle: .module)
        case .changedSinceScan:
            String(localized: "This item changed after the scan. Rescan to continue.", bundle: .module)
        case .specialItem:
            String(localized: "This is a summary row, not a real item.", bundle: .module)
        case .scanRoot:
            String(localized: "This is the folder being scanned.", bundle: .module)
        }
    }
}

/// Result of classifying a path. Frozen contract (PLAN 4.3).
public struct Classification: Sendable, Hashable {
    public var ruleID: String?
    public var risk: Risk
    public var categoryID: String?
    public var explanation: String?
    public var block: BlockReason?

    public init(ruleID: String? = nil, risk: Risk, categoryID: String? = nil, explanation: String? = nil, block: BlockReason? = nil) {
        self.ruleID = ruleID
        self.risk = risk
        self.categoryID = categoryID
        self.explanation = explanation
        self.block = block
    }

    /// No rule matched and nothing blocks the item.
    public static let unclassified = Classification(risk: .review)
}
