import Charts
import MapKit
import SwiftData
import SwiftUI

struct TripDetailView: View {
    let trip: Trip
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Prefs.useMilesKey) private var useMiles = false
    @AppStorage("colorRouteBySpeed") private var colorBySpeed = true
    @AppStorage(Prefs.fuelEconomyKey) private var fuelEconomy = 8.0
    @AppStorage(Prefs.fuelPriceKey) private var fuelPrice = 0.0

    /// Raw GPS points (real speeds, for the chart).
    @State private var points: [TrackPoint] = []
    /// What the map draws: road-matched if available.
    @State private var displayPoints: [TrackPoint] = []
    @State private var overlay: RouteOverlay?
    @State private var pauses: [TripPause] = []
    @State private var speedSamples: [SpeedSample] = []
    @State private var gpxURL: URL?
    @State private var showFullMap = false
    @State private var confirmDelete = false
    @State private var showEditor = false
    @State private var showFix = false
    @Namespace private var cardMapScope
    @Namespace private var fullMapScope
    /// Set by the fix sheet; the trip is deleted once that sheet has closed.
    @State private var deleteAfterFix = false

    // Replay
    /// Seconds since the start of the route; nil when not replaying.
    @State private var replayOffset: TimeInterval?
    @State private var isPlaying = false
    @State private var playbackRate: Double = 60

    private var routeStart: Date { displayPoints.first?.timestamp ?? trip.startDate }
    /// Replay time: driving only, pauses are skipped.
    private var routeDuration: TimeInterval {
        let total = (displayPoints.last?.timestamp ?? trip.endDate).timeIntervalSince(routeStart)
        return max(total - pauses.reduce(0) { $0 + $1.duration }, 1)
    }

    /// The moment of the trip `offset` seconds of driving after the start.
    private func replayTime(_ offset: TimeInterval) -> Date {
        var time = routeStart.addingTimeInterval(offset)
        for pause in pauses where pause.start < time {
            time.addTimeInterval(pause.duration)
        }
        return time
    }

    /// The reverse of `replayTime`: a moment during a pause maps to the moment it began.
    private func replayOffset(at time: Date) -> TimeInterval {
        var offset = time.timeIntervalSince(routeStart)
        for pause in pauses where pause.start < time {
            offset -= min(time.timeIntervalSince(pause.start), pause.duration)
        }
        return min(max(offset, 0), routeDuration)
    }

    private var replayState: ReplayState? {
        guard let replayOffset else { return nil }
        return ReplayState.at(replayTime(replayOffset), in: displayPoints)
    }

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(spacing: 16) {
                mapCard
                if displayPoints.count > 1 { replayCard }
                statsGrid
                labelsCard
                    .id("labels")
                timeline
                if speedSamples.count > 2 { speedChart }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        #if DEBUG
        // `-detailScroll labels` scrolls to the trip type buttons (for screenshots).
        .task {
            guard UserDefaults.standard.string(forKey: "detailScroll") == "labels" else { return }
            try? await Task.sleep(for: .milliseconds(600))
            proxy.scrollTo("labels", anchor: .center)
        }
        #endif
        }
        .navigationTitle(trip.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Edit") { showEditor = true }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showFix = true
                    } label: {
                        Label("Trim or Split…", systemImage: "scissors")
                    }
                    if let gpxURL {
                        ShareLink(item: gpxURL) {
                            Label("Export GPX", systemImage: "square.and.arrow.up")
                        }
                    }
                    Button(role: .destructive) {
                        confirmDelete = true
                    } label: {
                        Label("Delete Trip", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .confirmationDialog("Delete this trip?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Trip", role: .destructive) {
                context.delete(trip)
                try? context.save()
                dismiss()
            }
        }
        .sheet(isPresented: $showEditor) {
            TripEditView(trip: trip)
        }
        .sheet(isPresented: $showFix, onDismiss: {
            guard deleteAfterFix else { return }
            context.delete(trip)
            try? context.save()
            dismiss()
        }) {
            TripFixView(trip: trip) { deleteAfterFix = true }
        }
        .fullScreenCover(isPresented: $showFullMap) {
            ZStack(alignment: .topTrailing) {
                if let overlay {
                    RouteMap(overlay: overlay, colorBySpeed: colorBySpeed, replay: replayState, pauses: pauses, scope: fullMapScope)
                        .ignoresSafeArea()
                }
                VStack(spacing: 10) {
                    Button {
                        showFullMap = false
                    } label: {
                        Image(systemName: "xmark")
                            .font(.headline)
                            .frame(width: 44, height: 44)
                            .background(.regularMaterial, in: Circle())
                    }
                    MapCompass(scope: fullMapScope)
                }
                .padding()
            }
            .mapScope(fullMapScope)
        }
        .task(id: trip.snapshotKey) { load() }
        .task(id: isPlaying) { await play() }
        .onDisappear { isPlaying = false }
        #if DEBUG
        // `-autoReplay YES` starts the replay right away (for screenshots).
        .onAppear { if UserDefaults.standard.bool(forKey: "autoReplay") { isPlaying = true } }
        #endif
    }

    private func load() {
        let raw = trip.points
        points = raw
        displayPoints = trip.displayPoints
        overlay = RouteOverlay(points: displayPoints)
        pauses = trip.pauses.filter { $0.end != nil }.sorted { $0.start < $1.start }
        speedSamples = Self.samples(from: raw, factor: useMiles ? 2.236936 : 3.6)
        gpxURL = GPXExporter.export(title: trip.title, startDate: trip.startDate, points: raw)
    }

    // MARK: Replay

    private func play() async {
        guard isPlaying else { return }
        if replayOffset == nil || replayOffset! >= routeDuration { replayOffset = 0 }
        var last = Date()
        while isPlaying, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(50))
            let now = Date()
            let next = (replayOffset ?? 0) + now.timeIntervalSince(last) * playbackRate
            last = now
            if next >= routeDuration {
                replayOffset = routeDuration
                isPlaying = false
            } else {
                replayOffset = next
            }
        }
    }

    private var replayCard: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Button {
                    if replayOffset == nil {
                        // Pick a speed so a full replay takes about 30 seconds.
                        playbackRate = Self.rates.min { abs(routeDuration / $0 - 30) < abs(routeDuration / $1 - 30) } ?? 60
                    }
                    isPlaying.toggle()
                } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .frame(width: 44, height: 44)
                        .background(Color.accentColor.opacity(0.15), in: Circle())
                        .contentTransition(.symbolEffect(.replace))
                }
                .accessibilityLabel(isPlaying ? "Pause replay" : "Replay trip")

                if let replayOffset {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(replayTime(replayOffset).formatted(date: .omitted, time: .standard))
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                        Text(Format.speed(replayState?.speed ?? 0, miles: useMiles))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Replay trip").font(.subheadline.weight(.semibold))
                        Text("Watch the drive play back on the map").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Menu {
                    Picker("Speed", selection: $playbackRate) {
                        ForEach(Self.rates, id: \.self) { Text(verbatim: "\(Int($0))×").tag($0) }
                    }
                } label: {
                    Text(verbatim: "\(Int(playbackRate))×")
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.fill.tertiary, in: Capsule())
                }
                if replayOffset != nil {
                    Button {
                        isPlaying = false
                        replayOffset = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Stop replay")
                }
            }
            if replayOffset != nil {
                Slider(
                    value: Binding(
                        get: { replayOffset ?? 0 },
                        set: { replayOffset = $0 }
                    ),
                    in: 0...routeDuration,
                    onEditingChanged: { editing in if editing { isPlaying = false } }
                )
            }
        }
        .padding(14)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .animation(.snappy, value: replayOffset == nil)
    }

    private static let rates: [Double] = [10, 30, 60, 120, 240, 480]

    // MARK: Sections

    private var mapCard: some View {
        ZStack(alignment: .topTrailing) {
            if let overlay {
                RouteMap(overlay: overlay, colorBySpeed: colorBySpeed, replay: replayState, pauses: pauses, scope: cardMapScope)
            } else {
                Rectangle().fill(.fill.tertiary).overlay(ProgressView())
            }
            VStack(spacing: 10) {
                mapButton("arrow.up.left.and.arrow.down.right", label: "Full screen map") { showFullMap = true }
                mapButton(colorBySpeed ? "speedometer" : "paintbrush.pointed.fill",
                          label: colorBySpeed ? "Show plain route" : "Color route by speed") {
                    colorBySpeed.toggle()
                }
                // Appears below the buttons only while the map is rotated.
                MapCompass(scope: cardMapScope)
            }
            .padding(12)
            .disabled(overlay == nil)
        }
        .mapScope(cardMapScope)
        // Top corner: the bottom one holds the Apple Maps logo and legal link.
        .overlay(alignment: .topLeading) {
            if colorBySpeed, let overlay, overlay.speedSegments.count > 1 {
                SpeedLegend(referenceSpeed: overlay.referenceSpeed, useMiles: useMiles)
                    .padding(12)
                    .allowsHitTesting(false)
            }
        }
        .frame(height: 480)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private func mapButton(_ systemImage: String, label: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.semibold))
                .frame(width: 40, height: 40)
                .background(.regularMaterial, in: Circle())
        }
        .accessibilityLabel(label)
    }

    private var statsGrid: some View {
        let distance = Format.distanceParts(trip.distance, miles: useMiles)
        let avg = Format.speedParts(trip.averageSpeed, miles: useMiles)
        let max = Format.speedParts(trip.maxSpeed, miles: useMiles)
        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            card { StatView(title: "Distance", value: distance.value, unit: distance.unit, valueFont: .title) }
            card { StatView(title: pauses.isEmpty ? "Duration" : "Driving time", value: Format.duration(trip.duration), valueFont: .title) }
            card { StatView(title: "Avg speed", value: avg.value, unit: avg.unit, valueFont: .title) }
            card { StatView(title: "Max speed", value: max.value, unit: max.unit, valueFont: .title) }
            if let fuel = Costs.fuelCost(for: trip.distance, economy: fuelEconomy, price: fuelPrice) {
                let liters = Costs.liters(for: trip.distance, economy: fuelEconomy)
                let volume = useMiles ? liters / Costs.litersPerGallon : liters
                card { StatView(title: "Cost", value: Costs.money(fuel), valueFont: .title, info: Self.fuelEstimateInfo) }
                card {
                    StatView(
                        title: "Fuel used",
                        value: volume.formatted(.number.precision(.fractionLength(1))),
                        unit: Costs.volumeUnit(miles: useMiles),
                        valueFont: .title,
                        info: Self.fuelEstimateInfo
                    )
                }
            }
        }
    }

    /// The trip's label and notes.
    private var labelsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Label").font(.subheadline.weight(.semibold))
                Spacer()
                if trip.label == nil {
                    Text(String(localized: "category.none", defaultValue: "None", comment: "Trip type picker: no label"))
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            LabelPicker(selectedKey: trip.categoryRaw) { label in
                trip.label = label
                try? context.save()
            }
            Divider()
            Button {
                showEditor = true
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "note.text").foregroundStyle(.secondary)
                    Text(trip.notes.isEmpty ? String(localized: "Add a note") : trip.notes)
                        .foregroundStyle(trip.notes.isEmpty ? .secondary : .primary)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.subheadline)
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var timeline: some View {
        Button {
            showEditor = true
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 0) {
                    timelineRow(color: .green, time: trip.startDate, place: trip.startName ?? String(localized: "Start"), isLast: false)
                    ForEach(Array(pauses.enumerated()), id: \.offset) { _, pause in
                        timelineRow(
                            color: .orange,
                            time: pause.start,
                            place: String(localized: "Paused \(Format.duration(pause.duration))", comment: "Timeline row for a pause, e.g. Paused 14 min"),
                            isLast: false
                        )
                    }
                    timelineRow(color: .red, time: trip.endDate, place: trip.endName ?? String(localized: "End"), isLast: true)
                }
                Spacer()
                Image(systemName: "pencil")
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityHint("Rename the start and end places")
    }

    private func timelineRow(color: Color, time: Date, place: String, isLast: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                Circle().fill(color).frame(width: 12, height: 12).padding(.top, 4)
                if !isLast {
                    Rectangle().fill(.secondary.opacity(0.4)).frame(width: 2, height: 30)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(place).font(.body.weight(.semibold))
                Text(time.formatted(date: .abbreviated, time: .shortened))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Speed chart

    struct SpeedSample: Identifiable {
        let id: Int
        let time: Date
        let speed: Double
    }

    private static func samples(from points: [TrackPoint], factor: Double) -> [SpeedSample] {
        let valid = points.filter { $0.speed >= 0 }
        guard !valid.isEmpty else { return [] }
        let step = max(1, valid.count / 300)
        return stride(from: 0, to: valid.count, by: step).map {
            SpeedSample(id: $0, time: valid[$0].timestamp, speed: valid[$0].speed * factor)
        }
    }

    /// The chart sample closest to `time` (samples are sorted by time).
    private func speedSample(near time: Date) -> SpeedSample? {
        guard !speedSamples.isEmpty else { return nil }
        var lo = 0, hi = speedSamples.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if speedSamples[mid].time <= time { lo = mid } else { hi = mid }
        }
        let a = speedSamples[lo], b = speedSamples[hi]
        return abs(a.time.timeIntervalSince(time)) <= abs(b.time.timeIntervalSince(time)) ? a : b
    }

    private var speedChart: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Speed").font(.headline)
                Spacer()
                if let replayOffset {
                    // The speed where the finger (or the replay) is, right above the chart.
                    let time = replayTime(replayOffset)
                    let speed = speedSample(near: time)?.speed ?? (replayState?.speed ?? 0) * (useMiles ? 2.236936 : 3.6)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(verbatim: "\(Int(speed.rounded())) \(useMiles ? "mph" : "km/h")")
                            .font(.title3.weight(.bold))
                            .contentTransition(.numericText(value: speed))
                        Text(time.formatted(date: .omitted, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .monospacedDigit()
                } else {
                    Text("Touch to scrub").font(.caption).foregroundStyle(.secondary)
                }
            }
            Chart {
                ForEach(speedSamples) { sample in
                    AreaMark(x: .value("Time", sample.time), y: .value("Speed", sample.speed))
                        .foregroundStyle(.linearGradient(
                            colors: [Color.accentColor.opacity(0.35), Color.accentColor.opacity(0.02)],
                            startPoint: .top, endPoint: .bottom
                        ))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Time", sample.time), y: .value("Speed", sample.speed))
                        .foregroundStyle(Color.accentColor)
                        .interpolationMethod(.monotone)
                }
                if let replayOffset {
                    let time = replayTime(replayOffset)
                    RuleMark(x: .value("Now", time))
                        .foregroundStyle(.secondary.opacity(0.6))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    // On the drawn line, so the dot and the number above match what the chart shows.
                    if let sample = speedSample(near: time) {
                        PointMark(x: .value("Now", sample.time), y: .value("Speed", sample.speed))
                            .foregroundStyle(Color.accentColor)
                            .symbolSize(80)
                    }
                }
            }
            .chartYAxisLabel(useMiles ? "mph" : "km/h")
            .chartXSelection(value: Binding<Date?>(
                get: { replayOffset.map { replayTime($0) } },
                set: { date in
                    // Ends of a selection gesture report nil; keep the car where it is.
                    guard let date else { return }
                    isPlaying = false
                    replayOffset = replayOffset(at: date)
                }
            ))
            .frame(height: 180)
        }
        .padding(16)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private static let fuelEstimateInfo: LocalizedStringKey = "An estimate from the trip's distance and the fuel price and average consumption in Settings › Fuel & Mileage. Real use depends on traffic, speed, hills, weather, load and the car's condition, and on what you actually paid at the pump."

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}
