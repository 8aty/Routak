import CoreLocation
import SwiftData
import SwiftUI

/// Rename a trip's start and end, label it and add notes.
/// Renamed places can be remembered as saved places so future trips get the name too.
struct TripEditView: View {
    let trip: Trip
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \SavedPlace.createdAt) private var places: [SavedPlace]

    @State private var startName = ""
    @State private var endName = ""
    @State private var category: TripCategory?
    @State private var notes = ""
    @State private var rememberStart: SavedPlace.Kind?
    @State private var rememberEnd: SavedPlace.Kind?

    var body: some View {
        NavigationStack {
            Form {
                placeSection(
                    title: "Start", name: $startName, remember: $rememberStart,
                    coordinate: trip.startCoordinate, color: .green
                )
                placeSection(
                    title: "End", name: $endName, remember: $rememberEnd,
                    coordinate: trip.endCoordinate, color: .red
                )

                Section("Label") {
                    Picker("Trip type", selection: $category) {
                        Text(String(localized: "category.none", defaultValue: "None", comment: "Trip type picker: no label")).tag(TripCategory?.none)
                        ForEach(TripCategory.allCases) { category in
                            Label(category.title, systemImage: category.systemImage).tag(Optional(category))
                        }
                    }
                }

                Section("Notes") {
                    TextField("e.g. Client visit, parking paid", text: $notes, axis: .vertical)
                        .lineLimit(3...8)
                }
            }
            .navigationTitle("Edit Trip")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                }
            }
            .onAppear {
                startName = trip.startName ?? ""
                endName = trip.endName ?? ""
                category = trip.category
                notes = trip.notes
            }
            .onChange(of: rememberStart) { _, kind in
                if let kind, kind != .other { startName = kind.title }
            }
            .onChange(of: rememberEnd) { _, kind in
                if let kind, kind != .other { endName = kind.title }
            }
        }
    }

    @ViewBuilder
    private func placeSection(
        title: LocalizedStringKey, name: Binding<String>, remember: Binding<SavedPlace.Kind?>,
        coordinate: CLLocationCoordinate2D?, color: Color
    ) -> some View {
        let existing = coordinate.flatMap { PlaceBook.place(at: $0, in: places) }
        Section {
            HStack(spacing: 10) {
                Circle().fill(color).frame(width: 10, height: 10)
                TextField(title, text: name)
                    .textInputAutocapitalization(.words)
            }
            if coordinate != nil, existing == nil {
                Picker("Remember as", selection: remember) {
                    Text("Don't save").tag(SavedPlace.Kind?.none)
                    ForEach(SavedPlace.Kind.allCases) { kind in
                        Label(kind == .other ? String(localized: "Saved place") : kind.title, systemImage: kind.systemImage)
                            .tag(Optional(kind))
                    }
                }
            }
        } header: {
            Text(title)
        } footer: {
            if let existing {
                Text("This is your saved place “\(existing.name)”. Edit it in Settings › Saved Places to rename it everywhere.")
            } else if let kind = remember.wrappedValue {
                // Matches `remember(kind:name:at:)`: an empty name falls back to the kind's name.
                let placeName = name.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
                Text("Future trips starting or ending here will be called “\(placeName.isEmpty ? kind.title : placeName)”, and past trips here are renamed too.")
            }
        }
    }

    private func save() {
        let start = startName.trimmingCharacters(in: .whitespacesAndNewlines)
        let end = endName.trimmingCharacters(in: .whitespacesAndNewlines)
        trip.startName = start.isEmpty ? nil : start
        trip.endName = end.isEmpty ? nil : end
        trip.category = category
        trip.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)

        if let kind = rememberStart, let coordinate = trip.startCoordinate {
            remember(kind: kind, name: start, at: coordinate)
        }
        if let kind = rememberEnd, let coordinate = trip.endCoordinate {
            remember(kind: kind, name: end, at: coordinate)
        }
        try? context.save()
        dismiss()
    }

    private func remember(kind: SavedPlace.Kind, name: String, at coordinate: CLLocationCoordinate2D) {
        let placeName = name.isEmpty ? kind.title : name
        let place: SavedPlace
        if kind != .other, let existing = places.first(where: { $0.kind == kind }) {
            // There is only one Home and one Work: move it.
            existing.name = placeName
            existing.coordinate = coordinate
            place = existing
        } else {
            place = SavedPlace(name: placeName, kind: kind, coordinate: coordinate)
            context.insert(place)
        }
        PlaceBook.apply(place, in: context)
    }
}
