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
/// - **Low battery**: below 10% (and not charging) GPS stays off entirely until the phone recovers.
@MainActor
@Observable
final class TripTracker: NSObject {
    static let shared = TripTracker()

    enum Mode: Equatable {
        case off, idle, probing, recording, lowBattery
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

        startBatteryMonitoring()
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
        updateBatteryState()
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

    var canStartManualTrip: Bool { mode != .recording && !isBatteryLow }

    func startManualTrip() {
        guard canStartManualTrip else { return }
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
        isHeldInTraffic = false

        if Prefs.autoDetect && isAuthorized {
            if isBatteryLow {
                // No GPS at all. The cheap cell/Wi-Fi based signals stay on so the app still
                // wakes up now and then and can resume once the phone is charged.
                mode = .lowBattery
                statusDetail = "Paused to save battery"
            } else {
                mode = .idle
                statusDetail = hasAlwaysPermission ? "Watching for drives" : "Open the app to detect drives"
            }
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
        let startLocation = seed.first ?? manager.location

        resetActiveState()
        if !manual, Prefs.mergeTrips, let startLocation, let previous = recentTrip(near: startLocation) {
            // Picked up again right where the last drive ended: a gas stop or a long light.
            previous.isActive = true
            activeTrip = previous
            activePoints = previous.points
            activeDistance = RouteStats(activePoints).distance
            activeStartDate = previous.startDate
            lastAcceptedLocation = activePoints.last?.location
            isContinuedTrip = true
            statusDetail = "Continuing your last trip"
        } else {
            let trip = Trip(startDate: start, isManual: manual)
            context.insert(trip)
            activeTrip = trip
            activeStartDate = start
            statusDetail = manual ? "Recording manual trip" : "Drive detected"
            if !manual, Prefs.mergeTrips, let startLocation, let discard = recentDiscard,
               start.timeIntervalSince(discard.end) <= Prefs.mergeGap,
               let last = discard.points.last, last.location.distance(from: startLocation) <= Prefs.mergeRadius {
                // A short hop that was thrown away, followed by more driving: keep it after all.
                activePoints = discard.points
                activeDistance = RouteStats(discard.points).distance
                activeStartDate = discard.points.first?.timestamp ?? start
                trip.startDate = activeStartDate ?? start
                lastAcceptedLocation = last.location
            }
        }
        recentDiscard = nil
        lastMovingDate = Date()
        isManualTrip = manual
        mode = .recording
        probeDeadline = nil
        probeBuffer = []
        disarmDeparture()

        startRecordingUpdates()
        for location in seed { record(location) }
        flush(force: true)
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
                if isHeldInTraffic {
                    isHeldInTraffic = false
                    statusDetail = "Moving again"
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
    }

    private func checkForStop(now: Date = Date()) {
        guard mode == .recording, !isManualTrip, let lastMovingDate else { return }
        let stoppedFor = now.timeIntervalSince(lastMovingDate)

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
                statusDetail = "Stopped in traffic"
            }
            return
        }
        finishTrip()
    }

    private func finishTrip(reason: String? = nil) {
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
        points = TrackCleaner.clean(points)
        let stats = RouteStats(points)
        let longEnough = stats.distance >= Prefs.minTripDistance && stats.duration >= 60
        // A continued trip was already saved once: never throw it away.
        let keep = points.count >= 2 && (isManualTrip || isContinuedTrip || longEnough)
        let endLocation = lastAcceptedLocation
        let wasManual = isManualTrip

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

        resetActiveState()
        applyIdleMode(near: endLocation)
    }

    private func resetActiveState() {
        activeTrip = nil
        activePoints = []
        activeDistance = 0
        activeStartDate = nil
        isManualTrip = false
        isContinuedTrip = false
        isHeldInTraffic = false
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
                finishTrip(reason: "Recording stopped because the battery is low.")
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
            beginProbe(reason: "Driving motion detected")
        }
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
        if mode == .idle { beginProbe(reason: "Left parking spot") }
    }

    // MARK: - Location events

    private func handle(_ locations: [CLLocation]) {
        for location in locations {
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

    private func nameAndAnnounce(_ trip: Trip, points: [TrackPoint], keepStartName: String?, reason: String?) {
        guard let first = points.first, let last = points.last, let context else { return }
        let places = PlaceBook.all(in: context)
        let task = UIApplication.shared.beginBackgroundTask(withName: "NameTrip")
        Task {
            if let keepStartName {
                trip.startName = keepStartName
            } else {
                trip.startName = await Self.placeName(for: first, places: places)
            }
            trip.endName = await Self.placeName(for: last, places: places)
            try? context.save()
            postSavedNotification(for: trip, reason: reason)
            UIApplication.shared.endBackgroundTask(task)
            await TripMaintenance.snap(trip, context: context)
        }
    }

    private static func placeName(for point: TrackPoint, places: [SavedPlace]) async -> String? {
        if let place = PlaceBook.place(at: point.coordinate, in: places) { return place.name }
        return await PlaceNamer.name(for: point.location)
    }

    private func postSavedNotification(for trip: Trip, reason: String?) {
        let content = UNMutableNotificationContent()
        content.title = "Trip saved"
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
