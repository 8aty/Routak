import Foundation
import SwiftData
import UIKit

/// Background housekeeping for saved trips: filling in fields added by app updates,
/// and matching finished routes to roads.
@MainActor
enum TripMaintenance {
    private static var snapping: Set<UUID> = []
    private static var queueTask: Task<Void, Never>?

    /// Called when the app comes to the foreground.
    static func run(context: ModelContext) {
        backfill(context: context)
        snapPending(context: context)
    }

    /// Trips saved before endpoints were stored have 0,0 there. Cheap to check on every launch.
    private static func backfill(context: ModelContext) {
        let descriptor = FetchDescriptor<Trip>(predicate: #Predicate {
            $0.isActive == false && $0.startLatitude == 0 && $0.startLongitude == 0
        })
        guard let trips = try? context.fetch(descriptor), !trips.isEmpty else { return }
        for trip in trips { trip.backfillIfNeeded() }
        try? context.save()
    }

    /// Snaps trips that haven't been matched yet, newest first. Stops if MapKit throttles us.
    static func snapPending(context: ModelContext) {
        guard Prefs.snapToRoads, queueTask == nil else { return }
        let pending = RoadSnapper.State.pending.rawValue
        var descriptor = FetchDescriptor<Trip>(
            predicate: #Predicate { $0.isActive == false && $0.snapStateRaw == pending },
            sortBy: [SortDescriptor(\.startDate, order: .reverse)]
        )
        descriptor.fetchLimit = 20
        guard let trips = try? context.fetch(descriptor), !trips.isEmpty else { return }
        let ids = trips.map(\.persistentModelID)

        queueTask = Task {
            defer { queueTask = nil }
            for id in ids {
                guard let trip = context.model(for: id) as? Trip, !trip.isDeleted else { continue }
                if await !snap(trip, context: context) { break }
            }
        }
    }

    /// Matches one trip to roads. Returns false if MapKit throttled the request (try later).
    @discardableResult
    static func snap(_ trip: Trip, context: ModelContext) async -> Bool {
        guard Prefs.snapToRoads, !trip.isActive, !snapping.contains(trip.id) else { return true }
        snapping.insert(trip.id)
        defer { snapping.remove(trip.id) }

        let background = UIApplication.shared.beginBackgroundTask(withName: "SnapTrip")
        defer { UIApplication.shared.endBackgroundTask(background) }

        let key = trip.snapshotKey
        do {
            let matched = try await RoadSnapper.snap(trip.points)
            // The trip may have been edited, merged or deleted while we were waiting on the network.
            guard !trip.isDeleted, trip.snapshotKey == key else { return true }
            if let matched {
                trip.snappedData = TrackPoint.encode(matched)
                trip.snapStateRaw = RoadSnapper.State.matched.rawValue
            } else {
                trip.snapStateRaw = RoadSnapper.State.unavailable.rawValue
            }
            try? context.save()
            return true
        } catch {
            return false
        }
    }
}
