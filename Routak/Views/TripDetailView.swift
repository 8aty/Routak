import Charts
import SwiftData
import SwiftUI

struct TripDetailView: View {
    let trip: Trip
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Prefs.useMilesKey) private var useMiles = false
    @State private var points: [TrackPoint] = []
    @State private var gpxURL: URL?
    @State private var showFullMap = false
    @State private var confirmDelete = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                mapCard
                statsGrid
                timeline
                if speedSamples.count > 2 { speedChart }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .navigationTitle(trip.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
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
        .fullScreenCover(isPresented: $showFullMap) {
            ZStack(alignment: .topTrailing) {
                RouteMap(points: points)
                    .ignoresSafeArea()
                Button {
                    showFullMap = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.headline)
                        .frame(width: 44, height: 44)
                        .background(.regularMaterial, in: Circle())
                }
                .padding()
            }
        }
        .task {
            let decoded = trip.points
            points = decoded
            gpxURL = GPXExporter.export(title: trip.title, startDate: trip.startDate, points: decoded)
        }
    }

    // MARK: Sections

    private var mapCard: some View {
        ZStack(alignment: .topTrailing) {
            if points.isEmpty {
                Rectangle().fill(.fill.tertiary).overlay(ProgressView())
            } else {
                RouteMap(points: points)
            }
            Button {
                showFullMap = true
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 40, height: 40)
                    .background(.regularMaterial, in: Circle())
            }
            .padding(12)
            .disabled(points.isEmpty)
        }
        .frame(height: 480)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var statsGrid: some View {
        let distance = Format.distanceParts(trip.distance, miles: useMiles)
        let avg = Format.speedParts(trip.averageSpeed, miles: useMiles)
        let max = Format.speedParts(trip.maxSpeed, miles: useMiles)
        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            card { StatView(title: "Distance", value: distance.value, unit: distance.unit, valueFont: .title) }
            card { StatView(title: "Duration", value: Format.duration(trip.duration), valueFont: .title) }
            card { StatView(title: "Avg speed", value: avg.value, unit: avg.unit, valueFont: .title) }
            card { StatView(title: "Max speed", value: max.value, unit: max.unit, valueFont: .title) }
        }
    }

    private var timeline: some View {
        VStack(alignment: .leading, spacing: 0) {
            timelineRow(color: .green, time: trip.startDate, place: trip.startName ?? "Start", isFirst: true)
            timelineRow(color: .red, time: trip.endDate, place: trip.endName ?? "End", isFirst: false)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func timelineRow(color: Color, time: Date, place: String, isFirst: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                Circle().fill(color).frame(width: 12, height: 12).padding(.top, 4)
                if isFirst {
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

    private struct SpeedSample: Identifiable {
        let id: Int
        let time: Date
        let speed: Double
    }

    private var speedSamples: [SpeedSample] {
        let valid = points.filter { $0.speed >= 0 }
        guard !valid.isEmpty else { return [] }
        let step = max(1, valid.count / 300)
        let factor = useMiles ? 2.236936 : 3.6
        return stride(from: 0, to: valid.count, by: step).map {
            SpeedSample(id: $0, time: valid[$0].timestamp, speed: valid[$0].speed * factor)
        }
    }

    private var speedChart: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Speed")
                .font(.headline)
            Chart(speedSamples) { sample in
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
            .chartYAxisLabel(useMiles ? "mph" : "km/h")
            .frame(height: 180)
        }
        .padding(16)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}
