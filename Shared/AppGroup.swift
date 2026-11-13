import SwiftUI
import UIKit

/// Shared between the app and the widget extension.
enum AppGroup {
    private static let defaultID = "group.cc.tomy.Routak"

    /// AltStore re-signs the app with an App Group registered on the user's own Apple ID
    /// and lists it under `ALTAppGroups` in Info.plist. Use that one when present.
    static let id: String = {
        if let groups = Bundle.main.object(forInfoDictionaryKey: "ALTAppGroups") as? [String],
           let group = groups.first(where: { $0.hasPrefix(defaultID) }) ?? groups.first {
            return group
        }
        return defaultID
    }()
    static var defaults: UserDefaults { UserDefaults(suiteName: id) ?? .standard }
}

extension Color {
    /// The app's accent color, spelled out so the widget extension (which has no asset catalog) matches.
    static let routakAccent = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.294, green: 0.557, blue: 1.0, alpha: 1)
            : UIColor(red: 0.157, green: 0.420, blue: 0.965, alpha: 1)
    })
}

/// Number formatting that needs no app-specific strings, so it works the same in the widget.
enum SharedFormat {
    static func distance(_ meters: Double, miles: Bool, digits: Int? = nil) -> String {
        let value = miles ? meters / 1_609.344 : meters / 1_000
        let fraction = digits ?? (value < 100 ? 1 : 0)
        let measurement = Measurement(value: value, unit: miles ? UnitLength.miles : UnitLength.kilometers)
        return measurement.formatted(.measurement(width: .abbreviated, usage: .asProvided,
                                                  numberFormatStyle: .number.precision(.fractionLength(fraction))))
    }

    /// Just the number, for tight spaces (the unit is shown separately).
    static func distanceNumber(_ meters: Double, miles: Bool) -> String {
        let value = miles ? meters / 1_609.344 : meters / 1_000
        return value.formatted(.number.precision(.fractionLength(value < 100 ? 1 : 0)))
    }

    static func unit(miles: Bool) -> String { miles ? "mi" : "km" }

    static func duration(_ seconds: TimeInterval) -> String {
        let rounded = max(60, (seconds / 60).rounded() * 60)
        return Duration.seconds(rounded).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
    }
}
