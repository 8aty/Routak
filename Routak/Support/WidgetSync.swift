import Foundation
import SwiftData
import WidgetKit

/// Writes the summary the widgets show, and asks WidgetKit to redraw them.
@MainActor
enum WidgetSync {
    private static var pending: Task<Void, Never>?

    /// Coalesces bursts of changes (a trip being saved, named and snapped) into one update.
    static func schedule() {
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            update()
        }
    }

    static func update() {
        let context = Persistence.container.mainContext
        let calendar = Calendar.current
        let since = calendar.date(byAdding: .day, value: -35, to: calendar.startOfDay(for: .now)) ?? .distantPast
        let recent = (try? context.fetch(FetchDescriptor<Trip>(
            predicate: #Predicate { $0.isActive == false && $0.startDate >= since },
            sortBy: [SortDescriptor(\.startDate)]
        ))) ?? []

        var snapshot = WidgetSnapshot()
        var byDay: [Date: WidgetSnapshot.Day] = [:]
        for trip in recent {
            let day = calendar.startOfDay(for: trip.startDate)
            var entry = byDay[day] ?? WidgetSnapshot.Day(date: day, distance: 0, duration: 0, trips: 0)
            entry.distance += trip.distance
            entry.duration += trip.duration
            entry.trips += 1
            byDay[day] = entry
        }
        snapshot.days = byDay.values.sorted { $0.date < $1.date }

        var lastDescriptor = FetchDescriptor<Trip>(
            predicate: #Predicate { $0.isActive == false },
            sortBy: [SortDescriptor(\.endDate, order: .reverse)]
        )
        lastDescriptor.fetchLimit = 1
        if let last = try? context.fetch(lastDescriptor).first {
            snapshot.lastTrip = .init(title: last.title, distance: last.distance, duration: last.duration, endDate: last.endDate)
        }
        snapshot.useMiles = Prefs.useMiles
        snapshot.isRecording = TripTracker.shared.mode == .recording
        snapshot.updated = .now
        snapshot.save()
        WidgetCenter.shared.reloadAllTimelines()
    }
}
