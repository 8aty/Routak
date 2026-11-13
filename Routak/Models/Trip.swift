import CoreLocation
import Foundation
import SwiftData

/// What a trip was for. Stored as a raw string so new kinds can be added later.
enum TripCategory: String, CaseIterable, Identifiable, Codable {
    case commute, work, personal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .commute: String(localized: "category.commute", defaultValue: "Commute", comment: "Trip label: driving between home and work")
        case .work: String(localized: "category.work", defaultValue: "Work", comment: "Trip label: a business trip")
        case .personal: String(localized: "category.personal", defaultValue: "Personal", comment: "Trip label: a private trip")
        }
    }

    var systemImage: String {
        switch self {
        case .commute: "arrow.triangle.swap"
        case .work: "briefcase.fill"
        case .personal: "person.fill"
        }
    }
}

// Every stored property has a default value so the store can later sync with CloudKit.
@Model
final class Trip {
    var id: UUID = UUID()
    var startDate: Date = Date()
    var endDate: Date = Date()
    /// Meters.
    var distance: Double = 0
    /// Meters per second.
    var maxSpeed: Double = 0
    /// True while the trip is still being recorded.
    var isActive: Bool = true
    var isManual: Bool = false
    var startName: String?
    var endName: String?
    @Attribute(.externalStorage) var pointsData: Data = Data()

    // Added in 1.1
    /// Endpoints, stored so lists, search and places don't have to decode the whole route.
    var startLatitude: Double = 0
    var startLongitude: Double = 0
    var endLatitude: Double = 0
    var endLongitude: Double = 0
    /// `TripCategory` raw value, empty when not labeled.
    var categoryRaw: String = ""
    var notes: String = ""
    /// The route lined up with roads (same packing as `pointsData`), nil if not matched.
    /// Optional because adding a non-optional external-storage attribute breaks in-place migration.
    @Attribute(.externalStorage) var snappedData: Data?
    /// See `RoadSnapper.State`.
    var snapStateRaw: Int = 0

    // Added in 1.2
    /// Which device recorded the trip (see `Prefs.deviceID`). With iCloud sync, a trip still being
    /// recorded on one device shows up on the others, and only its own device may resume or finish it.
    var deviceID: String = ""

    init(startDate: Date, isManual: Bool) {
        self.id = UUID()
        self.deviceID = Prefs.deviceID
        self.startDate = startDate
        self.endDate = startDate
        self.isManual = isManual
        self.isActive = true
    }

    var duration: TimeInterval { max(0, endDate.timeIntervalSince(startDate)) }

    var averageSpeed: Double { duration > 0 ? distance / duration : 0 }

    var points: [TrackPoint] { TrackPoint.decode(pointsData) }

    var snappedPoints: [TrackPoint] { snappedData.map(TrackPoint.decode) ?? [] }

    /// The route to draw: matched to roads when available, otherwise the raw GPS track.
    var displayPoints: [TrackPoint] {
        guard Prefs.snapToRoads else { return points }
        let snapped = snappedPoints
        return snapped.count >= 2 ? snapped : points
    }

    var category: TripCategory? {
        get { TripCategory(rawValue: categoryRaw) }
        set { categoryRaw = newValue?.rawValue ?? "" }
    }

    var hasEndpoints: Bool { startLatitude != 0 || startLongitude != 0 }

    var startCoordinate: CLLocationCoordinate2D? {
        hasEndpoints ? CLLocationCoordinate2D(latitude: startLatitude, longitude: startLongitude) : nil
    }

    var endCoordinate: CLLocationCoordinate2D? {
        hasEndpoints ? CLLocationCoordinate2D(latitude: endLatitude, longitude: endLongitude) : nil
    }

    var title: String {
        switch (startName, endName) {
        case let (start?, end?) where start == end: return start
        case let (start?, end?): return "\(start) → \(end)"
        case let (start?, nil): return String(localized: "From \(start)", comment: "Trip title when only the start place is known")
        case let (nil, end?): return String(localized: "To \(end)", comment: "Trip title when only the end place is known")
        default: return isManual ? String(localized: "Manual trip") : String(localized: "Drive", comment: "Title of a trip with no known places")
        }
    }

    /// Unique per saved version of the route, used for snapshot caching.
    var snapshotKey: String {
        "\(id.uuidString)-\(Int(endDate.timeIntervalSinceReferenceDate))-\(pointsData.count)-\(Prefs.snapToRoads ? (snappedData?.count ?? 0) : 0)"
    }

    /// Replaces the route and recomputes everything derived from it.
    func apply(points: [TrackPoint]) {
        let stats = RouteStats(points)
        pointsData = TrackPoint.encode(points)
        distance = stats.distance
        maxSpeed = stats.maxSpeed
        if let first = points.first {
            startDate = first.timestamp
            startLatitude = first.latitude
            startLongitude = first.longitude
        }
        if let last = points.last {
            endDate = last.timestamp
            endLatitude = last.latitude
            endLongitude = last.longitude
        }
        // The road-matched copy no longer fits the new route.
        snappedData = nil
        snapStateRaw = 0
    }

    /// Fills in fields added after the first release, for trips saved by older versions.
    func backfillIfNeeded() {
        guard !hasEndpoints, !isActive else { return }
        let points = self.points
        guard let first = points.first, let last = points.last else { return }
        startLatitude = first.latitude
        startLongitude = first.longitude
        endLatitude = last.latitude
        endLongitude = last.longitude
    }
}

enum Persistence {
    static let cloudContainerID = "iCloud.cc.tomy.Routak"

    /// True when this launch opened the store with iCloud sync.
    @MainActor private(set) static var isSyncing = false
    /// The sync setting when the store was opened (changing it applies on the next launch).
    @MainActor private(set) static var syncSettingAtLaunch = false

    /// Builds for sideloading (AltStore) are signed with a personal Apple ID, which can't use iCloud.
    #if SIDELOAD
    static let supportsSync = false
    #else
    static let supportsSync = true
    #endif

    @MainActor static let container: ModelContainer = {
        let schema = Schema([Trip.self, SavedPlace.self])
        // Read directly: this can run before `Prefs.register()`.
        let wantsSync = supportsSync && (UserDefaults.standard.object(forKey: Prefs.iCloudSyncKey) as? Bool ?? true)
        syncSettingAtLaunch = wantsSync
        // `groupContainer: .none` keeps the store in the app's own folder, where it has always been.
        // Otherwise SwiftData would move it into the App Group the widgets use (they don't need it).
        if wantsSync {
            // Same store file as without sync, so turning sync on uploads the trips already saved.
            let configuration = ModelConfiguration(schema: schema, groupContainer: .none, cloudKitDatabase: .private(cloudContainerID))
            if let container = try? ModelContainer(for: schema, configurations: configuration) {
                isSyncing = true
                return container
            }
            // No iCloud entitlement or the container can't be set up: keep working locally.
        }
        do {
            let configuration = ModelConfiguration(schema: schema, groupContainer: .none, cloudKitDatabase: .none)
            return try ModelContainer(for: schema, configurations: configuration)
        } catch {
            fatalError("Could not open trip database: \(error)")
        }
    }()
}
