import Foundation

/// User settings, shared between SwiftUI (@AppStorage) and the background tracker.
enum Prefs {
    static let autoDetectKey = "autoDetect"
    static let minTripDistanceKey = "minTripDistance"
    static let stopTimeoutKey = "stopTimeout"
    static let useMilesKey = "useMiles"
    static let askedAlwaysKey = "askedAlwaysPermission"

    static let defaultMinTripDistance: Double = 2_000   // meters
    static let defaultStopTimeout: Double = 240         // seconds parked before a trip ends

    static func register() {
        UserDefaults.standard.register(defaults: [
            autoDetectKey: true,
            minTripDistanceKey: defaultMinTripDistance,
            stopTimeoutKey: defaultStopTimeout,
            useMilesKey: Locale.current.measurementSystem == .us,
        ])
    }

    static var autoDetect: Bool { UserDefaults.standard.bool(forKey: autoDetectKey) }
    static var minTripDistance: Double { UserDefaults.standard.double(forKey: minTripDistanceKey) }
    static var stopTimeout: Double { UserDefaults.standard.double(forKey: stopTimeoutKey) }
}
