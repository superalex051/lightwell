import Foundation
import VizKit

nonisolated enum Format {
    static func bytes(_ value: UInt64) -> String {
        ByteFormat.string(value)
    }

    static func count(_ value: some BinaryInteger) -> String {
        Int64(clamping: value).formatted(.number)
    }

    /// Money is stored in integer cents; this is the only place it becomes a decimal.
    static func dollars(cents: Int) -> String {
        (Decimal(cents) / 100).formatted(.currency(code: "USD"))
    }

    static func percent(_ fraction: Double) -> String {
        fraction.formatted(.percent.precision(.fractionLength(0)))
    }

    static func date(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    /// `/Users/<name>/x` becomes `~/x` for display.
    static func abbreviatedPath(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}
