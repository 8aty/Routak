import AppIntents
import Foundation
import SwiftData

/// Starts recording now. Meant for Siri and for Shortcuts automations such as
/// "When CarPlay connects" or "When my car's Bluetooth connects".
struct StartTripIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Start Trip"
    static var description = IntentDescription("Starts recording a trip now. It ends by itself when you park.")
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        switch TripTracker.shared.startTripFromShortcut() {
        case .started:
            return .result(dialog: "Recording your trip.")
        case .alreadyRecording:
            return .result(dialog: "A trip is already recording.")
        case .needsLocation:
            return .result(dialog: "Open Routak and allow location access first.")
        case .batteryLow:
            return .result(dialog: "Battery too low to record.")
        }
    }
}

/// "How far did I drive this week?"
struct WeekSummaryIntent: AppIntent {
    static var title: LocalizedStringResource = "Driving This Week"
    static var description = IntentDescription("Tells you how far you've driven this week.")
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<Double> {
        let interval = Calendar.current.dateInterval(of: .weekOfYear, for: .now) ?? DateInterval(start: .now, duration: 0)
        let start = interval.start
        let trips = (try? Persistence.container.mainContext.fetch(FetchDescriptor<Trip>(
            predicate: #Predicate { $0.isActive == false && $0.startDate >= start }
        ))) ?? []
        let meters = trips.reduce(0) { $0 + $1.distance }
        let distance = Format.distance(meters, miles: Prefs.useMiles)
        let value = Prefs.useMiles ? meters / Costs.metersPerMile : meters / 1_000
        if trips.isEmpty {
            return .result(value: 0, dialog: "No trips yet this week.")
        }
        return .result(value: value, dialog: "\(distance) in \(trips.count) trips this week.")
    }
}

struct RoutakShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartTripIntent(),
            phrases: [
                "Start a trip in \(.applicationName)",
                "Start recording in \(.applicationName)",
            ],
            shortTitle: "Start Trip",
            systemImageName: "car.fill"
        )
        AppShortcut(
            intent: EndTripIntent(),
            phrases: [
                "End my trip in \(.applicationName)",
                "Stop recording in \(.applicationName)",
            ],
            shortTitle: "End Trip",
            systemImageName: "stop.circle.fill"
        )
        AppShortcut(
            intent: WeekSummaryIntent(),
            phrases: [
                "How far did I drive this week in \(.applicationName)",
                "\(.applicationName) this week",
            ],
            shortTitle: "Driving This Week",
            systemImageName: "chart.bar.fill"
        )
    }
}
