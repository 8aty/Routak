import SwiftData
import SwiftUI

struct HistoryView: View {
    @Query(filter: #Predicate<Trip> { $0.isActive == false }, sort: \Trip.startDate, order: .reverse)
    private var trips: [Trip]
    @Query(sort: \SavedPlace.createdAt) private var places: [SavedPlace]
    @Environment(\.modelContext) private var context
    @AppStorage(Prefs.useMilesKey) private var useMiles = false
    @AppStorage(Prefs.minTripDistanceKey) private var minTripDistance = Prefs.defaultMinTripDistance
    @State private var path: [Trip] = []

    // Search and filters
    @State private var searchText = ""
    @State private var dateFilter: DateFilter = .all
    @State private var customRange = DateRangeDraft()
    @State private var showCustomRange = false
    /// "" = any, "none" = unlabeled, otherwise a `TripLabel.key`.
    @State private var categoryFilter = ""
    @State private var placeFilter: UUID?

    enum DateFilter: String, CaseIterable, Identifiable {
        case all, week, month, last30, year, custom
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: String(localized: "Any time")
            case .week: String(localized: "This week")
            case .month: String(localized: "This month")
            case .last30: String(localized: "Last 30 days")
            case .year: String(localized: "This year")
            case .custom: String(localized: "Custom range…")
            }
        }
    }

    struct DateRangeDraft: Equatable {
        var start = Calendar.current.date(byAdding: .month, value: -1, to: .now) ?? .now
        var end = Date.now
    }

    private var isFiltering: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty || dateFilter != .all
            || !categoryFilter.isEmpty || placeFilter != nil
    }

    private var filteredTrips: [Trip] {
        guard isFiltering else { return trips }
        let interval = dateInterval
        let place = placeFilter.flatMap { id in places.first { $0.id == id } }
        let tokens = searchText.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        return trips.filter { trip in
            if let interval, !interval.contains(trip.startDate) { return false }
            switch categoryFilter {
            case "": break
            case "none": if trip.label != nil { return false }
            default: if trip.categoryRaw != categoryFilter { return false }
            }
            if let place {
                let atStart = trip.startCoordinate.map(place.contains) ?? false
                let atEnd = trip.endCoordinate.map(place.contains) ?? false
                if !atStart && !atEnd { return false }
            }
            if !tokens.isEmpty {
                let haystack = Self.searchText(for: trip)
                return tokens.allSatisfy { haystack.contains($0) }
            }
            return true
        }
    }

    private static func searchText(for trip: Trip) -> String {
        [
            trip.title, trip.startName ?? "", trip.endName ?? "", trip.notes,
            trip.label?.title ?? "",
            trip.startDate.formatted(.dateTime.weekday(.wide).month(.wide).day().year()),
        ].joined(separator: " ").lowercased()
    }

    private var dateInterval: DateInterval? {
        let calendar = Calendar.current
        switch dateFilter {
        case .all: return nil
        case .week: return calendar.dateInterval(of: .weekOfYear, for: .now)
        case .month: return calendar.dateInterval(of: .month, for: .now)
        case .year: return calendar.dateInterval(of: .year, for: .now)
        case .last30:
            let start = calendar.date(byAdding: .day, value: -30, to: calendar.startOfDay(for: .now)) ?? .now
            return DateInterval(start: start, end: .distantFuture)
        case .custom:
            let start = calendar.startOfDay(for: min(customRange.start, customRange.end))
            let endDay = calendar.startOfDay(for: max(customRange.start, customRange.end))
            let end = calendar.date(byAdding: .day, value: 1, to: endDay) ?? endDay
            return DateInterval(start: start, end: end)
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if trips.isEmpty {
                    ContentUnavailableView {
                        Label("No trips yet", systemImage: "car.rear.road.lane")
                    } description: {
                        Text("Drives longer than \(Format.distance(minTripDistance, miles: useMiles)) are saved here automatically. You can also start a trip from the Drive tab.")
                    }
                } else {
                    list
                }
            }
            .navigationTitle("History")
            .searchable(text: $searchText, prompt: "Places, notes, dates")
            .toolbar {
                if !trips.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) { filterMenu }
                }
            }
            .navigationDestination(for: Trip.self) { trip in
                TripDetailView(trip: trip)
            }
            .sheet(isPresented: $showCustomRange) { customRangeSheet }
            #if DEBUG
            .onAppear {
                // `-openLatestTrip YES` launch argument jumps straight to the newest trip.
                if UserDefaults.standard.bool(forKey: "openLatestTrip"), path.isEmpty, let first = trips.first {
                    path = [first]
                }
                // `-openTrip "Phar Lap"` opens the newest trip whose title contains the text.
                if let match = UserDefaults.standard.string(forKey: "openTrip"), path.isEmpty,
                   let trip = trips.first(where: { $0.title.localizedCaseInsensitiveContains(match) }) {
                    path = [trip]
                }
            }
            #endif
        }
    }

    private var list: some View {
        let visible = filteredTrips
        return List {
            summary(for: visible)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 8, trailing: 16))

            if isFiltering {
                activeFilters
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 4, trailing: 16))
            }

            if visible.isEmpty {
                ContentUnavailableView {
                    Label("No matching trips", systemImage: "magnifyingglass")
                } description: {
                    Text("Try a different search or clear the filters.")
                } actions: {
                    Button("Clear Filters") { clearFilters() }
                }
                .listRowSeparator(.hidden)
            }

            ForEach(sections(of: visible), id: \.day) { section in
                Section {
                    ForEach(section.trips) { trip in
                        TripCard(trip: trip)
                            .background {
                                NavigationLink(value: trip) { EmptyView() }.opacity(0)
                            }
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    delete(trip)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            .contextMenu {
                                Menu {
                                    ForEach(LabelBook.shared.labels) { label in
                                        let chosen = trip.categoryRaw == label.key
                                        Button {
                                            trip.label = chosen ? nil : label
                                            try? context.save()
                                        } label: {
                                            Label(label.title, systemImage: chosen ? "checkmark" : label.symbol)
                                        }
                                    }
                                } label: {
                                    Label("Label as", systemImage: "tag")
                                }
                                Button(role: .destructive) {
                                    delete(trip)
                                } label: {
                                    Label("Delete Trip", systemImage: "trash")
                                }
                            }
                    }
                } header: {
                    Text(Format.dayTitle(section.day))
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.primary)
                        .textCase(nil)
                }
            }
        }
        .listStyle(.plain)
    }

    private func sections(of trips: [Trip]) -> [(day: Date, trips: [Trip])] {
        let grouped = Dictionary(grouping: trips) { Calendar.current.startOfDay(for: $0.startDate) }
        return grouped.keys.sorted(by: >).map { ($0, grouped[$0] ?? []) }
    }

    private func summary(for visible: [Trip]) -> some View {
        let shown: [Trip]
        let title: LocalizedStringKey
        if isFiltering {
            shown = visible
            title = "Matching trips"
        } else {
            let monthStart = Calendar.current.dateInterval(of: .month, for: .now)?.start ?? .now
            shown = trips.filter { $0.startDate >= monthStart }
            title = "Trips this month"
        }
        let distance = Format.distanceParts(shown.reduce(0) { $0 + $1.distance }, miles: useMiles)
        let time = shown.reduce(0) { $0 + $1.duration }
        return HStack {
            StatView(title: title, value: "\(shown.count)")
            Spacer()
            StatView(title: "Distance", value: distance.value, unit: distance.unit)
            Spacer()
            StatView(title: "Driving", value: Format.duration(time))
        }
        .padding(16)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    // MARK: Filters

    private var filterMenu: some View {
        Menu {
            Picker("Date", selection: Binding(
                get: { dateFilter },
                set: { value in
                    dateFilter = value
                    if value == .custom { showCustomRange = true }
                }
            )) {
                ForEach(DateFilter.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.menu)

            Picker("Label", selection: $categoryFilter) {
                Text("Any label").tag("")
                ForEach(LabelBook.shared.labels) { Label($0.title, systemImage: $0.symbol).tag($0.key) }
                Text("Not labeled").tag("none")
            }
            .pickerStyle(.menu)

            if !places.isEmpty {
                Picker("Place", selection: $placeFilter) {
                    Text("Any place").tag(UUID?.none)
                    ForEach(places) { Label($0.name, systemImage: $0.kind.systemImage).tag(Optional($0.id)) }
                }
                .pickerStyle(.menu)
            }

            if isFiltering {
                Divider()
                Button("Clear Filters", systemImage: "xmark.circle", role: .destructive) { clearFilters() }
            }
        } label: {
            Image(systemName: hasMenuFilters ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
        .accessibilityLabel("Filter trips")
    }

    private var hasMenuFilters: Bool { dateFilter != .all || !categoryFilter.isEmpty || placeFilter != nil }

    private var activeFilters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if dateFilter != .all {
                    chip(dateFilter == .custom ? customRangeTitle : dateFilter.title) { dateFilter = .all }
                }
                if !categoryFilter.isEmpty {
                    chip(LabelBook.shared.label(for: categoryFilter)?.title ?? String(localized: "Not labeled")) { categoryFilter = "" }
                }
                if let placeFilter, let place = places.first(where: { $0.id == placeFilter }) {
                    chip(place.name) { self.placeFilter = nil }
                }
            }
        }
    }

    private var customRangeTitle: String {
        let start = min(customRange.start, customRange.end), end = max(customRange.start, customRange.end)
        return "\(start.formatted(.dateTime.month(.abbreviated).day())) – \(end.formatted(.dateTime.month(.abbreviated).day()))"
    }

    private func chip(_ title: String, remove: @escaping () -> Void) -> some View {
        Button(action: { withAnimation { remove() } }) {
            HStack(spacing: 4) {
                Text(title)
                Image(systemName: "xmark").font(.caption2.weight(.bold))
            }
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.accentColor.opacity(0.15), in: Capsule())
            .foregroundStyle(Color.accentColor)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Remove filter \(title)")
    }

    private var customRangeSheet: some View {
        NavigationStack {
            Form {
                DatePicker("From", selection: $customRange.start, in: ...Date.now, displayedComponents: .date)
                DatePicker("To", selection: $customRange.end, in: ...Date.now, displayedComponents: .date)
            }
            .navigationTitle("Date Range")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showCustomRange = false }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func clearFilters() {
        withAnimation {
            searchText = ""
            dateFilter = .all
            categoryFilter = ""
            placeFilter = nil
        }
    }

    private func delete(_ trip: Trip) {
        withAnimation {
            context.delete(trip)
            try? context.save()
        }
    }
}

/// A large card with a map snapshot of the route and the trip's key numbers.
struct TripCard: View {
    let trip: Trip
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(Prefs.useMilesKey) private var useMiles = false
    @AppStorage(Prefs.fuelEconomyKey) private var fuelEconomy = 8.0
    @AppStorage(Prefs.fuelPriceKey) private var fuelPrice = 0.0
    @State private var image: UIImage?
    @State private var width: CGFloat = 0

    private let mapHeight: CGFloat = 240

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                Rectangle().fill(.fill.tertiary)
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .transition(.opacity)
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if let label = trip.label {
                    LabelBadge(label: label)
                        .padding(10)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: mapHeight)
            .clipped()
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .task(id: "\(trip.snapshotKey)-\(Int(width))-\(colorScheme == .dark)") {
                await loadSnapshot()
            }

            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(trip.title)
                        .font(.headline)
                        .lineLimit(1)
                    Text(Format.timeRange(trip.startDate, trip.endDate))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if !trip.notes.isEmpty {
                        Text(trip.notes)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                // Fuel cost joins the row once a fuel price is set; on narrow screens average speed makes room.
                let cost = Costs.fuelCost(for: trip.distance, economy: fuelEconomy, price: fuelPrice)
                ViewThatFits(in: .horizontal) {
                    metrics(cost: cost, showSpeed: true, spacing: 18)
                    metrics(cost: cost, showSpeed: true, spacing: 12)
                    metrics(cost: cost, showSpeed: false, spacing: 14)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.separator.opacity(0.5), lineWidth: 0.5)
        }
    }

    private func metrics(cost: Double?, showSpeed: Bool, spacing: CGFloat) -> some View {
        HStack(spacing: spacing) {
            MetricLabel(systemImage: "road.lanes", text: Format.distance(trip.distance, miles: useMiles))
            MetricLabel(systemImage: "clock", text: Format.duration(trip.duration))
            if showSpeed {
                MetricLabel(systemImage: "speedometer", text: Format.speed(trip.averageSpeed, miles: useMiles))
            }
            if let cost {
                MetricLabel(systemImage: "fuelpump", text: Costs.money(cost))
            }
        }
        .lineLimit(1)
        .fixedSize()
    }

    private func loadSnapshot() async {
        guard width > 0 else { return }
        let size = CGSize(width: width.rounded(), height: mapHeight)
        let dark = colorScheme == .dark
        let key = RouteSnapshotter.cacheKey(trip: trip.snapshotKey, size: size, dark: dark)
        if let cached = RouteSnapshotter.cached(key) {
            image = cached
            return
        }
        let coordinates = trip.displayPoints.map(\.coordinate)
        let rendered = await RouteSnapshotter.render(
            coordinates, key: key, size: size, dark: dark, routeColor: UIColor(named: "AccentColor") ?? .systemBlue
        )
        withAnimation(.easeOut(duration: 0.25)) { image = rendered }
    }
}
