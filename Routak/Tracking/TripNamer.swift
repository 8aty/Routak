import SwiftData

/// Names a trip's start and end: a saved place if one matches, otherwise a street address.
@MainActor
enum TripNamer {
    static func name(for point: TrackPoint, places: [SavedPlace]) async -> String? {
        if let place = PlaceBook.place(at: point.coordinate, in: places) { return place.name }
        return await PlaceNamer.name(for: point.location)
    }

    /// Looks up names for the trip's current endpoints and saves.
    static func nameEndpoints(of trip: Trip, start: Bool = true, end: Bool = true, context: ModelContext) async {
        let points = trip.points
        guard let first = points.first, let last = points.last else { return }
        let places = PlaceBook.all(in: context)
        if start { trip.startName = await name(for: first, places: places) }
        if end { trip.endName = await name(for: last, places: places) }
        guard !trip.isDeleted else { return }
        try? context.save()
    }
}
