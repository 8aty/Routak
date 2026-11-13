import AppIntents
import Foundation

/// What the intents do, filled in by the app at launch. The widget extension compiles the
/// intent types too (for the End Trip button), but the system runs them in the app.
@MainActor
enum TripIntentHandlers {
    /// Returns false if no trip was being recorded.
    static var endTrip: (() -> Bool)?
    /// Return false if there was nothing to pause or resume.
    static var pauseTrip: (() -> Bool)?
    static var resumeTrip: (() -> Bool)?
}

/// Ends the trip being recorded. Used by the Live Activity button, Siri and Shortcuts.
struct EndTripIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "End Trip"
    static var description = IntentDescription("Ends and saves the trip being recorded.")
    static var openAppWhenRun = false

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let ended = TripIntentHandlers.endTrip?() ?? false
        return .result(dialog: ended ? "Trip saved." : "No trip is being recorded.")
    }
}

/// Pauses the trip being recorded, for a gas stop or a break. It resumes when you drive off.
struct PauseTripIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Pause Trip"
    static var description = IntentDescription("Pauses the trip being recorded. It resumes by itself when you drive off.")
    static var openAppWhenRun = false

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let paused = TripIntentHandlers.pauseTrip?() ?? false
        return .result(dialog: paused ? "Trip paused." : "No trip is being recorded.")
    }
}

/// Resumes a paused trip.
struct ResumeTripIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Resume Trip"
    static var description = IntentDescription("Resumes the paused trip.")
    static var openAppWhenRun = false

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let resumed = TripIntentHandlers.resumeTrip?() ?? false
        return .result(dialog: resumed ? "Recording your trip." : "No trip is paused.")
    }
}
