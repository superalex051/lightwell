import os

/// Signpost intervals around main-actor work (visible in Instruments): scan finish, map colours,
/// tree updates after deletions, applying a deletion report. The 16 ms main-thread budget
/// (PLAN WS9) is checked by `MainThreadBudgetTests`.
enum Signposts {
    static let signposter = OSSignposter(subsystem: "com.alexluncan.lightwell", category: "MainActor")

    static func begin(_ name: StaticString) -> OSSignpostIntervalState {
        signposter.beginInterval(name, id: signposter.makeSignpostID())
    }

    static func end(_ name: StaticString, _ state: OSSignpostIntervalState) {
        signposter.endInterval(name, state)
    }
}
