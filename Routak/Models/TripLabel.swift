import Foundation
import Observation
import SwiftData
import SwiftUI

/// A label the user puts on trips (Work, Gym, Kids…): a name, an icon and a color.
// Every stored property has a default value so the store can sync with CloudKit.
@Model
final class TripLabel {
    /// Stored in `Trip.categoryRaw`. The starter labels keep the values of the old fixed trip
    /// types ("commute", "work", "personal"), so trips labeled before labels existed keep them.
    var key: String = UUID().uuidString
    /// Empty for a starter label that hasn't been renamed: it then shows in the phone's language.
    var name: String = ""
    var symbol: String = "tag.fill"
    /// One of `LabelColor`.
    var colorName: String = LabelColor.blue.rawValue
    var sortOrder: Int = 0
    var createdAt: Date = Date()

    init(key: String = UUID().uuidString, name: String, symbol: String, color: LabelColor, sortOrder: Int) {
        self.key = key
        self.name = name
        self.symbol = symbol
        self.colorName = color.rawValue
        self.sortOrder = sortOrder
        self.createdAt = Date()
    }

    var title: String {
        if !name.isEmpty { return name }
        switch key {
        case "commute": return String(localized: "category.commute", defaultValue: "Commute", comment: "Trip label: driving between home and work")
        case "work": return String(localized: "category.work", defaultValue: "Work", comment: "Trip label: a business trip")
        case "personal": return String(localized: "category.personal", defaultValue: "Personal", comment: "Trip label: a private trip")
        default: return String(localized: "Label")
        }
    }

    var labelColor: LabelColor {
        get { LabelColor(rawValue: colorName) ?? .blue }
        set { colorName = newValue.rawValue }
    }

    var color: Color { labelColor.color }
    /// For text and icons on a filled background of the label's color.
    var foreground: Color { labelColor.foreground }
}

extension TripLabel: Identifiable {
    var id: String { key }
}

/// The colors a label can have.
enum LabelColor: String, CaseIterable, Identifiable {
    case red, orange, yellow, green, mint, teal, cyan, blue, indigo, purple, pink, brown, gray

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .mint: .mint
        case .teal: .teal
        case .cyan: .cyan
        case .blue: .blue
        case .indigo: .indigo
        case .purple: .purple
        case .pink: .pink
        case .brown: .brown
        case .gray: .gray
        }
    }

    /// Text and icons on a filled background of this color: dark on yellow, where white is hard to read.
    var foreground: Color { self == .yellow ? Color.black.opacity(0.78) : .white }
}

/// Icons offered for labels.
enum LabelSymbols {
    static let all: [String] = [
        "briefcase.fill", "arrow.triangle.swap", "person.fill", "house.fill", "building.2.fill", "building.columns.fill",
        "cart.fill", "bag.fill", "gift.fill", "fuelpump.fill", "bolt.car.fill", "wrench.and.screwdriver.fill",
        "graduationcap.fill", "books.vertical.fill", "cross.case.fill", "stethoscope", "heart.fill", "pawprint.fill",
        "dumbbell.fill", "figure.run", "sportscourt.fill", "fork.knife", "cup.and.saucer.fill", "music.note",
        "gamecontroller.fill", "theatermasks.fill", "camera.fill", "airplane", "suitcase.fill", "beach.umbrella.fill",
        "mountain.2.fill", "tent.fill", "tree.fill", "figure.2.and.child.holdinghands", "person.2.fill", "car.fill",
        "shippingbox.fill", "hammer.fill", "dollarsign.circle.fill", "star.fill", "flag.fill", "tag.fill",
    ]
}

/// The user's labels, in their order, for quick lookup by key anywhere in the app.
/// Kept up to date by `RootView` from a SwiftData query, which also picks up iCloud changes.
@MainActor
@Observable
final class LabelBook {
    static let shared = LabelBook()

    private(set) var labels: [TripLabel] = []
    private var byKey: [String: TripLabel] = [:]

    private init() {}

    func update(_ labels: [TripLabel]) {
        self.labels = labels
        byKey = Dictionary(labels.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Nil for an empty key, or a label that has been deleted (possibly on another device).
    func label(for key: String) -> TripLabel? {
        key.isEmpty ? nil : byKey[key]
    }

    func refresh(context: ModelContext) {
        let descriptor = FetchDescriptor<TripLabel>(sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.createdAt)])
        update((try? context.fetch(descriptor)) ?? [])
    }

    private static let seededKey = "labelsSeeded"

    /// Adds the starter labels the first time, and removes duplicates iCloud sync can create
    /// when two devices each added the same starter label.
    static func prepare(context: ModelContext) {
        let descriptor = FetchDescriptor<TripLabel>(sortBy: [SortDescriptor(\.createdAt)])
        var existing = (try? context.fetch(descriptor)) ?? []
        if existing.isEmpty, !UserDefaults.standard.bool(forKey: seededKey) {
            let starters: [(String, String, LabelColor)] = [
                ("commute", "arrow.triangle.swap", .teal),
                ("work", "briefcase.fill", .indigo),
                ("personal", "person.fill", .orange),
            ]
            for (index, starter) in starters.enumerated() {
                let label = TripLabel(key: starter.0, name: "", symbol: starter.1, color: starter.2, sortOrder: index)
                context.insert(label)
                existing.append(label)
            }
        }
        UserDefaults.standard.set(true, forKey: seededKey)

        var seen = Set<String>()
        for label in existing where !seen.insert(label.key).inserted {
            context.delete(label)
        }
        try? context.save()
        shared.refresh(context: context)
    }

    /// Deletes a label; trips that had it become unlabeled.
    static func delete(_ label: TripLabel, context: ModelContext) {
        let key = label.key
        let trips = (try? context.fetch(FetchDescriptor<Trip>(predicate: #Predicate { $0.categoryRaw == key }))) ?? []
        for trip in trips { trip.categoryRaw = "" }
        context.delete(label)
        try? context.save()
        shared.refresh(context: context)
    }

    /// Saves a new order after the user dragged labels around.
    static func reorder(_ labels: [TripLabel], context: ModelContext) {
        for (index, label) in labels.enumerated() where label.sortOrder != index {
            label.sortOrder = index
        }
        try? context.save()
        shared.refresh(context: context)
    }
}
