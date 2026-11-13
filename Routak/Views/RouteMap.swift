import MapKit
import SwiftUI

/// An interactive map showing a full route with start and end markers,
/// optionally colored by speed and with a car for trip replay.
struct RouteMap: View {
    let overlay: RouteOverlay
    var colorBySpeed = true
    var replay: ReplayState?
    /// Where the trip was paused, shown as markers.
    var pauses: [TripPause] = []
    /// The map's control scope. The caller places `MapCompass(scope:)` itself, so the compass
    /// doesn't end up under its own buttons in the top corner.
    let scope: Namespace.ID
    @State private var position: MapCameraPosition
    @State private var cameraHeading: Double = 0

    init(overlay: RouteOverlay, colorBySpeed: Bool = true, replay: ReplayState? = nil, pauses: [TripPause] = [], scope: Namespace.ID) {
        self.scope = scope
        self.pauses = pauses
        self.overlay = overlay
        self.colorBySpeed = colorBySpeed
        self.replay = replay
        let polyline = overlay.full
        if polyline.pointCount == 0 {
            _position = State(initialValue: .automatic)
        } else {
            _position = State(initialValue: .rect(RouteSnapshotter.fittedRect(for: polyline.coordinates, aspect: 0.8)))
        }
    }

    var body: some View {
        Map(position: $position, scope: scope) {
            if overlay.full.pointCount > 1 {
                // The outline and the colored line sit on different overlay levels. MapKit doesn't keep
                // the order of overlays on one level when the content updates (every frame of a replay),
                // which drew the white outline over the colors.
                MapPolyline(overlay.full)
                    .stroke(.white.opacity(0.85), style: StrokeStyle(lineWidth: 9, lineCap: .round, lineJoin: .round))
                    .mapOverlayLevel(level: .aboveRoads)
                if colorBySpeed {
                    ForEach(overlay.speedSegments) { segment in
                        MapPolyline(segment.polyline)
                            .stroke(segment.color, style: StrokeStyle(lineWidth: 5.5, lineCap: .round, lineJoin: .round))
                            .mapOverlayLevel(level: .aboveLabels)
                    }
                } else {
                    MapPolyline(overlay.full)
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 5.5, lineCap: .round, lineJoin: .round))
                        .mapOverlayLevel(level: .aboveLabels)
                }
            }
            if let start = overlay.start {
                Annotation(String(localized: "Start"), coordinate: start, anchor: .center) {
                    RouteEndpoint(color: .green, systemImage: "car.fill")
                }
            }
            if let end = overlay.end {
                Annotation(String(localized: "End"), coordinate: end, anchor: .center) {
                    RouteEndpoint(color: .red, systemImage: "flag.checkered")
                }
            }
            ForEach(Array(pauses.enumerated()), id: \.offset) { _, pause in
                Annotation(Format.duration(pause.duration), coordinate: pause.coordinate, anchor: .center) {
                    RouteEndpoint(color: .orange, systemImage: "pause.fill")
                        .scaleEffect(0.85)
                }
            }
            if let replay {
                Annotation(String(localized: "Car"), coordinate: replay.coordinate, anchor: .center) {
                    ReplayCar(rotation: replay.heading - cameraHeading)
                }
                .annotationTitles(.hidden)
            }
        }
        .mapStyle(.standard(elevation: .realistic, pointsOfInterest: .excludingAll))
        .mapControls {
            MapScaleView()
        }
        #if DEBUG
        // `-mapHeading 45` rotates the map shortly after it appears (to check the compass).
        .task {
            let heading = UserDefaults.standard.double(forKey: "mapHeading")
            guard heading != 0, overlay.full.pointCount > 1 else { return }
            try? await Task.sleep(for: .seconds(1.5))
            let rect = RouteSnapshotter.fittedRect(for: overlay.full.coordinates, aspect: 0.8)
            let center = MKMapPoint(x: rect.midX, y: rect.midY).coordinate
            let meters = rect.size.width / MKMapPointsPerMeterAtLatitude(center.latitude)
            withAnimation { position = .camera(MapCamera(centerCoordinate: center, distance: meters * 2, heading: heading)) }
        }
        #endif
        .onMapCameraChange(frequency: .continuous) { context in
            cameraHeading = context.camera.heading
        }
    }
}

/// The moving arrow shown while replaying a trip.
private struct ReplayCar: View {
    let rotation: Double

    var body: some View {
        Image(systemName: "location.north.fill")
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(.white)
            .rotationEffect(.degrees(rotation))
            .frame(width: 34, height: 34)
            .background(Color.accentColor.gradient, in: Circle())
            .overlay(Circle().stroke(.white, lineWidth: 3))
            .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
    }
}

/// Slow-to-fast color scale under the speed-colored route.
struct SpeedLegend: View {
    let referenceSpeed: Double
    let useMiles: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text("Slow")
            Capsule()
                .fill(LinearGradient(
                    colors: (0...6).map { RouteOverlay.color(forFraction: Double($0) / 6) },
                    startPoint: .leading, endPoint: .trailing
                ))
                .frame(width: 70, height: 6)
            Text(Format.speed(referenceSpeed, miles: useMiles) + "+")
        }
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
    }
}

struct RouteEndpoint: View {
    let color: Color
    let systemImage: String

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 28, height: 28)
            .background(color.gradient, in: Circle())
            .overlay(Circle().stroke(.white, lineWidth: 2.5))
            .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
    }
}
