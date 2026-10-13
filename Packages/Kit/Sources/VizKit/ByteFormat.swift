import Foundation

/// The one byte formatter of the app (map labels, lists, totals): decimal units like the Finder
/// (1 KB = 1000 bytes) with exactly three significant digits, for example "693 GB", "19.5 GB",
/// "4.02 GB", "4.00 GB".
public enum ByteFormat {
    static let units = ["KB", "MB", "GB", "TB", "PB", "EB"]

    public static func string(_ bytes: UInt64) -> String {
        guard bytes >= 1000 else {
            return String(localized: "\(Int(bytes)) bytes", bundle: .module, comment: "Size below one kilobyte")
        }
        var value = Double(bytes) / 1000
        var unit = 0
        // Move up while the value would round to 1000 or more at three significant digits.
        while value >= 999.5, unit < units.count - 1 {
            value /= 1000
            unit += 1
        }
        let number = value.formatted(.number.precision(.significantDigits(3)))
        return String(localized: "byteFormat.size", defaultValue: "\(number) \(units[unit])", bundle: .module, comment: "Size: a number with three significant digits, then a unit such as GB")
    }
}
