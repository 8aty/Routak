import MapKit
import SwiftData
import SwiftUI

/// For trips that were recorded wrong: cut off the ends, split one trip into two, or delete it.
struct TripFixView: View {
    let trip: Trip
    /// Called when the user chose to delete the trip; the presenter deletes it after the sheet closes.
    var onDelete: () -> Void

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Prefs.useMilesKey) private var useMiles = false

    @State private var points: [TrackPoint] = []
    @State private var coordinates: [CLLocationCoordinate2D] = []
    @State private var mode: Mode = .trim
    @State private var trimStart: Double = 0
    @State private var trimEnd: Double = 0
    @State private var splitAt: Double = 1
    @State private var position: MapCameraPosition = .automatic
    @State private var confirmDelete = false

    enum Mode: String, CaseIterable, Identifiable {
        case trim, split
        var id: String { rawValue }
        var title: String { self == .trim ? String(localized: "Trim") : String(localized: "Split") }
    }

    private var lastIndex: Int { max(points.count - 1, 0) }
    private var canTrim: Bool { points.count >= 3 }
    private var canSplit: Bool { points.count >= 4 }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                map
                    .frame(maxHeight: .infinity)
                controls
            }
            .navigationTitle("Fix Trip")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(mode == .trim ? "Trim" : "Split") { save() }
                        .disabled(!hasChange)
                }
            }
            .confirmationDialog("Delete this trip?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete Trip", role: .destructive) {
                    onDelete()
                    dismiss()
                }
            } message: {
                Text("The route and its details are removed for good.")
            }
            .onAppear(perform: load)
        }
    }

    private func load() {
        guard points.isEmpty else { return }
        points = trip.points
        coordinates = points.map(\.coordinate)
        trimStart = 0
        trimEnd = Double(lastIndex)
        splitAt = Double(Self.longestStop(in: points))
        if coordinates.count > 1 {
            position = .rect(RouteSnapshotter.fittedRect(for: coordinates, aspect: 1))
        }
    }

    /// The point just before the longest pause in the recording, usually where one drive ended
    /// and the next began.
    private static func longestStop(in points: [TrackPoint]) -> Int {
        guard points.count >= 4 else { return 1 }
        var best = points.count / 2, longest: TimeInterval = -1
        for i in 1...(points.count - 3) {
            let gap = points[i + 1].timestamp.timeIntervalSince(points[i].timestamp)
            if gap > longest {
                longest = gap
                best = i
            }
        }
        return best
    }

    private var hasChange: Bool {
        switch mode {
        case .trim: canTrim && (Int(trimStart) > 0 || Int(trimEnd) < lastIndex) && Int(trimEnd) > Int(trimStart)
        case .split: canSplit
        }
    }

    // MARK: Map

    private var map: some View {
        Map(position: $position) {
            if coordinates.count > 1 {
                switch mode {
                case .trim:
                    let s = Int(trimStart), e = Int(trimEnd)
                    if s > 0 { line(0...s, color: .gray.opacity(0.7)) }
                    if e < lastIndex { line(e...lastIndex, color: .gray.opacity(0.7)) }
                    if e > s { line(s...e, color: .accentColor) }
                    Annotation(String(localized: "Start"), coordinate: coordinates[s], anchor: .center) {
                        RouteEndpoint(color: .green, systemImage: "car.fill")
                    }
                    Annotation(String(localized: "End"), coordinate: coordinates[e], anchor: .center) {
                        RouteEndpoint(color: .red, systemImage: "flag.checkered")
                    }
                case .split:
                    let i = Int(splitAt)
                    line(0...i, color: .accentColor)
                    line((i + 1)...lastIndex, color: .orange)
                    Annotation(String(localized: "Split"), coordinate: coordinates[i], anchor: .center) {
                        RouteEndpoint(color: .purple, systemImage: "scissors")
                    }
                }
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        .mapControls { MapCompass() }
    }

    private func line(_ range: ClosedRange<Int>, color: Color) -> some MapContent {
        let slice = Array(coordinates[range])
        return MapPolyline(coordinates: slice)
            .stroke(color, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
    }

    // MARK: Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Action", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)

            if points.count >= 3 {
                switch mode {
                case .trim: trimControls
                case .split: splitControls
                }
            } else {
                Text("This trip has too few points to trim or split.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Button(role: .destructive) {
                confirmDelete = true
            } label: {
                Label("Delete Trip", systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .padding(16)
        .background(.bar)
    }

    private var trimControls: some View {
        let s = Int(trimStart), e = Int(trimEnd)
        let kept = RouteStats(e > s ? Array(points[s...e]) : [])
        return VStack(alignment: .leading, spacing: 10) {
            sliderRow("Starts", value: $trimStart, range: 0...Double(max(lastIndex - 1, 0)), time: points[s].timestamp, color: .green)
                .onChange(of: trimStart) { _, value in
                    if value >= trimEnd { trimEnd = min(value + 1, Double(lastIndex)) }
                }
            sliderRow("Ends", value: $trimEnd, range: 1...Double(lastIndex), time: points[e].timestamp, color: .red)
                .onChange(of: trimEnd) { _, value in
                    if value <= trimStart { trimStart = max(value - 1, 0) }
                }
            Text("Keeps \(Format.distance(kept.distance, miles: useMiles)) over \(Format.duration(kept.duration)). Gray parts are removed.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var splitControls: some View {
        let i = min(Int(splitAt), max(lastIndex - 2, 1))
        let first = RouteStats(Array(points[0...i]))
        let second = RouteStats(Array(points[(i + 1)...lastIndex]))
        let pause = points[i + 1].timestamp.timeIntervalSince(points[i].timestamp)
        return VStack(alignment: .leading, spacing: 10) {
            sliderRow("Split at", value: $splitAt, range: 1...Double(max(lastIndex - 2, 1)), time: points[i].timestamp, color: .purple)
                .disabled(!canSplit)
            HStack(spacing: 12) {
                partSummary("First trip", stats: first, color: .accentColor)
                partSummary("Second trip", stats: second, color: .orange)
            }
            if pause >= 60 {
                Text("Stopped here for \(Format.duration(pause)).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func sliderRow(_ title: LocalizedStringKey, value: Binding<Double>, range: ClosedRange<Double>, time: Date, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.subheadline.weight(.semibold))
                Spacer()
                Text(time.formatted(date: .omitted, time: .standard))
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range.lowerBound...max(range.upperBound, range.lowerBound + 1), step: 1)
                .tint(color)
        }
    }

    private func partSummary(_ title: LocalizedStringKey, stats: RouteStats, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
            Text(verbatim: "\(Format.distance(stats.distance, miles: useMiles)) · \(Format.duration(stats.duration))")
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: Saving

    private func save() {
        let context = self.context
        switch mode {
        case .trim:
            let s = Int(trimStart), e = Int(trimEnd)
            guard e > s else { return }
            trip.apply(points: Array(points[s...e]))
            try? context.save()
            let trip = self.trip
            Task {
                await TripNamer.nameEndpoints(of: trip, start: s > 0, end: e < lastIndex, context: context)
                await TripMaintenance.snap(trip, context: context)
            }
        case .split:
            let i = min(Int(splitAt), max(lastIndex - 2, 1))
            let second = Array(points[(i + 1)...lastIndex])
            let newTrip = Trip(startDate: second[0].timestamp, isManual: trip.isManual)
            newTrip.apply(points: second)
            newTrip.isActive = false
            newTrip.categoryRaw = trip.categoryRaw
            newTrip.endName = trip.endName
            context.insert(newTrip)
            trip.apply(points: Array(points[0...i]))
            try? context.save()
            let trip = self.trip
            Task {
                await TripNamer.nameEndpoints(of: trip, start: false, end: true, context: context)
                await TripNamer.nameEndpoints(of: newTrip, start: true, end: false, context: context)
                await TripMaintenance.snap(trip, context: context)
                await TripMaintenance.snap(newTrip, context: context)
            }
        }
        dismiss()
    }
}
