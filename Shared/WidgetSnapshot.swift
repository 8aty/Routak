import Foundation

/// A small summary of recent driving that the app writes for the widgets to show.
struct WidgetSnapshot: Codable {
    struct Day: Codable {
        var date: Date
        var distance: Double
        var duration: Double
        var trips: Int
    }

    struct LastTrip: Codable {
        var title: String
        var distance: Double
        var duration: Double
        var endDate: Date
    }

    /// Days with trips in the last five weeks, oldest first.
    var days: [Day] = []
    var lastTrip: LastTrip?
    var useMiles = false
    var isRecording = false
    var updated = Date()

    private static let key = "widgetSnapshot"

    static func load() -> WidgetSnapshot? {
        guard let data = AppGroup.defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        AppGroup.defaults.set(data, forKey: Self.key)
    }

    /// Totals for the week containing `date`, worked out when the widget draws,
    /// so a new week starts at zero even if the app hasn't run since.
    func week(of date: Date) -> (distance: Double, duration: Double, trips: Int) {
        guard let interval = Calendar.current.dateInterval(of: .weekOfYear, for: date) else { return (0, 0, 0) }
        return days
            .filter { interval.contains($0.date) }
            .reduce((0, 0, 0)) { ($0.0 + $1.distance, $0.1 + $1.duration, $0.2 + $1.trips) }
    }

    /// Distance for each day of the week containing `date`, first day of the week first.
    func dailyDistances(weekOf date: Date) -> [Double] {
        let calendar = Calendar.current
        guard let start = calendar.dateInterval(of: .weekOfYear, for: date)?.start else { return Array(repeating: 0, count: 7) }
        return (0..<7).map { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: start) else { return 0 }
            return days.filter { calendar.isDate($0.date, inSameDayAs: day) }.reduce(0) { $0 + $1.distance }
        }
    }

    /// Sample data for widget previews and the gallery.
    static var preview: WidgetSnapshot {
        let calendar = Calendar.current
        let start = calendar.dateInterval(of: .weekOfYear, for: .now)?.start ?? .now
        let km: [Double] = [18.4, 22.1, 0, 31.6, 12.0, 0, 0]
        var snapshot = WidgetSnapshot()
        for (i, value) in km.enumerated() where value > 0 {
            let date = calendar.date(byAdding: .day, value: i, to: start) ?? start
            if date > .now { break }
            snapshot.days.append(Day(date: date, distance: value * 1_000, duration: value * 95, trips: 2))
        }
        snapshot.lastTrip = LastTrip(title: "Home → Work", distance: 12_000, duration: 1_260, endDate: .now.addingTimeInterval(-5_400))
        return snapshot
    }
}
