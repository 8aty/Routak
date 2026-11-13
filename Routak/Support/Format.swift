import Foundation

enum Format {
    static func distanceParts(_ meters: Double, miles: Bool) -> (value: String, unit: String) {
        let value = miles ? meters / 1609.344 : meters / 1000
        let digits = value < 100 ? 1 : 0
        return (value.formatted(.number.precision(.fractionLength(digits))), miles ? "mi" : "km")
    }

    static func distance(_ meters: Double, miles: Bool) -> String {
        let parts = distanceParts(meters, miles: miles)
        return "\(parts.value) \(parts.unit)"
    }

    static func speedParts(_ metersPerSecond: Double, miles: Bool) -> (value: String, unit: String) {
        let value = max(0, metersPerSecond) * (miles ? 2.236936 : 3.6)
        return ("\(Int(value.rounded()))", miles ? "mph" : "km/h")
    }

    static func speed(_ metersPerSecond: Double, miles: Bool) -> String {
        let parts = speedParts(metersPerSecond, miles: miles)
        return "\(parts.value) \(parts.unit)"
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return String(localized: "\(h)h \(m)m", comment: "Duration: hours and minutes") }
        if m > 0 { return "\(m) min" }
        return "\(s) s"
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    static func timeRange(_ start: Date, _ end: Date) -> String {
        "\(start.formatted(date: .omitted, time: .shortened)) – \(end.formatted(date: .omitted, time: .shortened))"
    }

    static func dayTitle(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return String(localized: "Today") }
        if calendar.isDateInYesterday(date) { return String(localized: "Yesterday") }
        if calendar.isDate(date, equalTo: .now, toGranularity: .year) {
            return date.formatted(.dateTime.weekday(.wide).month(.wide).day()).capitalizedFirst
        }
        return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().year()).capitalizedFirst
    }
}

extension String {
    /// Uppercases only the first letter. Some languages (Czech, for one) write weekday
    /// and month names in lowercase, which looks wrong at the start of a title.
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
