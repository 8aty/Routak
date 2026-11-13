import AppIntents
import Foundation

/// What the intents do, filled in by the app at launch. The widget extension compiles the
/// intent types too (for the End Trip button), but the system runs them in the app.
@MainActor
enum TripIntentHandlers {
    /// Returns false if no trip was being recorded.
    static var endTrip: (() -> Bool)?
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
