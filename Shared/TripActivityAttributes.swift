import ActivityKit
import Foundation

/// The Live Activity shown on the Lock Screen and in the Dynamic Island while a trip records.
struct TripActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// Meters.
        var distance: Double
        /// Stopped in traffic or at a light, still recording.
        var isStopped = false
        /// The trip has ended; the activity stays up briefly to show the result.
        var endDate: Date?
    }

    var startDate: Date
    var useMiles: Bool
}
