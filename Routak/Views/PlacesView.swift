import MapKit
import SwiftData
import SwiftUI

/// Settings › Saved Places: Home, Work and any other named places.
struct PlacesView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \SavedPlace.createdAt) private var places: [SavedPlace]
    @State private var editing: PlaceDraft?

    private var others: [SavedPlace] { places.filter { $0.kind == .other } }

    var body: some View {
        List {
            Section {
                ForEach([SavedPlace.Kind.home, .work]) { kind in
                    if let place = places.first(where: { $0.kind == kind }) {
                        row(place)
                    } else {
                        Button {
                            editing = PlaceDraft(kind: kind)
                        } label: {
                            Label("Set \(kind.title)", systemImage: kind.systemImage)
                        }
                    }
                }
            } footer: {
                Text("Trips that start or end at a saved place are named after it, like “Home → Work”.")
            }

            Section("Other places") {
                ForEach(others) { row($0) }
                    .onDelete { offsets in
                        for index in offsets { context.delete(others[index]) }
                        try? context.save()
                    }
                Button {
                    editing = PlaceDraft(kind: .other)
                } label: {
                    Label("Add Place", systemImage: "plus")
                }
            }
        }
        .navigationTitle("Saved Places")
        .sheet(item: $editing) { draft in
            PlaceEditorView(draft: draft)
        }
    }

    private func row(_ place: SavedPlace) -> some View {
        Button {
            editing = PlaceDraft(place: place)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: place.kind.systemImage)
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Color.accentColor.gradient, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(place.name).foregroundStyle(.primary)
                    Text(place.kind == .other ? "Within \(Int(place.radius)) m" : "\(place.kind.title) · within \(Int(place.radius)) m")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .swipeActions {
            Button(role: .destructive) {
                context.delete(place)
                try? context.save()
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}

/// What the place editor is working on: an existing place or a new one.
struct PlaceDraft: Identifiable {
    let id = UUID()
    var place: SavedPlace?
    var kind: SavedPlace.Kind
    var coordinate: CLLocationCoordinate2D?

    init(kind: SavedPlace.Kind, coordinate: CLLocationCoordinate2D? = nil) {
        self.kind = kind
        self.coordinate = coordinate
    }

    init(place: SavedPlace) {
        self.place = place
        self.kind = place.kind
        self.coordinate = place.coordinate
    }
}

/// Pick a spot on the map (or search for an address) and name it.
struct PlaceEditorView: View {
    let draft: PlaceDraft
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var places: [SavedPlace]

    @State private var name = ""
    @State private var kind: SavedPlace.Kind = .other
    @State private var radius: Double = 150
    @State private var renamePastTrips = true
    @State private var center: CLLocationCoordinate2D?
    @State private var position: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var query = ""
    @State private var results: [MKMapItem] = []
    @State private var isSearching = false

    private let radiusOptions: [Double] = [75, 150, 250, 400]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    mapPicker
                        .frame(height: 260)
                        .listRowInsets(EdgeInsets())
                    searchField
                    ForEach(results, id: \.self) { item in
                        Button {
                            select(item)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name ?? "Result").foregroundStyle(.primary)
                                if let subtitle = Self.subtitle(for: item) {
                                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } footer: {
                    Text("Move the map so the pin sits on the place.")
                }

                Section {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.words)
                    Picker("Type", selection: $kind) {
                        ForEach(SavedPlace.Kind.allCases) { kind in
                            Text(kind == .other ? "Other" : kind.title).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                    Picker("Size", selection: $radius) {
                        ForEach(radiusOptions, id: \.self) { Text("\(Int($0)) m").tag($0) }
                    }
                }

                Section {
                    Toggle("Rename past trips here", isOn: $renamePastTrips)
                }
            }
            .navigationTitle(draft.place == nil ? "New Place" : "Edit Place")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(center == nil || name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear(perform: setUp)
            .onChange(of: kind) { old, new in
                if name.isEmpty || name == old.title { name = new == .other ? "" : new.title }
            }
        }
    }

    private var mapPicker: some View {
        Map(position: $position) {
            UserAnnotation()
            if let center {
                MapCircle(center: center, radius: radius)
                    .foregroundStyle(Color.accentColor.opacity(0.18))
                    .stroke(Color.accentColor, lineWidth: 1.5)
            }
        }
        .mapControls { MapUserLocationButton() }
        .onMapCameraChange(frequency: .continuous) { context in
            center = context.region.center
        }
        .overlay {
            Image(systemName: "mappin")
                .font(.title.weight(.bold))
                .foregroundStyle(.red)
                .offset(y: -14)
                .allowsHitTesting(false)
        }
    }

    private var searchField: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search address or place", text: $query)
                .submitLabel(.search)
                .onSubmit { Task { await search() } }
            if isSearching { ProgressView() }
        }
    }

    private func setUp() {
        kind = draft.kind
        if let place = draft.place {
            name = place.name
            radius = place.radius
        } else if draft.kind != .other {
            name = draft.kind.title
        }
        if let coordinate = draft.coordinate {
            center = coordinate
            position = .region(MKCoordinateRegion(center: coordinate, latitudinalMeters: 800, longitudinalMeters: 800))
        }
    }

    private func search() async {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        isSearching = true
        defer { isSearching = false }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = text
        if let center {
            request.region = MKCoordinateRegion(center: center, latitudinalMeters: 50_000, longitudinalMeters: 50_000)
        }
        let response = try? await MKLocalSearch(request: request).start()
        results = Array((response?.mapItems ?? []).prefix(5))
    }

    private func select(_ item: MKMapItem) {
        let coordinate: CLLocationCoordinate2D
        if #available(iOS 26.0, *) {
            coordinate = item.location.coordinate
        } else {
            coordinate = item.placemark.coordinate
        }
        withAnimation {
            position = .region(MKCoordinateRegion(center: coordinate, latitudinalMeters: 600, longitudinalMeters: 600))
        }
        if name.isEmpty, kind == .other { name = item.name ?? "" }
        results = []
        query = ""
    }

    private static func subtitle(for item: MKMapItem) -> String? {
        if #available(iOS 26.0, *) {
            return item.address?.shortAddress ?? item.address?.fullAddress
        } else {
            return item.placemark.title
        }
    }

    private func save() {
        guard let center else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let place: SavedPlace
        if let existing = draft.place {
            place = existing
        } else if kind != .other, let existing = places.first(where: { $0.kind == kind }) {
            place = existing // only one Home and one Work
        } else {
            place = SavedPlace(name: trimmed, kind: kind, coordinate: center, radius: radius)
            context.insert(place)
        }
        if kind != .other {
            // Another place already had this role: it becomes a plain saved place.
            for other in places where other.kind == kind && other !== place { other.kind = .other }
        }
        place.name = trimmed
        place.kind = kind
        place.coordinate = center
        place.radius = radius
        if renamePastTrips {
            PlaceBook.apply(place, in: context)
        }
        try? context.save()
        dismiss()
    }
}
