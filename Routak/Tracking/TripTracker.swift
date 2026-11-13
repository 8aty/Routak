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
/// - **Recording**: sustained driving speed starts a trip with full-accuracy GPS. The trip ends
///   after you've been parked for a few minutes, and it is saved if it is long enough.
@MainActor
@Observable
final class TripTracker: NSObject {
    static let shared = TripTracker()

    enum Mode: Equatable {
        case off, idle, probing, recording
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
    @ObservationIgnored private var unflushedCount = 0
    @ObservationIgnored private var lastFlush = Date.distantPast
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private var monitor: CLMonitor?
    @ObservationIgnored private var pendingDeparture: CLLocationCoordinate2D?
    @ObservationIgnored private var configured = false

    // MARK: Tuning

    /// Sustained speed that counts as driving (~23 km/h / 15 mph).
    private let drivingSpeed: CLLocationSpeed = 6.5
    /// Above this we still consider the car moving (~9 km/h). Below it we're parked or crawling.
    private let movingSpeed: CLLocationSpeed = 2.5
    private let probeDuration: TimeInterval = 120
    private let maxRecordAccuracy: CLLocationAccuracy = 50
    private let maxProbeAccuracy: CLLocationAccuracy = 65
    private let minPointSpacing: CLLocationDistance = 8
    /// Stop detection uses displacement, not reported speed, which can be noisy or stale while parked.
    private let stopRadius: CLLocationDistance = 60
    /// A probe must also cover this much ground before a drive starts.
    private let minProbeDisplacement: CLLocationDistance = 100
    private let departureRadius: CLLocationDistance = 150
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

        startMotionUpdates()
        Task { await startMonitor() }

        recoverActiveTrips()
        if mode != .recording { applyIdleMode(near: nil) }
        #if DEBUG
        installDebugHooks()
        #endif
    }

    #if DEBUG
    /// Lets the simulator drive the tracker without tapping, e.g.
    /// `xcrun simctl spawn booted notifyutil -p cc.tomy.Routak.debug.endTrip`
    private func installDebugHooks() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        for name in ["cc.tomy.Routak.debug.startTrip", "cc.tomy.Routak.debug.endTrip"] {
            CFNotificationCenterAddObserver(center, nil, { _, _, name, _, _ in
                let isStart = (name?.rawValue as String?)?.hasSuffix("startTrip") == true
                Task { @MainActor in
                    if isStart { TripTracker.shared.startManualTrip() } else { TripTracker.shared.stopTrip() }
                }
            }, name as CFString, nil, .deliverImmediately)
        }
    }
    #endif

    /// Re-applies preferences (e.g. auto-detect toggled in Settings).
    func settingsChanged() {
        guard mode != .recording else { return }
        applyIdleMode(near: nil)
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
        if mode != .recording { applyIdleMode(near: nil) }
    }

    // MARK: - Public trip controls

    func startManualTrip() {
        guard mode != .recording else { return }
        if authorization == .notDetermined { manager.requestWhenInUseAuthorization() }
        startTrip(manual: true, seed: [])
    }

    func stopTrip() {
        finishTrip()
    }

    // MARK: - Modes

    private func applyIdleMode(near location: CLLocation?) {
        manager.stopUpdatingLocation()
        manager.showsBackgroundLocationIndicator = false
        stopTicker()
        probeDeadline = nil
        probeBuffer = []
        fastFixes = 0

        if Prefs.autoDetect && isAuthorized {
            mode = .idle
            statusDetail = hasAlwaysPermission ? "Watching for drives" : "Open the app to detect drives"
            manager.startMonitoringSignificantLocationChanges()
            manager.startMonitoringVisits()
            if let coordinate = (location ?? manager.location)?.coordinate {
                armDeparture(at: coordinate)
            }
        } else {
            mode = .off
            statusDetail = isAuthorized ? "Automatic detection is off" : "Location access needed"
            manager.stopMonitoringSignificantLocationChanges()
            manager.stopMonitoringVisits()
            disarmDeparture()
        }
    }

    private func beginProbe(reason: String) {
        guard mode == .idle, Prefs.autoDetect else { return }
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
        guard location.horizontalAccuracy >= 0, location.horizontalAccuracy <= maxProbeAccuracy else { return }
        let previous = probeBuffer.last
        probeBuffer.append(location)
        probeBuffer.removeAll { location.timestamp.timeIntervalSince($0.timestamp) > 180 }
        currentSpeed = max(0, location.speed)

        let speed = effectiveSpeed(of: location, previous: previous)
        if speed >= drivingSpeed {
            fastFixes += 1
        } else if speed < movingSpeed {
            fastFixes = 0
        }
        let displacement = probeBuffer.first.map { location.distance(from: $0) } ?? 0
        let fastEnough = fastFixes >= 3 || (isAutomotive && speed >= movingSpeed * 2)
        if fastEnough && displacement >= minProbeDisplacement {
            startTrip(manual: false, seed: probeBuffer)
        } else if let probeDeadline, Date() >= probeDeadline {
            endProbe()
        }
    }

    private func endProbe() {
        let last = probeBuffer.last
        applyIdleMode(near: last)
    }

    // MARK: - Recording

    private func startTrip(manual: Bool, seed: [CLLocation]) {
        guard let context else { return }
        let start = seed.first?.timestamp ?? Date()
        let trip = Trip(startDate: start, isManual: manual)
        context.insert(trip)

        activeTrip = trip
        activePoints = []
        activeDistance = 0
        activeStartDate = start
        lastAcceptedLocation = nil
        lastMovingDate = Date()
        stopAnchor = nil
        isManualTrip = manual
        mode = .recording
        statusDetail = manual ? "Recording manual trip" : "Drive detected"
        probeDeadline = nil
        probeBuffer = []
        disarmDeparture()

        startRecordingUpdates()
        for location in seed { record(location) }
        flush(force: true)
    }

    private func startRecordingUpdates() {
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = kCLDistanceFilterNone
        manager.showsBackgroundLocationIndicator = true
        manager.startUpdatingLocation()
        startTicker()
    }

    private func record(_ location: CLLocation) {
        guard location.horizontalAccuracy >= 0, location.horizontalAccuracy <= maxRecordAccuracy else { return }

        if let anchor = stopAnchor {
            if location.distance(from: anchor) > stopRadius {
                stopAnchor = location
                lastMovingDate = max(lastMovingDate ?? location.timestamp, location.timestamp)
            }
        } else {
            stopAnchor = location
        }
        // Show 0 once we've been sitting still, even if the GPS still reports a speed.
        let stationaryFor = location.timestamp.timeIntervalSince(lastMovingDate ?? location.timestamp)
        currentSpeed = stationaryFor > 15 ? 0 : max(0, location.speed)

        if let last = lastAcceptedLocation {
            let delta = location.distance(from: last)
            guard delta >= minPointSpacing else { return }
            let elapsed = max(location.timestamp.timeIntervalSince(last.timestamp), 0.5)
            guard delta / elapsed < 90 else { return } // reject GPS jumps (> 320 km/h)
            activeDistance += delta
        }
        lastAcceptedLocation = location
        activePoints.append(TrackPoint(location))
        unflushedCount += 1
        flush(force: false)
    }

    private func checkForStop(now: Date = Date()) {
        guard mode == .recording, !isManualTrip, let lastMovingDate else { return }
        if now.timeIntervalSince(lastMovingDate) >= Prefs.stopTimeout {
            finishTrip()
        }
    }

    private func finishTrip() {
        guard mode == .recording else { return }
        guard let trip = activeTrip, let context else {
            resetActiveState()
            applyIdleMode(near: nil)
            return
        }

        var points = activePoints
        if !isManualTrip, let lastMovingDate {
            // Drop the minutes spent parked at the end.
            points.removeAll { $0.timestamp > lastMovingDate.addingTimeInterval(20) }
        }
        let stats = RouteStats(points)
        let longEnough = stats.distance >= Prefs.minTripDistance && stats.duration >= 60
        let keep = points.count >= 2 && (isManualTrip || longEnough)
        let endLocation = lastAcceptedLocation

        if keep {
            trip.apply(points: points)
            trip.isActive = false
            try? context.save()
            nameAndAnnounce(trip, points: points)
        } else {
            context.delete(trip)
            try? context.save()
        }

        resetActiveState()
        applyIdleMode(near: endLocation)
    }

    private func resetActiveState() {
        activeTrip = nil
        activePoints = []
        activeDistance = 0
        activeStartDate = nil
        isManualTrip = false
        lastMovingDate = nil
        stopAnchor = nil
        lastAcceptedLocation = nil
        unflushedCount = 0
        currentSpeed = 0
    }

    /// Persists in-progress points so a trip survives the app being terminated.
    private func flush(force: Bool) {
        guard let trip = activeTrip, let context else { return }
        guard force || (unflushedCount > 0 && Date().timeIntervalSince(lastFlush) >= 20) else { return }
        trip.pointsData = TrackPoint.encode(activePoints)
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
            let canResume = mode != .recording
                && Date().timeIntervalSince(lastTime) < Prefs.stopTimeout
                && (trip.isManual || Prefs.autoDetect)

            activeTrip = trip
            activePoints = points
            activeDistance = RouteStats(points).distance
            activeStartDate = trip.startDate
            isManualTrip = trip.isManual
            lastMovingDate = lastTime
            stopAnchor = points.last?.location
            lastAcceptedLocation = points.last?.location
            mode = .recording

            if canResume {
                statusDetail = "Resumed trip"
                startRecordingUpdates()
            } else {
                finishTrip()
            }
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
        case .idle, .off:
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
        if isAutomotive, mode == .idle {
            beginProbe(reason: "Driving motion detected")
        }
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
        if mode == .idle { beginProbe(reason: "Left parking spot") }
    }

    // MARK: - Location events

    private func handle(_ locations: [CLLocation]) {
        for location in locations {
            switch mode {
            case .off:
                return
            case .idle:
                // Significant-change or initial fix: something moved, check whether we're driving.
                if Date().timeIntervalSince(location.timestamp) < 120 {
                    beginProbe(reason: "Movement detected")
                    handleProbe(location)
                }
            case .probing:
                handleProbe(location)
            case .recording:
                record(location)
                checkForStop(now: location.timestamp)
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

    // MARK: - After saving

    private func nameAndAnnounce(_ trip: Trip, points: [TrackPoint]) {
        guard let first = points.first, let last = points.last else { return }
        let task = UIApplication.shared.beginBackgroundTask(withName: "NameTrip")
        Task {
            async let start = PlaceNamer.name(for: first.location)
            async let end = PlaceNamer.name(for: last.location)
            let (startName, endName) = await (start, end)
            trip.startName = startName
            trip.endName = endName
            try? context?.save()
            postSavedNotification(for: trip)
            UIApplication.shared.endBackgroundTask(task)
        }
    }

    private func postSavedNotification(for trip: Trip) {
        let miles = UserDefaults.standard.bool(forKey: Prefs.useMilesKey)
        let content = UNMutableNotificationContent()
        content.title = "Trip saved"
        content.body = "\(trip.title) · \(Format.distance(trip.distance, miles: miles)) · \(Format.duration(trip.duration))"
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
            if visit.departureDate != .distantFuture {
                self.beginProbe(reason: "Left a place")
            } else if self.mode == .idle {
                self.armDeparture(at: visit.coordinate)
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // kCLErrorLocationUnknown is transient; everything else is surfaced through authorization state.
    }
}
