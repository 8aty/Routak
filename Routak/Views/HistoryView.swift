import SwiftData
import SwiftUI

struct HistoryView: View {
    @Query(filter: #Predicate<Trip> { $0.isActive == false }, sort: \Trip.startDate, order: .reverse)
    private var trips: [Trip]
    @Environment(\.modelContext) private var context
    @AppStorage(Prefs.useMilesKey) private var useMiles = false
    @AppStorage(Prefs.minTripDistanceKey) private var minTripDistance = Prefs.defaultMinTripDistance
    @State private var path: [Trip] = []

    private var sections: [(day: Date, trips: [Trip])] {
        let grouped = Dictionary(grouping: trips) { Calendar.current.startOfDay(for: $0.startDate) }
        return grouped.keys.sorted(by: >).map { ($0, grouped[$0] ?? []) }
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
            .navigationDestination(for: Trip.self) { trip in
                TripDetailView(trip: trip)
            }
            #if DEBUG
            .onAppear {
                // `-openLatestTrip YES` launch argument jumps straight to the newest trip.
                if UserDefaults.standard.bool(forKey: "openLatestTrip"), path.isEmpty, let first = trips.first {
                    path = [first]
                }
            }
            #endif
        }
    }

    private var list: some View {
        List {
            summary
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 8, trailing: 16))

            ForEach(sections, id: \.day) { section in
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

    private var summary: some View {
        let monthStart = Calendar.current.dateInterval(of: .month, for: .now)?.start ?? .now
        let monthTrips = trips.filter { $0.startDate >= monthStart }
        let distance = Format.distanceParts(monthTrips.reduce(0) { $0 + $1.distance }, miles: useMiles)
        let time = monthTrips.reduce(0) { $0 + $1.duration }
        return HStack {
            StatView(title: "Trips this month", value: "\(monthTrips.count)")
            Spacer()
            StatView(title: "Distance", value: distance.value, unit: distance.unit)
            Spacer()
            StatView(title: "Driving", value: Format.duration(time))
        }
        .padding(16)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
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
    @State private var image: UIImage?
    @State private var width: CGFloat = 0

    private let mapHeight: CGFloat = 240

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                Rectangle().fill(.fill.tertiary)
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .transition(.opacity)
                } else {
                    ProgressView()
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
                }
                HStack(spacing: 18) {
                    MetricLabel(systemImage: "road.lanes", text: Format.distance(trip.distance, miles: useMiles))
                    MetricLabel(systemImage: "clock", text: Format.duration(trip.duration))
                    MetricLabel(systemImage: "speedometer", text: Format.speed(trip.averageSpeed, miles: useMiles))
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

    private func loadSnapshot() async {
        guard width > 0 else { return }
        let size = CGSize(width: width.rounded(), height: mapHeight)
        let dark = colorScheme == .dark
        let key = RouteSnapshotter.cacheKey(trip: trip.snapshotKey, size: size, dark: dark)
        if let cached = RouteSnapshotter.cached(key) {
            image = cached
            return
        }
        let coordinates = trip.points.map(\.coordinate)
        let rendered = await RouteSnapshotter.render(
            coordinates, key: key, size: size, dark: dark, routeColor: UIColor(named: "AccentColor") ?? .systemBlue
        )
        withAnimation(.easeOut(duration: 0.25)) { image = rendered }
    }
}
