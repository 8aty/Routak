import CoreLocation
import CoreMotion
import Foundation
import Observation
import SwiftData
import UIKit
import UserNotifications

/// Watches for drives in the background and records them.
///
/// How it stays battery friendly:
/// - **Idle**: only low-power signals are on: significant location changes, visits,
///   a geofence around where you last parked (CLMonitor) and motion activity.
///   All of these can wake or relaunch the app in the background.
/// - **Probing**: when one of those fires, GPS turns on for up to two minutes to check speed.
/// - **Recording**: sustained driving speed starts a trip. GPS precision follows the driving:
///   full precision in town, coarser on highways, full again while charging. The trip ends
///   after you've been parked for a few minutes, unless the motion sensor says you're still
///   in the car (a red light or a traffic jam).
/// - **Paused**: you paused the trip (a gas stop, lunch). GPS is off and a geofence is set around the
///   car. Driving off resumes the same trip; a pause that lasts too long saves it.
/// - **Low battery**: below 10% (and not charging) GPS stays off entirely until the phone recovers.
@MainActor
@Observable
final class TripTracker: NSObject {
    static let shared = TripTracker()

    enum Mode: Equatable {
        case off, idle, probing, recording, paused, lowBattery
    }

    /// How much GPS precision a moving car needs.
    enum Precision: Int, Comparable {
        case highway, road, city
        static func < (a: Precision, b: Precision) -> Bool { a.rawValue < b.rawValue }
    }

    // MARK: Observable state for the UI

    private(set) var mode: Mode = .off
    private(set) var authorization: CLAuthorizationStatus = .notDetermined
    private(set) var hasPreciseLocation = true
    private(set) var activePoints: [TrackPoint] = []
    private(set) var activeDistance: CLLocationDistance = 0
    private(set) var activeStartDate: Date?
    private(set) var currentSpeed: CLLocationSpeed = 0
    private(set) var isManualTrip = false
    private(set) var statusDetail = ""
    /// True while stopped but still in the car, so the trip is kept open.
    private(set) var isHeldInTraffic = false
    /// True when the current trip continues one that ended a few minutes ago.
    private(set) var isContinuedTrip = false
    private(set) var precision: Precision = .city
    /// When the current trip was paused; nil unless `mode == .paused`.
    private(set) var pausedSince: Date?
    /// Finished pauses of the current trip, left out of its driving time.
    private(set) var activePausedDuration: TimeInterval = 0
    /// A manual trip that stopped moving ends at this time unless you answer "Still driving?".
    private(set) var stopCheckDeadline: Date?
    /// The last trip, when it ended recently and close by: it can be continued.
    private(set) var continuableTrip: Trip?

    /// A trip is being recorded or is paused.
    var hasOpenTrip: Bool { mode == .recording || mode == .paused }
    /// When the trip timer starts counting: the trip start, shifted by the time spent paused.
    var activeTimerStart: Date? { activeStartDate?.addingTimeInterval(activePausedDuration) }

    var hasAlwaysPermission: Bool { authorization == .authorizedAlways }
    var isAuthorized: Bool { authorization == .authorizedAlways || authorization == .authorizedWhenInUse }

    // MARK: Internals

    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private let motion = CMMotionActivityManager()
    @ObservationIgnored private var container: ModelContainer?
    @ObservationIgnored private var activeTrip: Trip?
    @ObservationIgnored private var lastAcceptedLocation: CLLocation?
    @ObservationIgnored private var lastMovingDate: Date?
    /// Where the car was when it last moved. Moving more than `stopRadius` from here counts as driving.
    @ObservationIgnored private var stopAnchor: CLLocation?
    @ObservationIgnored private var probeDeadline: Date?
    @ObservationIgnored private var probeBuffer: [CLLocation] = []
    @ObservationIgnored private var fastFixes = 0
    @ObservationIgnored private var isAutomotive = false
    @ObservationIgnored private var isWalking = false
    @ObservationIgnored private var walkingSince: Date?
    @ObservationIgnored private var rejectedRun = 0
    @ObservationIgnored private var unflushedCount = 0
    @ObservationIgnored private var lastFlush = Date.distantPast
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private var monitor: CLMonitor?
    @ObservationIgnored private var pendingDeparture: CLLocationCoordinate2D?
    @ObservationIgnored private var configured = false
    /// A drive that was too short to save. If driving resumes nearby within a few minutes it's joined back in.
    @ObservationIgnored private var recentDiscard: (points: [TrackPoint], end: Date)?
    /// Speed band we may switch to, and since when it has applied.
    @ObservationIgnored private var precisionCandidate: (precision: Precision, since: Date)?
    @ObservationIgnored private var isBatteryLow = false
    @ObservationIgnored private var activePauses: [TripPause] = []
    /// While paused: GPS is on briefly to check whether you drove off.
    @ObservationIgnored private var resumeCheckDeadline: Date?
    /// "Keep recording" was chosen: don't ask again until this time (or until the car moves).
    @ObservationIgnored private var stopCheckSnoozedUntil: Date?
    /// When a single fix was requested to check whether the last trip can be continued.
    @ObservationIgnored private var continueFixRequested: Date?
    /// When the last trip ended. Older fixes (iOS sometimes delivers them late) never start a new drive.
    @ObservationIgnored private var lastTripEnd: Date?

    // MARK: Tuning

    /// Sustained speed that counts as driving (~23 km/h / 15 mph).
    private let drivingSpeed: CLLocationSpeed = 6.5
    /// Above this we still consider the car moving (~9 km/h). Below it we're parked or crawling.
    private let movingSpeed: CLLocationSpeed = 2.5
    private let probeDuration: TimeInterval = 120
    private let maxProbeAccuracy: CLLocationAccuracy = 65
    /// Stop detection uses displacement, not reported speed, which can be noisy or stale while parked.
    private let stopRadius: CLLocationDistance = 60
    /// A probe must also cover this much ground before a drive starts.
    private let minProbeDisplacement: CLLocationDistance = 100
    private let departureRadius: CLLocationDistance = 150
    /// A drive detected this close to where the car was parked is drawn from the parking spot.
    private let maxBackfillDistance: CLLocationDistance = 3_000
    /// Walking for this long after stopping means you've left the car.
    private let walkAwayTime: TimeInterval = 60
    private static let departureID = "departure"

    private override init() {
        super.init()
    }

    private var context: ModelContext? { container?.mainContext }

    // MARK: - Lifecycle

    /// Called at every launch, including background relaunches triggered by location events.
    func configure(container: ModelContainer) {
        guard !configured else { return }
        configured = true
        self.container = container

        manager.delegate = self
        manager.activityType = .automotiveNavigation
        manager.pausesLocationUpdatesAutomatically = false
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = false
        authorization = manager.authorizationStatus
        hasPreciseLocation = manager.accuracyAuthorization == .fullAccuracy

        registerNotificationActions()
        startBatteryMonitoring()
        startMotionUpdates()
        Task { await startMonitor() }

        recoverActiveTrips()
        if !hasOpenTrip { applyIdleMode(near: nil) }
        #if DEBUG
        installDebugHooks()
        #endif
    }

    #if DEBUG
    /// Lets the simulator drive the tracker without tapping, e.g.
    /// `xcrun simctl spawn booted notifyutil -p cc.tomy.Routak.debug.endTrip` (also startTrip, pauseTrip, resumeTrip, continueTrip)
    private func installDebugHooks() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        for name in ["startTrip", "endTrip", "pauseTrip", "resumeTrip", "continueTrip"].map({ "cc.tomy.Routak.debug." + $0 }) {
            CFNotificationCenterAddObserver(center, nil, { _, _, name, _, _ in
                let action = (name?.rawValue as String?)?.components(separatedBy: ".").last
                Task { @MainActor in
                    let tracker = TripTracker.shared
                    switch action {
                    case "startTrip": tracker.startManualTrip()
                    case "pauseTrip": tracker.pauseTrip()
                    case "resumeTrip": tracker.resumeTrip()
                    case "continueTrip": if let trip = tracker.continuableTrip { tracker.continueTrip(trip) }
                    default: tracker.stopTrip()
                    }
                }
            }, name as CFString, nil, .deliverImmediately)
        }
    }
    #endif

    /// Re-applies preferences (e.g. auto-detect toggled in Settings).
    func settingsChanged() {
        updateBatteryState()
        guard !hasOpenTrip else { return }
        applyIdleMode(near: nil)
    }

    /// The app came to the foreground.
    func appBecameActive() {
        _ = expirePauseIfNeeded()
        refreshContinuableTrip()
    }

    // MARK: - Permissions

    func requestPermission() {
        switch authorization {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse:
            if UserDefaults.standard.bool(forKey: Prefs.askedAlwaysKey) {
                openSettings()
            } else {
                UserDefaults.standard.set(true, forKey: Prefs.askedAlwaysKey)
                manager.requestAlwaysAuthorization()
            }
        default:
            openSettings()
        }
    }

    func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    private func authorizationChanged() {
        let previous = authorization
        authorization = manager.authorizationStatus
        hasPreciseLocation = manager.accuracyAuthorization == .fullAccuracy

        // Right after "Allow While Using", ask to upgrade to "Always" so drives can be detected in the background.
        if authorization == .authorizedWhenInUse, previous == .notDetermined,
           !UserDefaults.standard.bool(forKey: Prefs.askedAlwaysKey) {
            UserDefaults.standard.set(true, forKey: Prefs.askedAlwaysKey)
            manager.requestAlwaysAuthorization()
        }
        if isAuthorized, previous != authorization {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        if !hasOpenTrip { applyIdleMode(near: nil) }
    }

    // MARK: - Public trip controls

    var canStartManualTrip: Bool { !hasOpenTrip && !isBatteryLow }

    func startManualTrip() {
        guard canStartManualTrip else { return }
        if authorization == .notDetermined { manager.requestWhenInUseAuthorization() }
        startTrip(manual: true, seed: [])
    }

    /// Ending a trip yourself always saves it, however short.
    func stopTrip() {
        finishTrip(byUser: true)
    }

    var canPause: Bool { mode == .recording && !activePoints.isEmpty }

    /// Keeps the trip open with GPS off, for a gas stop or a break. Driving off resumes it.
    func pauseTrip() {
        guard canPause, let spot = lastAcceptedLocation ?? activePoints.last?.location else { return }
        let now = Date()
        cancelStopCheck()
        activePauses.append(TripPause(start: now, coordinate: spot.coordinate))
        pausedSince = now
        mode = .paused
        isHeldInTraffic = false
        currentSpeed = 0
        statusDetail = String(localized: "Paused")
        flush(force: true)

        manager.stopUpdatingLocation()
        manager.showsBackgroundLocationIndicator = false
        resetResumeCheck()
        // The cheap signals that notice you driving off, as when parked.
        manager.startMonitoringSignificantLocationChanges()
        manager.startMonitoringVisits()
        armDeparture(at: spot.coordinate)
        startTicker()
        LiveActivityController.shared.tripPaused(at: now, distance: activeDistance, pausedTotal: activePausedDuration)
        WidgetSync.schedule()
    }

    func resumeTrip() {
        resume(seed: [], automatically: false)
    }

    /// Answer to "Still driving?": keep recording and don't ask again for a while.
    func keepRecording() {
        cancelStopCheck()
        stopCheckSnoozedUntil = Date().addingTimeInterval(30 * 60)
        lastMovingDate = Date()
    }

    /// Reopens a trip that ended a few minutes ago; the time in between counts as a pause.
    func continueTrip(_ trip: Trip) {
        guard !hasOpenTrip, !isBatteryLow, !trip.isActive else { return }
        if authorization == .notDetermined { manager.requestWhenInUseAuthorization() }
        resetActiveState()
        reopen(trip, resumingAt: Date())
        continuableTrip = nil
        beginRecording(manual: trip.isManual, seed: [])
    }

    enum ShortcutStart {
        case started, resumed, alreadyRecording, needsLocation, batteryLow
    }

    /// Starts recording from Siri, Shortcuts or an automation (e.g. CarPlay connected).
    /// Unlike a manual trip, it still ends by itself when you park. A paused trip resumes.
    func startTripFromShortcut() -> ShortcutStart {
        if mode == .recording { return .alreadyRecording }
        if mode == .paused {
            resumeTrip()
            return .resumed
        }
        guard isAuthorized else { return .needsLocation }
        if isBatteryLow { return .batteryLow }
        startTrip(manual: false, seed: [])
        return .started
    }

    // MARK: - Modes

    private func applyIdleMode(near location: CLLocation?) {
        manager.stopUpdatingLocation()
        manager.showsBackgroundLocationIndicator = false
        stopTicker()
        probeDeadline = nil
        probeBuffer = []
        fastFixes = 0
        resumeCheckDeadline = nil
        isHeldInTraffic = false

        if Prefs.autoDetect && isAuthorized {
            if isBatteryLow {
                // No GPS at all. The cheap cell/Wi-Fi based signals stay on so the app still
                // wakes up now and then and can resume once the phone is charged.
                mode = .lowBattery
                statusDetail = String(localized: "Paused to save battery")
            } else {
                mode = .idle
                statusDetail = hasAlwaysPermission ? String(localized: "Watching for drives") : String(localized: "Open the app to detect drives")
            }
            manager.startMonitoringSignificantLocationChanges()
            manager.startMonitoringVisits()
            if let coordinate = (location ?? manager.location)?.coordinate {
                armDeparture(at: coordinate)
            }
        } else {
            mode = .off
            statusDetail = isAuthorized ? String(localized: "Automatic detection is off") : String(localized: "Location access needed")
            manager.stopMonitoringSignificantLocationChanges()
            manager.stopMonitoringVisits()
            disarmDeparture()
        }
    }

    private func beginProbe(reason: String) {
        guard mode == .idle, Prefs.autoDetect, !isBatteryLow else { return }
        mode = .probing
        statusDetail = reason
        probeDeadline = Date().addingTimeInterval(probeDuration)
        probeBuffer = []
        fastFixes = 0
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
        manager.startUpdatingLocation()
        startTicker()
    }

    private func handleProbe(_ location: CLLocation) {
        if probeSeesDriving(location) {
            startTrip(manual: false, seed: probeBuffer)
        } else if let probeDeadline, Date() >= probeDeadline {
            endProbe()
        }
    }

    /// Adds a fix to `probeBuffer` and says whether it now looks like sustained driving.
    private func probeSeesDriving(_ location: CLLocation) -> Bool {
        guard location.horizontalAccuracy >= 0, location.horizontalAccuracy <= maxProbeAccuracy,
              location.timestamp > (lastTripEnd ?? .distantPast) else { return false }
        let previous = probeBuffer.last
        probeBuffer.append(location)
        probeBuffer.removeAll { location.timestamp.timeIntervalSince($0.timestamp) > 180 }

        let speed = effectiveSpeed(of: location, previous: previous)
        if speed >= drivingSpeed {
            fastFixes += 1
        } else if speed < movingSpeed {
            fastFixes = 0
        }
        let displacement = probeBuffer.first.map { location.distance(from: $0) } ?? 0
        let fastEnough = fastFixes >= 3 || (isAutomotive && speed >= movingSpeed * 2)
        return fastEnough && displacement >= minProbeDisplacement
    }

    private func endProbe() {
        let last = probeBuffer.last
        applyIdleMode(near: last)
    }

    // MARK: - Recording

    private func startTrip(manual: Bool, seed: [CLLocation]) {
        guard let context else { return }
        let start = seed.first?.timestamp ?? Date()
        let startLocation = seed.first ?? manager.location
        var parkingSpot: (location: CLLocation, since: Date)?

        resetActiveState()
        if !manual, Prefs.mergeTrips, let startLocation, let previous = recentTrip(near: startLocation) {
            // Picked up again right where the last drive ended: a gas stop or a long light.
            reopen(previous, resumingAt: start)
        } else {
            let trip = Trip(startDate: start, isManual: manual)
            context.insert(trip)
            activeTrip = trip
            activeStartDate = start
            statusDetail = manual ? String(localized: "Recording manual trip") : String(localized: "Drive detected")
            if !manual, Prefs.mergeTrips, let startLocation, let discard = recentDiscard,
               start.timeIntervalSince(discard.end) <= Prefs.mergeGap,
               let last = discard.points.last, last.location.distance(from: startLocation) <= Prefs.mergeRadius {
                // A short hop that was thrown away, followed by more driving: keep it after all.
                activePoints = discard.points
                activeDistance = RouteStats(discard.points).distance
                activeStartDate = discard.points.first?.timestamp ?? start
                trip.startDate = activeStartDate ?? start
                lastAcceptedLocation = last.location
            } else if !manual, let first = seed.first {
                parkingSpot = self.parkingSpot(before: first)
            }
        }
        recentDiscard = nil
        guard let parkingSpot, let first = seed.first else {
            beginRecording(manual: manual, seed: seed)
            return
        }

        // Detection always lags a little behind pulling away. Start the route where the car was
        // parked; road matching later draws the missing stretch along the roads.
        let distance = parkingSpot.location.distance(from: first)
        let latest = first.timestamp.addingTimeInterval(-distance / 25)
        let estimate = first.timestamp.addingTimeInterval(-distance / 7) // about 25 km/h in town
        let departure = min(max(estimate, parkingSpot.since.addingTimeInterval(1)), latest)
        activeStartDate = departure
        activeTrip?.startDate = departure
        record(Self.backfillPoint(at: parkingSpot.location.coordinate, time: departure))
        beginRecording(manual: manual, seed: seed, liveActivity: false)

        // The motion sensor knows when the car actually started moving: use that if it can tell.
        let trip = activeTrip
        Task {
            if let moved = await drivingStart(before: first.timestamp, notBefore: parkingSpot.since),
               activeTrip === trip, !activePoints.isEmpty {
                let refined = min(max(moved, parkingSpot.since.addingTimeInterval(1)), latest)
                activePoints[0].timestamp = refined
                activeStartDate = refined
                trip?.startDate = refined
                flush(force: true)
            }
            if activeTrip === trip, hasOpenTrip {
                LiveActivityController.shared.tripStarted(startDate: activeStartDate ?? departure, distance: activeDistance)
            }
        }
    }

    /// Picks the recording back up (after `startTrip`, `reopen` or recovery).
    private func beginRecording(manual: Bool, seed: [CLLocation], liveActivity: Bool = true) {
        lastMovingDate = Date()
        isManualTrip = manual
        mode = .recording
        probeDeadline = nil
        probeBuffer = []
        resumeCheckDeadline = nil
        disarmDeparture()

        startRecordingUpdates()
        for location in seed { record(location) }
        flush(force: true)
        if liveActivity {
            LiveActivityController.shared.tripStarted(
                startDate: activeStartDate ?? Date(), distance: activeDistance, pausedTotal: activePausedDuration
            )
        }
        WidgetSync.schedule()
    }

    /// Makes a saved trip the active one again. The time since it ended becomes a pause.
    private func reopen(_ trip: Trip, resumingAt time: Date) {
        trip.isActive = true
        activeTrip = trip
        activePoints = trip.points
        activeDistance = RouteStats(activePoints).distance
        activeStartDate = trip.startDate
        lastAcceptedLocation = activePoints.last?.location
        activePauses = trip.pauses
        if let last = activePoints.last {
            activePauses.append(TripPause(start: last.timestamp, end: max(time, last.timestamp), coordinate: last.coordinate))
        }
        activePausedDuration = activePauses.reduce(0) { $0 + $1.duration }
        isContinuedTrip = true
        statusDetail = String(localized: "Continuing your last trip")
    }

    /// Where the car was parked before a drive starting at `location`: the end of the last trip,
    /// if that's close enough to be where this drive set off from.
    private func parkingSpot(before location: CLLocation) -> (location: CLLocation, since: Date)? {
        guard let context else { return nil }
        var candidate: (location: CLLocation, since: Date)?
        var descriptor = FetchDescriptor<Trip>(
            predicate: #Predicate { $0.isActive == false },
            sortBy: [SortDescriptor(\.endDate, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        if let trip = try? context.fetch(descriptor).first, let end = trip.endCoordinate,
           trip.deviceID.isEmpty || trip.deviceID == Prefs.deviceID {
            candidate = (CLLocation(latitude: end.latitude, longitude: end.longitude), trip.endDate)
        }
        if let discard = recentDiscard, let last = discard.points.last, discard.end > (candidate?.since ?? .distantPast) {
            candidate = (last.location, discard.end)
        }
        guard let candidate, candidate.since < location.timestamp else { return nil }
        let distance = candidate.location.distance(from: location)
        guard distance >= 50, distance <= maxBackfillDistance else { return nil }
        return candidate
    }

    private static func backfillPoint(at coordinate: CLLocationCoordinate2D, time: Date) -> CLLocation {
        CLLocation(coordinate: coordinate, altitude: 0, horizontalAccuracy: 10, verticalAccuracy: -1,
                   course: -1, speed: -1, timestamp: time)
    }

    /// When the current stretch of driving began, according to the motion sensor.
    private func drivingStart(before end: Date, notBefore: Date) async -> Date? {
        guard CMMotionActivityManager.isActivityAvailable(),
              CMMotionActivityManager.authorizationStatus() == .authorized else { return nil }
        let from = max(notBefore, end.addingTimeInterval(-20 * 60))
        guard from < end else { return nil }
        let activities: [CMMotionActivity] = await withCheckedContinuation { continuation in
            motion.queryActivityStarting(from: from, to: end, to: .main) { activities, _ in
                continuation.resume(returning: activities ?? [])
            }
        }
        // Walk back from the newest: red lights (stationary) are part of the drive, walking is not.
        var start: Date?
        for activity in activities.reversed() {
            if activity.automotive {
                start = activity.startDate
            } else if (activity.walking || activity.running || activity.cycling) && activity.confidence != .low {
                break
            }
        }
        return start
    }

    /// The last saved automatic trip, if it ended within a few minutes and near `location`.
    private func recentTrip(near location: CLLocation) -> Trip? {
        guard let context else { return nil }
        var descriptor = FetchDescriptor<Trip>(
            predicate: #Predicate { $0.isActive == false },
            sortBy: [SortDescriptor(\.endDate, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        guard let trip = try? context.fetch(descriptor).first, !trip.isManual,
              trip.deviceID.isEmpty || trip.deviceID == Prefs.deviceID,
              location.timestamp.timeIntervalSince(trip.endDate) <= Prefs.mergeGap,
              location.timestamp >= trip.endDate.addingTimeInterval(-60),
              let end = trip.endCoordinate,
              CLLocation(latitude: end.latitude, longitude: end.longitude).distance(from: location) <= Prefs.mergeRadius
        else { return nil }
        return trip
    }

    private func startRecordingUpdates() {
        precision = .city
        precisionCandidate = nil
        applyPrecision()
        manager.showsBackgroundLocationIndicator = true
        manager.startUpdatingLocation()
        startTicker()
    }

    private func record(_ location: CLLocation) {
        // iOS may first hand over the last known position, from minutes ago: not part of this trip.
        if let activeStartDate, location.timestamp < activeStartDate.addingTimeInterval(-5) { return }
        let verdict = TrackCleaner.verdict(for: location, after: lastAcceptedLocation)
        if verdict == .reject {
            rejectedRun += 1
            // Several "jumps" in a row that agree with each other: the previous fix was the bad one.
            guard rejectedRun >= 3, location.horizontalAccuracy >= 0,
                  location.horizontalAccuracy <= TrackCleaner.maxAccuracy,
                  location.timestamp > (lastAcceptedLocation?.timestamp ?? .distantPast) else { return }
            lastAcceptedLocation = nil
        }
        rejectedRun = 0

        if let anchor = stopAnchor {
            if location.distance(from: anchor) > stopRadius {
                stopAnchor = location
                lastMovingDate = max(lastMovingDate ?? location.timestamp, location.timestamp)
                stopCheckSnoozedUntil = nil
                if stopCheckDeadline != nil {
                    cancelStopCheck()
                    statusDetail = String(localized: "Moving again")
                }
                if isHeldInTraffic {
                    isHeldInTraffic = false
                    statusDetail = String(localized: "Moving again")
                }
            }
        } else {
            stopAnchor = location
        }
        // Show 0 once we've been sitting still, even if the GPS still reports a speed.
        let stationaryFor = location.timestamp.timeIntervalSince(lastMovingDate ?? location.timestamp)
        currentSpeed = stationaryFor > 15 ? 0 : max(0, location.speed)
        updatePrecision(speed: currentSpeed, at: location.timestamp)

        guard verdict != .tooClose else { return }
        if let last = lastAcceptedLocation {
            activeDistance += location.distance(from: last)
        }
        lastAcceptedLocation = location
        activePoints.append(TrackPoint(location))
        unflushedCount += 1
        flush(force: false)
        LiveActivityController.shared.tripUpdated(distance: activeDistance, isStopped: isHeldInTraffic)
    }

    private func checkForStop(now: Date = Date()) {
        guard mode == .recording, let lastMovingDate else { return }
        let stoppedFor = now.timeIntervalSince(lastMovingDate)
        if isManualTrip {
            checkManualTripStopped(now: now, stoppedFor: stoppedFor)
            return
        }

        // Stopped, then walked away from the car: no need to wait out the full timeout.
        if let walkingSince, isWalking, stoppedFor >= walkAwayTime,
           now.timeIntervalSince(walkingSince) >= walkAwayTime {
            finishTrip()
            return
        }
        guard stoppedFor >= Prefs.stopTimeout else { return }

        // The motion sensor still says "in a car": a red light or a jam, not parked.
        if isAutomotive, stoppedFor < Prefs.maxTrafficHold {
            if !isHeldInTraffic {
                isHeldInTraffic = true
                statusDetail = String(localized: "Stopped in traffic")
                LiveActivityController.shared.tripUpdated(distance: activeDistance, isStopped: true)
            }
            return
        }
        finishTrip()
    }

    /// `byUser`: ended with the End Trip button, Siri or the Live Activity, so it's kept however short.
    private func finishTrip(reason: String? = nil, byUser: Bool = false) {
        guard hasOpenTrip else { return }
        cancelStopCheck()
        guard let trip = activeTrip, let context else {
            resetActiveState()
            applyIdleMode(near: nil)
            return
        }

        // A trip ended while paused ends where it was paused.
        activePauses.removeAll { $0.end == nil }
        trip.pauses = activePauses
        var points = activePoints
        if !isManualTrip, let lastMovingDate {
            // Drop the minutes spent parked at the end.
            points.removeAll { $0.timestamp > lastMovingDate.addingTimeInterval(20) }
        }
        points = TrackCleaner.clean(points)
        let stats = RouteStats(points)
        let longEnough = stats.distance >= Prefs.minTripDistance && stats.duration >= 60
        // A continued trip was already saved once: never throw it away.
        let keep = points.count >= 2 && (isManualTrip || isContinuedTrip || byUser || longEnough)
        let endLocation = lastAcceptedLocation
        let wasManual = isManualTrip
        lastTripEnd = Date()

        if keep {
            let keptStart = trip.startName
            trip.apply(points: points)
            trip.isActive = false
            try? context.save()
            nameAndAnnounce(trip, points: points, keepStartName: isContinuedTrip ? keptStart : nil, reason: reason)
        } else {
            if !wasManual, points.count >= 2 { recentDiscard = (points, points.last!.timestamp) }
            context.delete(trip)
            try? context.save()
        }

        LiveActivityController.shared.tripEnded(savedDistance: keep ? stats.distance : nil, pausedTotal: trip.pausedSeconds)
        WidgetSync.schedule()
        resetActiveState()
        applyIdleMode(near: endLocation)
        // Ended by hand right here: offer to carry on, in case that was a mistake or just a stop.
        continuableTrip = keep && byUser ? trip : nil
    }

    private func resetActiveState() {
        activeTrip = nil
        activePoints = []
        activeDistance = 0
        activeStartDate = nil
        isManualTrip = false
        isContinuedTrip = false
        isHeldInTraffic = false
        activePauses = []
        activePausedDuration = 0
        pausedSince = nil
        resumeCheckDeadline = nil
        stopCheckDeadline = nil
        stopCheckSnoozedUntil = nil
        lastMovingDate = nil
        stopAnchor = nil
        lastAcceptedLocation = nil
        rejectedRun = 0
        unflushedCount = 0
        currentSpeed = 0
    }

    /// Persists in-progress points so a trip survives the app being terminated.
    private func flush(force: Bool) {
        guard let trip = activeTrip, let context else { return }
        guard force || (unflushedCount > 0 && Date().timeIntervalSince(lastFlush) >= 20) else { return }
        trip.pointsData = TrackPoint.encode(activePoints)
        trip.pauses = activePauses
        trip.distance = activeDistance
        trip.endDate = activePoints.last?.timestamp ?? trip.startDate
        try? context.save()
        unflushedCount = 0
        lastFlush = Date()
    }

    /// On launch, resume a trip that was being recorded, or finalize one that went stale.
    private func recoverActiveTrips() {
        guard let context else { return }
        let descriptor = FetchDescriptor<Trip>(predicate: #Predicate { $0.isActive == true })
        guard let trips = try? context.fetch(descriptor), !trips.isEmpty else { return }

        for trip in trips {
            let points = trip.points
            let lastTime = points.last?.timestamp ?? trip.startDate
            // Being recorded on another device and synced here through iCloud: that device finishes it.
            // Only take over a trip that device clearly abandoned.
            if !trip.deviceID.isEmpty, trip.deviceID != Prefs.deviceID,
               Date().timeIntervalSince(lastTime) < 6 * 3_600 { continue }
            let pauses = trip.pauses
            let openPause = pauses.last.flatMap { $0.end == nil ? $0 : nil }
            let canResume = !hasOpenTrip
                && Date().timeIntervalSince(lastTime) < Prefs.stopTimeout
                && (trip.isManual || Prefs.autoDetect)
            let canStayPaused = !hasOpenTrip && openPause.map { Date().timeIntervalSince($0.start) < Prefs.maxPause } == true

            activeTrip = trip
            activePoints = points
            activeDistance = RouteStats(points).distance
            activeStartDate = trip.startDate
            activePauses = pauses
            activePausedDuration = pauses.reduce(0) { $0 + $1.duration }
            isManualTrip = trip.isManual
            lastMovingDate = lastTime
            stopAnchor = points.last?.location
            lastAcceptedLocation = points.last?.location
            mode = .recording

            if let openPause, canStayPaused {
                // Relaunched while paused: keep waiting for the drive to continue.
                mode = .paused
                pausedSince = openPause.start
                statusDetail = String(localized: "Paused")
                manager.startMonitoringSignificantLocationChanges()
                manager.startMonitoringVisits()
                armDeparture(at: openPause.coordinate)
                LiveActivityController.shared.tripPaused(at: openPause.start, distance: activeDistance, pausedTotal: activePausedDuration)
            } else if openPause == nil, canResume {
                statusDetail = String(localized: "Resumed trip")
                startRecordingUpdates()
                LiveActivityController.shared.tripStarted(startDate: trip.startDate, distance: activeDistance, pausedTotal: activePausedDuration)
            } else {
                finishTrip()
            }
        }
    }

    // MARK: - GPS precision (battery)

    private func targetPrecision(for speed: CLLocationSpeed) -> Precision {
        if speed >= 25 { return .highway }   // ~90 km/h
        if speed >= 15 { return .road }      // ~54 km/h
        return .city
    }

    /// Switches precision when the speed band has been stable for a while.
    /// Slowing down switches quickly (turns and exits need detail); speeding up waits longer.
    private func updatePrecision(speed: CLLocationSpeed, at time: Date) {
        var target = targetPrecision(for: speed)
        let device = UIDevice.current
        if device.batteryState == .charging || device.batteryState == .full {
            target = .city // plugged into the car: no reason to save power
        } else if ProcessInfo.processInfo.isLowPowerModeEnabled {
            target = min(target, .road)
        }
        guard target != precision else {
            precisionCandidate = nil
            return
        }
        if precisionCandidate?.precision != target {
            precisionCandidate = (target, time)
            return
        }
        let wait: TimeInterval = target > precision ? 5 : 30
        if let candidate = precisionCandidate, time.timeIntervalSince(candidate.since) >= wait {
            precision = target
            precisionCandidate = nil
            applyPrecision()
        }
    }

    private func applyPrecision() {
        switch precision {
        case .city:
            manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
            manager.distanceFilter = kCLDistanceFilterNone
        case .road:
            manager.desiredAccuracy = kCLLocationAccuracyBest
            manager.distanceFilter = 20
        case .highway:
            manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
            manager.distanceFilter = 50
        }
    }

    // MARK: - Battery

    private func startBatteryMonitoring() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let center = NotificationCenter.default
        for name in [UIDevice.batteryLevelDidChangeNotification, UIDevice.batteryStateDidChangeNotification,
                     Notification.Name.NSProcessInfoPowerStateDidChange] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateBatteryState() }
            }
        }
        updateBatteryState()
    }

    private func updateBatteryState() {
        let device = UIDevice.current
        let level = device.batteryLevel // -1 when unknown (simulator)
        let pluggedIn = device.batteryState == .charging || device.batteryState == .full
        let wasLow = isBatteryLow

        if !Prefs.lowBatteryStop || pluggedIn || level < 0 {
            isBatteryLow = false
        } else if level <= Prefs.batteryStopLevel {
            isBatteryLow = true
        } else if level >= Prefs.batteryResumeLevel {
            isBatteryLow = false
        }
        guard wasLow != isBatteryLow else { return }

        if isBatteryLow {
            if mode == .recording {
                finishTrip(reason: String(localized: "Recording stopped because the battery is low."))
            } else {
                applyIdleMode(near: nil)
            }
        } else if mode == .lowBattery {
            applyIdleMode(near: nil)
        }
    }

    // MARK: - Timer

    private func startTicker() {
        guard ticker == nil else { return }
        ticker = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    private func tick() {
        switch mode {
        case .probing:
            if let probeDeadline, Date() >= probeDeadline { endProbe() }
        case .recording:
            checkForStop()
            flush(force: false)
        case .paused:
            if expirePauseIfNeeded() { return }
            if let resumeCheckDeadline, Date() >= resumeCheckDeadline { endResumeCheck() }
        case .idle, .off, .lowBattery:
            stopTicker()
        }
    }

    // MARK: - Motion activity

    private func startMotionUpdates() {
        guard CMMotionActivityManager.isActivityAvailable() else { return }
        motion.startActivityUpdates(to: .main) { [weak self] activity in
            guard let activity else { return }
            MainActor.assumeIsolated { self?.handleMotion(activity) }
        }
    }

    private func handleMotion(_ activity: CMMotionActivity) {
        isAutomotive = activity.automotive && activity.confidence != .low
        let walking = (activity.walking || activity.running) && activity.confidence != .low && !activity.automotive
        if walking, !isWalking { walkingSince = activity.startDate }
        isWalking = walking
        if !walking { walkingSince = nil }

        if isAutomotive, mode == .idle {
            beginProbe(reason: String(localized: "Driving motion detected"))
        }
        if isAutomotive, mode == .paused { beginResumeCheck() }
        if mode == .recording, isWalking { checkForStop() }
    }

    // MARK: - Departure geofence

    private func startMonitor() async {
        let monitor = await CLMonitor("RoutakMonitor")
        self.monitor = monitor
        if let pendingDeparture {
            self.pendingDeparture = nil
            armDeparture(at: pendingDeparture)
        }
        do {
            for try await event in await monitor.events {
                if event.identifier == Self.departureID, event.state == .unsatisfied {
                    handleDeparture()
                }
            }
        } catch {
            // Monitoring ended; low-power fallbacks (significant changes, visits) still work.
        }
    }

    private func armDeparture(at coordinate: CLLocationCoordinate2D) {
        guard let monitor else {
            pendingDeparture = coordinate
            return
        }
        let condition = CLMonitor.CircularGeographicCondition(center: coordinate, radius: departureRadius)
        Task {
            await monitor.remove(Self.departureID)
            await monitor.add(condition, identifier: Self.departureID, assuming: .satisfied)
        }
    }

    private func disarmDeparture() {
        pendingDeparture = nil
        guard let monitor else { return }
        Task { await monitor.remove(Self.departureID) }
    }

    private func handleDeparture() {
        updateBatteryState()
        if mode == .idle { beginProbe(reason: String(localized: "Left parking spot")) }
        if mode == .paused { beginResumeCheck() }
    }

    // MARK: - Location events

    private func handle(_ locations: [CLLocation]) {
        for location in locations {
            if let requested = continueFixRequested {
                continueFixRequested = nil
                // The one fix asked for to offer "Continue last trip": not a sign of driving.
                if mode == .idle || mode == .off || mode == .lowBattery, Date().timeIntervalSince(requested) < 20 {
                    updateContinuableTrip(at: location)
                    continue
                }
            }
            // A forgotten pause is saved first; the fix may then start a new drive.
            if mode == .paused { _ = expirePauseIfNeeded() }
            switch mode {
            case .off:
                return
            case .lowBattery:
                // Woken by a cheap location signal: check whether the battery has recovered.
                updateBatteryState()
                return
            case .idle:
                // Significant-change or initial fix: something moved, check whether we're driving.
                if Date().timeIntervalSince(location.timestamp) < 120 {
                    beginProbe(reason: String(localized: "Movement detected"))
                    handleProbe(location)
                }
            case .probing:
                handleProbe(location)
            case .recording:
                record(location)
                checkForStop(now: location.timestamp)
            case .paused:
                if resumeCheckDeadline == nil {
                    guard Date().timeIntervalSince(location.timestamp) < 120 else { continue }
                    beginResumeCheck()
                }
                handleResumeCheck(location)
            }
        }
    }

    private func effectiveSpeed(of location: CLLocation, previous: CLLocation?) -> CLLocationSpeed {
        if location.speed >= 0 { return location.speed }
        guard let previous else { return 0 }
        let elapsed = location.timestamp.timeIntervalSince(previous.timestamp)
        guard elapsed > 0 else { return 0 }
        return location.distance(from: previous) / elapsed
    }

    // MARK: - Pause and resume

    /// Saves a paused trip that has waited longer than the pause limit. It ends where it was paused,
    /// so saving it late (the app only runs when something wakes it) changes nothing.
    private func expirePauseIfNeeded() -> Bool {
        guard mode == .paused, let pausedSince, Date().timeIntervalSince(pausedSince) >= Prefs.maxPause else { return false }
        finishTrip(reason: String(localized: "Paused too long, so the trip ended."))
        return true
    }

    private func resume(seed: [CLLocation], automatically: Bool) {
        guard mode == .paused else { return }
        let resumedAt = seed.first?.timestamp ?? Date()
        if let index = activePauses.lastIndex(where: { $0.end == nil }) {
            activePauses[index].end = max(resumedAt, activePauses[index].start)
        }
        activePausedDuration = activePauses.reduce(0) { $0 + $1.duration }
        pausedSince = nil
        stopAnchor = nil
        isContinuedTrip = true
        statusDetail = automatically ? String(localized: "Drive resumed") : String(localized: "Recording")
        beginRecording(manual: isManualTrip, seed: seed, liveActivity: false)
        LiveActivityController.shared.tripResumed(distance: activeDistance, pausedTotal: activePausedDuration)
    }

    /// Something suggests the car may be moving: GPS on for a moment to check.
    private func beginResumeCheck() {
        guard mode == .paused, resumeCheckDeadline == nil, !isBatteryLow, isAuthorized else { return }
        if expirePauseIfNeeded() { return }
        resumeCheckDeadline = Date().addingTimeInterval(probeDuration)
        probeBuffer = []
        fastFixes = 0
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
        manager.startUpdatingLocation()
        startTicker()
    }

    private func handleResumeCheck(_ location: CLLocation) {
        if probeSeesDriving(location) {
            resume(seed: probeBuffer, automatically: true)
        } else if let resumeCheckDeadline, Date() >= resumeCheckDeadline {
            endResumeCheck()
        }
    }

    /// Not driving after all (walking to the shop, say): GPS off again.
    private func endResumeCheck() {
        let here = probeBuffer.last
        resetResumeCheck()
        manager.stopUpdatingLocation()
        // Watch around where the phone is now, so walking about doesn't keep waking the GPS.
        if let coordinate = here?.coordinate ?? activePauses.last?.coordinate {
            armDeparture(at: coordinate)
        }
    }

    private func resetResumeCheck() {
        resumeCheckDeadline = nil
        probeBuffer = []
        fastFixes = 0
    }

    // MARK: - Continue last trip

    /// Offers the last trip for continuing when it ended recently and close to here.
    func refreshContinuableTrip() {
        guard !hasOpenTrip, let trip = recentlyEndedTrip() else {
            continuableTrip = nil
            return
        }
        if let location = manager.location, Date().timeIntervalSince(location.timestamp) < 60 {
            updateContinuableTrip(at: location, trip: trip)
        } else if isAuthorized, mode != .probing, continueFixRequested == nil {
            continueFixRequested = Date()
            manager.requestLocation()
        }
    }

    private func updateContinuableTrip(at location: CLLocation, trip: Trip? = nil) {
        guard !hasOpenTrip, let trip = trip ?? recentlyEndedTrip(), let end = trip.endCoordinate else {
            continuableTrip = nil
            return
        }
        let distance = CLLocation(latitude: end.latitude, longitude: end.longitude).distance(from: location)
        continuableTrip = distance <= Prefs.continueRadius + max(location.horizontalAccuracy, 0) ? trip : nil
    }

    /// The last trip recorded on this phone, if it ended within the continue window.
    private func recentlyEndedTrip() -> Trip? {
        guard let context else { return nil }
        var descriptor = FetchDescriptor<Trip>(
            predicate: #Predicate { $0.isActive == false },
            sortBy: [SortDescriptor(\.endDate, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        guard let trip = try? context.fetch(descriptor).first,
              trip.deviceID.isEmpty || trip.deviceID == Prefs.deviceID,
              Date().timeIntervalSince(trip.endDate) <= Prefs.continueWindow
        else { return nil }
        return trip
    }

    // MARK: - "Still driving?" (manual trips)

    static let stopCheckCategory = "stopCheck"
    static let stopCheckNotificationID = "stopCheck"
    enum StopCheckAction: String {
        case end = "stopCheck.end", pause = "stopCheck.pause", keep = "stopCheck.keep"
    }

    private func registerNotificationActions() {
        let category = UNNotificationCategory(
            identifier: Self.stopCheckCategory,
            actions: [
                UNNotificationAction(identifier: StopCheckAction.keep.rawValue, title: String(localized: "Keep Recording")),
                UNNotificationAction(identifier: StopCheckAction.pause.rawValue, title: String(localized: "Pause")),
                UNNotificationAction(identifier: StopCheckAction.end.rawValue, title: String(localized: "End Trip"), options: .destructive),
            ],
            intentIdentifiers: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    func handleStopCheckAction(_ identifier: String) {
        switch StopCheckAction(rawValue: identifier) {
        case .end: if hasOpenTrip { stopTrip() }
        case .pause: pauseTrip()
        case .keep: keepRecording()
        case nil: break
        }
    }

    /// A manual trip never ends by itself while you drive. If it looks forgotten (parked a while,
    /// or walked away from the car), it asks, then ends unless you say otherwise.
    private func checkManualTripStopped(now: Date, stoppedFor: TimeInterval) {
        if let stopCheckDeadline {
            if now >= stopCheckDeadline {
                finishTrip(reason: String(localized: "You stopped moving, so the trip ended."))
            }
            return
        }
        if let stopCheckSnoozedUntil, now < stopCheckSnoozedUntil { return }
        let walkedAway = isWalking && stoppedFor >= walkAwayTime * 2
            && walkingSince.map { now.timeIntervalSince($0) >= walkAwayTime * 2 } == true
        var checkAfter = Prefs.manualStopCheck
        #if DEBUG
        // `-manualStopCheck 30` asks sooner (for testing).
        if UserDefaults.standard.double(forKey: "manualStopCheck") > 0 { checkAfter = UserDefaults.standard.double(forKey: "manualStopCheck") }
        #endif
        let parked = stoppedFor >= checkAfter && !(isAutomotive && stoppedFor < Prefs.maxTrafficHold)
        guard walkedAway || parked else { return }

        stopCheckDeadline = now.addingTimeInterval(Prefs.stopCheckGrace)
        statusDetail = String(localized: "Not moving")
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Still driving?")
        content.body = String(localized: "Trip ends in 1 minute.")
        content.categoryIdentifier = Self.stopCheckCategory
        content.sound = .default
        let request = UNNotificationRequest(identifier: Self.stopCheckNotificationID, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func cancelStopCheck() {
        guard stopCheckDeadline != nil else { return }
        stopCheckDeadline = nil
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [Self.stopCheckNotificationID])
        center.removePendingNotificationRequests(withIdentifiers: [Self.stopCheckNotificationID])
    }

    // MARK: - After saving

    private func nameAndAnnounce(_ trip: Trip, points: [TrackPoint], keepStartName: String?, reason: String?) {
        guard let first = points.first, let last = points.last, let context else { return }
        let places = PlaceBook.all(in: context)
        let task = UIApplication.shared.beginBackgroundTask(withName: "NameTrip")
        Task {
            if let keepStartName {
                trip.startName = keepStartName
            } else {
                trip.startName = await TripNamer.name(for: first, places: places)
            }
            trip.endName = await TripNamer.name(for: last, places: places)
            try? context.save()
            WidgetSync.schedule()
            postSavedNotification(for: trip, reason: reason)
            UIApplication.shared.endBackgroundTask(task)
            await TripMaintenance.snap(trip, context: context)
        }
    }

    private func postSavedNotification(for trip: Trip, reason: String?) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Trip saved")
        // No sound or vibration: it may arrive while still in the car (e.g. low battery ends the trip).
        content.interruptionLevel = .passive
        content.body = "\(trip.title) · \(Format.distance(trip.distance, miles: Prefs.useMiles)) · \(Format.duration(trip.duration))"
        if let reason { content.body += "\n\(reason)" }
        // Same identifier for a continued trip, so the notification is updated rather than duplicated.
        let request = UNNotificationRequest(identifier: trip.id.uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

// MARK: - CLLocationManagerDelegate

extension TripTracker: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated { self.authorizationChanged() }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        MainActor.assumeIsolated { self.handle(locations) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
        MainActor.assumeIsolated {
            self.updateBatteryState()
            if self.mode == .paused, self.expirePauseIfNeeded() { return }
            if visit.departureDate != .distantFuture {
                self.beginProbe(reason: String(localized: "Left a place"))
                self.beginResumeCheck()
            } else if self.mode == .idle {
                self.armDeparture(at: visit.coordinate)
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // kCLErrorLocationUnknown is transient; everything else is surfaced through authorization state.
        MainActor.assumeIsolated { self.continueFixRequested = nil }
    }
}
