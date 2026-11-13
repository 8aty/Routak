import CoreLocation
import Foundation

/// Drives between Home and Work, and when it's quickest to leave.
@MainActor
struct CommuteAnalysis {
    enum Direction: String, CaseIterable, Identifiable {
        case toWork, toHome
        var id: String { rawValue }
        var title: String { self == .toWork ? String(localized: "To Work") : String(localized: "To Home") }
        var systemImage: String { self == .toWork ? "briefcase.fill" : "house.fill" }
    }

    /// A 15-minute window of departure times.
    struct Slot: Identifiable {
        /// Minutes after midnight when the window starts.
        let minute: Int
        let count: Int
        let averageDuration: TimeInterval
        var id: Int { minute }

        var title: String { CommuteAnalysis.clockText(minute) }
    }

    let direction: Direction
    /// Newest first.
    let trips: [Trip]

    /// Extra room around Home/Work: drives are often detected a little after pulling away.
    static let slack: CLLocationDistance = 250
    static let slotMinutes = 15

    init(direction: Direction, trips: [Trip], home: SavedPlace, work: SavedPlace) {
        self.direction = direction
        let (from, to) = direction == .toWork ? (home, work) : (work, home)
        self.trips = trips
            .filter { trip in
                guard let start = trip.startCoordinate, let end = trip.endCoordinate else { return false }
                return Self.isNear(start, from) && Self.isNear(end, to)
            }
            .sorted { $0.startDate > $1.startDate }
    }

    static func isNear(_ coordinate: CLLocationCoordinate2D, _ place: SavedPlace) -> Bool {
        place.location.distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
            <= place.radius + slack
    }

    var isEmpty: Bool { trips.isEmpty }
    var durations: [TimeInterval] { trips.map(\.duration) }

    var average: TimeInterval {
        trips.isEmpty ? 0 : durations.reduce(0, +) / Double(trips.count)
    }

    var median: TimeInterval {
        let sorted = durations.sorted()
        guard !sorted.isEmpty else { return 0 }
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    var fastest: Trip? { trips.min { $0.duration < $1.duration } }
    var slowest: Trip? { trips.max { $0.duration < $1.duration } }

    var averageDistance: Double {
        trips.isEmpty ? 0 : trips.reduce(0) { $0 + $1.distance } / Double(trips.count)
    }

    /// Departure windows with at least two drives, in time order.
    var slots: [Slot] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: trips) { trip -> Int in
            let parts = calendar.dateComponents([.hour, .minute], from: trip.startDate)
            let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            return minute / Self.slotMinutes * Self.slotMinutes
        }
        return grouped
            .filter { $0.value.count >= 2 }
            .map { Slot(minute: $0.key, count: $0.value.count, averageDuration: $0.value.reduce(0) { $0 + $1.duration } / Double($0.value.count)) }
            .sorted { $0.minute < $1.minute }
    }

    var bestSlot: Slot? { slots.min { $0.averageDuration < $1.averageDuration } }
    var worstSlot: Slot? { slots.max { $0.averageDuration < $1.averageDuration } }

    /// Average duration per weekday (1 = Sunday … 7 = Saturday), only days with drives.
    var byWeekday: [(weekday: Int, average: TimeInterval, count: Int)] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: trips) { calendar.component(.weekday, from: $0.startDate) }
        return grouped.keys.sorted { Self.weekdayOrder($0) < Self.weekdayOrder($1) }.map { day in
            let list = grouped[day] ?? []
            return (day, list.reduce(0) { $0 + $1.duration } / Double(list.count), list.count)
        }
    }

    /// Position of a weekday in the user's week (Monday first in most of the world).
    nonisolated static func weekdayOrder(_ weekday: Int) -> Int {
        (weekday - Calendar.current.firstWeekday + 7) % 7
    }

    nonisolated static func clockText(_ minute: Int) -> String {
        let date = Calendar.current.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: .now) ?? .now
        return date.formatted(date: .omitted, time: .shortened)
    }

    /// Today's date with the trip's departure time, so departures can share one time-of-day axis.
    nonisolated static func timeOfDay(_ date: Date) -> Date {
        let calendar = Calendar.current
        let parts = calendar.dateComponents([.hour, .minute, .second], from: date)
        return calendar.date(bySettingHour: parts.hour ?? 0, minute: parts.minute ?? 0, second: parts.second ?? 0,
                             of: calendar.startOfDay(for: .now)) ?? date
    }
}
