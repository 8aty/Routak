import ActivityKit
import Foundation

/// Runs the Lock Screen / Dynamic Island Live Activity for the trip being recorded.
///
/// The elapsed time counts up on its own, so updates are only sent when the distance has
/// changed noticeably or the car stops in traffic: a few per minute at most.
@MainActor
final class LiveActivityController {
    static let shared = LiveActivityController()

    private var activity: Activity<TripActivityAttributes>?
    private var lastSent: (distance: Double, isStopped: Bool, date: Date)?
    /// A start that iOS refused (apps usually can't start one from the background); retried when the app opens.
    private var pendingStart: (startDate: Date, distance: Double)?
    /// Time already spent paused, left out of the trip timer.
    private var pausedTotal: TimeInterval = 0
    private var pausedSince: Date?

    private static let minDistanceChange: Double = 200
    private static let minInterval: TimeInterval = 30
    /// How long the "Trip saved" summary stays on the Lock Screen.
    private static let summaryDuration: TimeInterval = 5 * 60

    private init() {}

    private var isAllowed: Bool {
        Prefs.showsLiveActivity && ActivityAuthorizationInfo().areActivitiesEnabled
    }

    func tripStarted(startDate: Date, distance: Double, pausedTotal: TimeInterval = 0) {
        self.pausedTotal = pausedTotal
        pausedSince = nil
        guard isAllowed else { return }
        // Pick up an activity that survived the app being relaunched.
        if activity == nil {
            activity = Activity<TripActivityAttributes>.activities.first {
                abs($0.attributes.startDate.timeIntervalSince(startDate)) < 1 && $0.content.state.endDate == nil
            }
        }
        for other in Activity<TripActivityAttributes>.activities where other.id != activity?.id {
            Task { await other.end(nil, dismissalPolicy: .immediate) }
        }
        if activity != nil {
            send(distance: distance, isStopped: false, force: true)
            return
        }
        let attributes = TripActivityAttributes(startDate: startDate, useMiles: Prefs.useMiles)
        let state = TripActivityAttributes.ContentState(distance: distance, pausedTotal: pausedTotal)
        do {
            activity = try Activity.request(attributes: attributes, content: .init(state: state, staleDate: nil))
            lastSent = (distance, false, .now)
            pendingStart = nil
        } catch {
            pendingStart = (startDate, distance)
        }
    }

    func tripUpdated(distance: Double, isStopped: Bool) {
        if activity == nil, let pending = pendingStart {
            pendingStart = (pending.startDate, distance)
            return
        }
        send(distance: distance, isStopped: isStopped, force: false)
    }

    /// Shows "Paused" until the trip resumes. The activity goes stale when the pause limit is reached,
    /// since the trip is then saved the next time the app runs.
    func tripPaused(at date: Date, distance: Double, pausedTotal: TimeInterval) {
        self.pausedTotal = pausedTotal
        pausedSince = date
        if pendingStart != nil { pendingStart?.distance = distance }
        send(distance: distance, isStopped: false, force: true)
    }

    func tripResumed(distance: Double, pausedTotal: TimeInterval) {
        self.pausedTotal = pausedTotal
        pausedSince = nil
        send(distance: distance, isStopped: false, force: true)
    }

    /// `savedDistance` is nil when the drive was too short to keep.
    func tripEnded(savedDistance: Double?, pausedTotal: TimeInterval = 0) {
        pendingStart = nil
        lastSent = nil
        pausedSince = nil
        self.pausedTotal = 0
        guard let activity else { return }
        self.activity = nil
        Task {
            if let savedDistance {
                let state = TripActivityAttributes.ContentState(distance: savedDistance, endDate: .now, pausedTotal: pausedTotal)
                await activity.end(.init(state: state, staleDate: nil), dismissalPolicy: .after(.now + Self.summaryDuration))
            } else {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    /// Called when the app comes to the foreground: start the activity iOS refused earlier,
    /// or clear one left over from a trip that's no longer recording.
    func appBecameActive() {
        let tracker = TripTracker.shared
        if tracker.hasOpenTrip, let startDate = tracker.activeStartDate {
            if activity == nil { resume(tracker, startDate: startDate) }
        } else {
            pendingStart = nil
            for stale in Activity<TripActivityAttributes>.activities where stale.content.state.endDate == nil {
                Task { await stale.end(nil, dismissalPolicy: .immediate) }
            }
            activity = nil
        }
    }

    /// Turning the setting off removes the activity right away.
    func settingChanged() {
        let tracker = TripTracker.shared
        if Prefs.showsLiveActivity {
            if tracker.hasOpenTrip, let startDate = tracker.activeStartDate { resume(tracker, startDate: startDate) }
        } else {
            pendingStart = nil
            let all = Activity<TripActivityAttributes>.activities
            activity = nil
            for activity in all { Task { await activity.end(nil, dismissalPolicy: .immediate) } }
        }
    }

    /// Brings the activity up for the trip the tracker has open, paused or not.
    private func resume(_ tracker: TripTracker, startDate: Date) {
        tripStarted(startDate: startDate, distance: tracker.activeDistance, pausedTotal: tracker.activePausedDuration)
        if let pausedSince = tracker.pausedSince {
            tripPaused(at: pausedSince, distance: tracker.activeDistance, pausedTotal: tracker.activePausedDuration)
        }
    }

    private func send(distance: Double, isStopped: Bool, force: Bool) {
        guard let activity else { return }
        if !force, let lastSent {
            let stateChanged = lastSent.isStopped != isStopped
            let movedEnough = abs(distance - lastSent.distance) >= Self.minDistanceChange
            let waitedEnough = Date.now.timeIntervalSince(lastSent.date) >= Self.minInterval
            guard stateChanged || (movedEnough && waitedEnough) else { return }
        }
        lastSent = (distance, isStopped, .now)
        let state = TripActivityAttributes.ContentState(
            distance: distance, isStopped: isStopped, pausedSince: pausedSince, pausedTotal: pausedTotal
        )
        let stale = pausedSince.map { $0.addingTimeInterval(Prefs.maxPause) }
        Task { await activity.update(.init(state: state, staleDate: stale)) }
    }
}
