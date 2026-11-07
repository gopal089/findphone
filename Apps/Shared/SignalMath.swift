import Foundation

/// Signal-strength rules shared by the findphone Mac and iPhone apps.
/// They are the same rules the findphone command-line tool uses.
enum SignalMath {

    /// Readings outside this range are errors or "no value" markers (127, 0).
    static let validRSSI = -126 ... -1

    /// The displayed value is the median of this many newest readings.
    static let windowSize = 7

    /// With no valid reading for this long, the signal counts as "gone":
    /// the big number shows "--" and the clicks stop.
    static let silenceAfter: TimeInterval = 10

    /// Median of the values (average of the two middle ones for an even count).
    static func median(of values: [Int]) -> Int? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count % 2 == 1 {
            return sorted[middle]
        }
        return Int((Double(sorted[middle - 1] + sorted[middle]) / 2).rounded())
    }

    // MARK: Click speed

    static let weakRSSI = -95.0
    static let strongRSSI = -50.0
    static let slowestClick: TimeInterval = 1.0    // at -95 dBm and weaker
    static let fastestClick: TimeInterval = 0.07   // at -50 dBm and stronger

    /// Seconds between clicks, on a straight line from 1 s at -95 dBm to
    /// 0.07 s at -50 dBm, clamped at both ends.
    static func clickInterval(for rssi: Int) -> TimeInterval {
        let clamped = min(max(Double(rssi), weakRSSI), strongRSSI)
        let fraction = (clamped - weakRSSI) / (strongRSSI - weakRSSI)
        return slowestClick + (fastestClick - slowestClick) * fraction
    }

    /// 0.0 (about -100 dBm, far) to 1.0 (about -30 dBm, very close),
    /// for a "closeness" bar.
    static func closeness(_ rssi: Int) -> Double {
        min(max((Double(rssi) + 100) / 70, 0), 1)
    }

    // MARK: Text

    /// True when two device names are identical apart from upper/lower case.
    /// "Gopal’s iPhone" (curly apostrophe) does NOT match "Gopal's iPhone".
    static func namesMatch(_ a: String, _ b: String) -> Bool {
        a.trimmingCharacters(in: .whitespaces)
            .caseInsensitiveCompare(b.trimmingCharacters(in: .whitespaces)) == .orderedSame
    }

    /// Formats seconds as mm:ss.
    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
