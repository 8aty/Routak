import Foundation
import SwiftData

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

    init(startDate: Date, isManual: Bool) {
        self.id = UUID()
        self.startDate = startDate
        self.endDate = startDate
        self.isManual = isManual
        self.isActive = true
    }

    var duration: TimeInterval { max(0, endDate.timeIntervalSince(startDate)) }

    var averageSpeed: Double { duration > 0 ? distance / duration : 0 }

    var points: [TrackPoint] { TrackPoint.decode(pointsData) }

    var title: String {
        switch (startName, endName) {
        case let (start?, end?) where start == end: return start
        case let (start?, end?): return "\(start) → \(end)"
        case let (start?, nil): return "From \(start)"
        case let (nil, end?): return "To \(end)"
        default: return isManual ? "Manual trip" : "Drive"
        }
    }

    /// Unique per saved version of the route, used for snapshot caching.
    var snapshotKey: String {
        "\(id.uuidString)-\(Int(endDate.timeIntervalSinceReferenceDate))-\(pointsData.count)"
    }

    func apply(points: [TrackPoint]) {
        let stats = RouteStats(points)
        pointsData = TrackPoint.encode(points)
        distance = stats.distance
        maxSpeed = stats.maxSpeed
        if let first = points.first { startDate = first.timestamp }
        if let last = points.last { endDate = last.timestamp }
    }
}

enum Persistence {
    @MainActor static let container: ModelContainer = {
        do {
            return try ModelContainer(for: Trip.self)
        } catch {
            fatalError("Could not open trip database: \(error)")
        }
    }()
}
