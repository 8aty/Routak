import MapKit
import SwiftData
import SwiftUI

/// Every route drawn on one dark map. Lines add up where they overlap,
/// so roads you drive often glow brighter.
struct HeatmapView: View {
    @Query(filter: #Predicate<Trip> { $0.isActive == false }, sort: \Trip.startDate, order: .reverse)
    private var trips: [Trip]
    @State private var range: Range = .all
    @State private var routes: HeatRoutes = HeatRoutes(lines: [], version: 0)
    @State private var isLoading = true

    enum Range: String, CaseIterable, Identifiable {
        case days30, days90, year, all
        var id: String { rawValue }
        var title: String {
            switch self {
            case .days30: "30 days"
            case .days90: "90 days"
            case .year: "Year"
            case .all: "All"
            }
        }
        var start: Date? {
            let calendar = Calendar.current
            switch self {
            case .days30: return calendar.date(byAdding: .day, value: -30, to: .now)
            case .days90: return calendar.date(byAdding: .day, value: -90, to: .now)
            case .year: return calendar.date(byAdding: .year, value: -1, to: .now)
            case .all: return nil
            }
        }
    }

    /// At most this many routes are drawn (the newest).
    private static let maxRoutes = 1_500

    var body: some View {
        HeatmapMap(routes: routes)
            .ignoresSafeArea(edges: .bottom)
            .overlay(alignment: .top) {
                VStack(spacing: 8) {
                    Picker("Range", selection: $range) {
                        ForEach(Range.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .padding(4)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                    Group {
                        if isLoading {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Drawing routes…")
                            }
                        } else {
                            Text(routes.lines.count == 1 ? "1 trip" : "\(routes.lines.count) trips")
                        }
                    }
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
            .navigationTitle("Where You Drive")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .task(id: range) { await load() }
    }

    private func load() async {
        isLoading = true
        let start = range.start
        let snapped = Prefs.snapToRoads
        let data: [Data] = trips
            .filter { start == nil || $0.startDate >= start! }
            .prefix(Self.maxRoutes)
            .map { trip in
                if snapped, let snappedData = trip.snappedData, snappedData.count > 0 { return snappedData }
                return trip.pointsData
            }
        let version = routes.version + 1
        let lines = await Task.detached(priority: .userInitiated) {
            data.compactMap { Self.simplified(TrackPoint.decode($0)) }
        }.value
        guard !Task.isCancelled else { return }
        routes = HeatRoutes(lines: lines, version: version)
        isLoading = false
    }

    /// Drops points closer than ~25 m to the last kept one. Plenty for a zoomed-out map, and much lighter.
    nonisolated private static func simplified(_ points: [TrackPoint]) -> [CLLocationCoordinate2D]? {
        guard points.count > 1 else { return nil }
        var result: [CLLocationCoordinate2D] = [points[0].coordinate]
        var last = MKMapPoint(points[0].coordinate)
        for point in points.dropFirst().dropLast() {
            let mapPoint = MKMapPoint(point.coordinate)
            if mapPoint.distance(to: last) >= 25 {
                result.append(point.coordinate)
                last = mapPoint
            }
        }
        result.append(points[points.count - 1].coordinate)
        return result
    }
}

struct HeatRoutes {
    let lines: [[CLLocationCoordinate2D]]
    /// Changes whenever `lines` does, so the map knows to redraw.
    let version: Int
}

private struct HeatmapMap: UIViewRepresentable {
    let routes: HeatRoutes

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.overrideUserInterfaceStyle = .dark
        let configuration = MKStandardMapConfiguration(emphasisStyle: .muted)
        configuration.pointOfInterestFilter = .excludingAll
        map.preferredConfiguration = configuration
        map.showsUserLocation = false
        map.isPitchEnabled = false
        map.showsCompass = true
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        guard context.coordinator.version != routes.version else { return }
        let isFirst = context.coordinator.version == 0
        context.coordinator.version = routes.version
        map.removeOverlays(map.overlays)
        let polylines = routes.lines.map { line -> MKPolyline in
            var coordinates = line
            return MKPolyline(coordinates: &coordinates, count: coordinates.count)
        }
        map.addOverlays(polylines, level: .aboveRoads)
        if let rect = Self.focusRect(routes.lines) {
            map.setVisibleMapRect(rect, edgePadding: UIEdgeInsets(top: 110, left: 30, bottom: 40, right: 30), animated: !isFirst)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Frames where most of the driving happens, ignoring the odd road trip far away.
    private static func focusRect(_ lines: [[CLLocationCoordinate2D]]) -> MKMapRect? {
        var xs: [Double] = [], ys: [Double] = []
        for line in lines {
            for coordinate in line {
                let point = MKMapPoint(coordinate)
                xs.append(point.x)
                ys.append(point.y)
            }
        }
        guard !xs.isEmpty else { return nil }
        xs.sort()
        ys.sort()
        let trim = lines.count >= 10 ? 0.02 : 0
        func value(_ sorted: [Double], _ fraction: Double) -> Double {
            sorted[min(sorted.count - 1, max(0, Int(Double(sorted.count - 1) * fraction)))]
        }
        let minX = value(xs, trim), maxX = value(xs, 1 - trim)
        let minY = value(ys, trim), maxY = value(ys, 1 - trim)
        let minSize = 3_000 * MKMapPointsPerMeterAtLatitude(MKMapPoint(x: minX, y: minY).coordinate.latitude)
        let width = max(maxX - minX, minSize), height = max(maxY - minY, minSize)
        return MKMapRect(x: (minX + maxX - width) / 2, y: (minY + maxY - height) / 2, width: width, height: height)
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var version = 0

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let polyline = overlay as? MKPolyline else { return MKOverlayRenderer(overlay: overlay) }
            let renderer = MKPolylineRenderer(polyline: polyline)
            renderer.strokeColor = UIColor(red: 1.0, green: 0.38, blue: 0.12, alpha: 0.42)
            renderer.lineWidth = 2.5
            renderer.lineCap = .round
            renderer.lineJoin = .round
            // Overlapping routes add up toward yellow and white.
            renderer.blendMode = .plusLighter
            return renderer
        }
    }
}
