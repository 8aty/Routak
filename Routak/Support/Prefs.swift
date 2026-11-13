import Foundation

/// User settings, shared between SwiftUI (@AppStorage) and the background tracker.
enum Prefs {
    static let autoDetectKey = "autoDetect"
    static let minTripDistanceKey = "minTripDistance"
    static let stopTimeoutKey = "stopTimeout"
    static let useMilesKey = "useMiles"
    static let askedAlwaysKey = "askedAlwaysPermission"
    static let snapToRoadsKey = "snapToRoads"
    static let lowBatteryStopKey = "lowBatteryStop"
    static let mergeTripsKey = "mergeTrips"
    static let hasOnboardedKey = "hasOnboarded"
    /// Stored in metric; the UI converts to mpg, per gallon and per mile when miles are on.
    static let fuelEconomyKey = "fuelLitersPer100km"
    static let fuelPriceKey = "fuelPricePerLiter"
    static let mileageRateKey = "mileageRatePerKm"

    static let defaultMinTripDistance: Double = 2_000   // meters
    static let defaultStopTimeout: Double = 240         // seconds parked before a trip ends

    /// Trips this close in time (seconds) and space (meters) are joined into one.
    static let mergeGap: TimeInterval = 300
    static let mergeRadius: Double = 400
    /// While the motion sensor says we're still in a car, a stop can last this long before the trip ends.
    static let maxTrafficHold: TimeInterval = 20 * 60
    /// GPS turns off below this battery level (unless charging), and back on above `batteryResumeLevel`.
    static let batteryStopLevel: Float = 0.10
    static let batteryResumeLevel: Float = 0.15

    static func register() {
        UserDefaults.standard.register(defaults: [
            autoDetectKey: true,
            minTripDistanceKey: defaultMinTripDistance,
            stopTimeoutKey: defaultStopTimeout,
            useMilesKey: Locale.current.measurementSystem == .us,
            snapToRoadsKey: true,
            lowBatteryStopKey: true,
            mergeTripsKey: true,
            fuelEconomyKey: 8.0,
            fuelPriceKey: 0.0,
            // US standard business rate (70¢ per mile); elsewhere the user sets their own.
            mileageRateKey: Locale.current.region == .unitedStates ? 0.70 / 1.609344 : 0.0,
        ])
    }

    static var autoDetect: Bool { UserDefaults.standard.bool(forKey: autoDetectKey) }
    static var minTripDistance: Double { UserDefaults.standard.double(forKey: minTripDistanceKey) }
    static var stopTimeout: Double { UserDefaults.standard.double(forKey: stopTimeoutKey) }
    static var useMiles: Bool { UserDefaults.standard.bool(forKey: useMilesKey) }
    static var snapToRoads: Bool { UserDefaults.standard.bool(forKey: snapToRoadsKey) }
    static var lowBatteryStop: Bool { UserDefaults.standard.bool(forKey: lowBatteryStopKey) }
    static var mergeTrips: Bool { UserDefaults.standard.bool(forKey: mergeTripsKey) }
    static var fuelEconomy: Double { UserDefaults.standard.double(forKey: fuelEconomyKey) }
    static var fuelPrice: Double { UserDefaults.standard.double(forKey: fuelPriceKey) }
    static var mileageRate: Double { UserDefaults.standard.double(forKey: mileageRateKey) }
}
