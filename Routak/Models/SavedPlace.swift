import CoreLocation
import Foundation
import SwiftData

/// A place the user named once, like Home or Work. Trips starting or ending inside
/// its radius are titled with its name instead of a street address.
@Model
final class SavedPlace {
    enum Kind: String, CaseIterable, Identifiable {
        case home, work, other
        var id: String { rawValue }

        var title: String {
            switch self {
            case .home: String(localized: "place.home", defaultValue: "Home", comment: "Saved place kind; also the default name for the user's home")
            case .work: String(localized: "place.work", defaultValue: "Work", comment: "Saved place kind; also the default name for the user's workplace")
            case .other: String(localized: "place.other", defaultValue: "Place", comment: "Saved place kind for any other place")
            }
        }

        var systemImage: String {
            switch self {
            case .home: "house.fill"
            case .work: "briefcase.fill"
            case .other: "mappin"
            }
        }
    }

    var id: UUID = UUID()
    var name: String = ""
    var kindRaw: String = Kind.other.rawValue
    var latitude: Double = 0
    var longitude: Double = 0
    /// Meters.
    var radius: Double = 150
    var createdAt: Date = Date()

    init(name: String, kind: Kind, coordinate: CLLocationCoordinate2D, radius: Double = 150) {
        self.id = UUID()
        self.name = name
        self.kindRaw = kind.rawValue
        self.latitude = coordinate.latitude
        self.longitude = coordinate.longitude
        self.radius = radius
        self.createdAt = Date()
    }

    var kind: Kind {
        get { Kind(rawValue: kindRaw) ?? .other }
        set { kindRaw = newValue.rawValue }
    }

    var coordinate: CLLocationCoordinate2D {
        get { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
        set {
            latitude = newValue.latitude
            longitude = newValue.longitude
        }
    }

    var location: CLLocation { CLLocation(latitude: latitude, longitude: longitude) }

    func contains(_ coordinate: CLLocationCoordinate2D) -> Bool {
        location.distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)) <= radius
    }
}

/// Lookups and bulk renames for saved places.
@MainActor
enum PlaceBook {
    static func all(in context: ModelContext) -> [SavedPlace] {
        (try? context.fetch(FetchDescriptor<SavedPlace>())) ?? []
    }

    /// The closest saved place containing `coordinate`, if any.
    static func place(at coordinate: CLLocationCoordinate2D, in places: [SavedPlace]) -> SavedPlace? {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return places
            .filter { $0.contains(coordinate) }
            .min { $0.location.distance(from: location) < $1.location.distance(from: location) }
    }

    /// Renames the start/end of every saved trip that begins or ends at `place`.
    /// Returns how many trips changed.
    @discardableResult
    static func apply(_ place: SavedPlace, in context: ModelContext) -> Int {
        let descriptor = FetchDescriptor<Trip>(predicate: #Predicate { $0.isActive == false })
        guard let trips = try? context.fetch(descriptor) else { return 0 }
        var changed = 0
        for trip in trips {
            var didChange = false
            if let start = trip.startCoordinate, place.contains(start), trip.startName != place.name {
                trip.startName = place.name
                didChange = true
            }
            if let end = trip.endCoordinate, place.contains(end), trip.endName != place.name {
                trip.endName = place.name
                didChange = true
            }
            if didChange { changed += 1 }
        }
        try? context.save()
        return changed
    }

    /// How many saved trips start or end at `coordinate` within `radius`.
    static func tripCount(near coordinate: CLLocationCoordinate2D, radius: Double, in context: ModelContext) -> Int {
        let probe = SavedPlace(name: "", kind: .other, coordinate: coordinate, radius: radius)
        let descriptor = FetchDescriptor<Trip>(predicate: #Predicate { $0.isActive == false })
        let trips = (try? context.fetch(descriptor)) ?? []
        return trips.filter { trip in
            (trip.startCoordinate.map(probe.contains) ?? false) || (trip.endCoordinate.map(probe.contains) ?? false)
        }.count
    }
}
