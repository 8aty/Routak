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
    static let drivingReminderKey = "drivingReminder"
    static let iCloudSyncKey = "iCloudSync"
    static let liveActivityKey = "liveActivity"
    static let mergeGapKey = "mergeGap"
    static let maxPauseKey = "maxPause"
    static let continueWindowKey = "continueWindow"
    static let continueRadiusKey = "continueRadius"
    private static let deviceIDKey = "deviceID"
    /// Stored in metric; the UI converts to mpg, per gallon and per mile when miles are on.
    static let fuelEconomyKey = "fuelLitersPer100km"
    static let fuelPriceKey = "fuelPricePerLiter"
    static let mileageRateKey = "mileageRatePerKm"
    /// The mileage log lists every trip, or only trips with the labels in `mileageLabelsKey` (comma-separated keys).
    static let mileageAllTripsKey = "mileageAllTrips"
    static let mileageLabelsKey = "mileageLabels"

    static let defaultMinTripDistance: Double = 2_000   // meters
    static let defaultStopTimeout: Double = 240         // seconds parked before a trip ends

    /// Driving again this close in time (`mergeGap`, seconds) and space (meters) to where a trip ended joins it.
    static let defaultMergeGap: TimeInterval = 600
    static let mergeRadius: Double = 400
    /// A paused trip that hasn't resumed after this long is saved.
    static let defaultMaxPause: TimeInterval = 3_600
    /// "Continue last trip" is offered this long after a trip ended, and this close to where it ended.
    static let defaultContinueWindow: TimeInterval = 1_800
    static let defaultContinueRadius: Double = 500
    /// A manual trip that has been standing still this long asks whether you're still driving.
    static let manualStopCheck: TimeInterval = 600
    /// How long that question waits for an answer before the trip ends.
    static let stopCheckGrace: TimeInterval = 60
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
            mergeGapKey: defaultMergeGap,
            maxPauseKey: defaultMaxPause,
            continueWindowKey: defaultContinueWindow,
            continueRadiusKey: defaultContinueRadius,
            drivingReminderKey: true,
            iCloudSyncKey: true,
            liveActivityKey: true,
            fuelEconomyKey: 8.0,
            fuelPriceKey: 0.0,
            // US standard business rate (70¢ per mile); elsewhere the user sets their own.
            mileageRateKey: Locale.current.region == .unitedStates ? 0.70 / 1.609344 : 0.0,
            mileageAllTripsKey: false,
            mileageLabelsKey: "work",
        ])
        // The mileage log used to offer fixed choices: carry the old one over.
        if let old = UserDefaults.standard.string(forKey: "mileageLogInclude") {
            switch old {
            case "all": UserDefaults.standard.set(true, forKey: mileageAllTripsKey)
            case "workAndCommute": UserDefaults.standard.set("work,commute", forKey: mileageLabelsKey)
            default: break
            }
            UserDefaults.standard.removeObject(forKey: "mileageLogInclude")
        }
    }

    static var autoDetect: Bool { UserDefaults.standard.bool(forKey: autoDetectKey) }
    static var minTripDistance: Double { UserDefaults.standard.double(forKey: minTripDistanceKey) }
    static var stopTimeout: Double { UserDefaults.standard.double(forKey: stopTimeoutKey) }
    static var useMiles: Bool { UserDefaults.standard.bool(forKey: useMilesKey) }
    static var snapToRoads: Bool { UserDefaults.standard.bool(forKey: snapToRoadsKey) }
    static var lowBatteryStop: Bool { UserDefaults.standard.bool(forKey: lowBatteryStopKey) }
    static var mergeTrips: Bool { UserDefaults.standard.bool(forKey: mergeTripsKey) }
    static var mergeGap: TimeInterval { UserDefaults.standard.double(forKey: mergeGapKey) }
    static var maxPause: TimeInterval { UserDefaults.standard.double(forKey: maxPauseKey) }
    static var continueWindow: TimeInterval { UserDefaults.standard.double(forKey: continueWindowKey) }
    static var continueRadius: Double { UserDefaults.standard.double(forKey: continueRadiusKey) }
    static var showsLiveActivity: Bool { UserDefaults.standard.bool(forKey: liveActivityKey) }

    /// A random ID for this install, stored on first use.
    static var deviceID: String {
        if let id = UserDefaults.standard.string(forKey: deviceIDKey) { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: deviceIDKey)
        return id
    }
    static var fuelEconomy: Double { UserDefaults.standard.double(forKey: fuelEconomyKey) }
    static var fuelPrice: Double { UserDefaults.standard.double(forKey: fuelPriceKey) }
    static var mileageRate: Double { UserDefaults.standard.double(forKey: mileageRateKey) }

    static func mileageLabelKeys(_ raw: String) -> Set<String> {
        Set(raw.split(separator: ",").map(String.init))
    }

    /// Whether a trip goes in the mileage log.
    static func countsForMileage(_ trip: Trip) -> Bool {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: mileageAllTripsKey) { return true }
        return !trip.categoryRaw.isEmpty
            && mileageLabelKeys(defaults.string(forKey: mileageLabelsKey) ?? "").contains(trip.categoryRaw)
    }
}
