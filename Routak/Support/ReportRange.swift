import Foundation

/// A date range picked for exports and the mileage log.
enum ReportRange: String, CaseIterable, Identifiable {
    case thisMonth, lastMonth, thisYear, lastYear, all, custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .thisMonth: "This month"
        case .lastMonth: "Last month"
        case .thisYear: "This year"
        case .lastYear: "Last year"
        case .all: "All trips"
        case .custom: "Custom"
        }
    }

    /// nil means no limit.
    func interval(customStart: Date, customEnd: Date, now: Date = .now) -> DateInterval? {
        let calendar = Calendar.current
        switch self {
        case .thisMonth:
            return calendar.dateInterval(of: .month, for: now)
        case .lastMonth:
            guard let previous = calendar.date(byAdding: .month, value: -1, to: now) else { return nil }
            return calendar.dateInterval(of: .month, for: previous)
        case .thisYear:
            return calendar.dateInterval(of: .year, for: now)
        case .lastYear:
            guard let previous = calendar.date(byAdding: .year, value: -1, to: now) else { return nil }
            return calendar.dateInterval(of: .year, for: previous)
        case .all:
            return nil
        case .custom:
            let start = calendar.startOfDay(for: min(customStart, customEnd))
            let endDay = calendar.startOfDay(for: max(customStart, customEnd))
            let end = calendar.date(byAdding: .day, value: 1, to: endDay) ?? endDay
            return DateInterval(start: start, end: end)
        }
    }

    /// Short text for file names and report headers, e.g. "March 2026".
    func label(customStart: Date, customEnd: Date) -> String {
        guard let interval = interval(customStart: customStart, customEnd: customEnd) else { return "All trips" }
        switch self {
        case .thisMonth, .lastMonth:
            return interval.start.formatted(.dateTime.month(.wide).year())
        case .thisYear, .lastYear:
            return interval.start.formatted(.dateTime.year())
        default:
            let end = interval.end.addingTimeInterval(-1)
            return "\(interval.start.formatted(date: .abbreviated, time: .omitted)) – \(end.formatted(date: .abbreviated, time: .omitted))"
        }
    }
}
