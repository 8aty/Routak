import MapKit
import SwiftUI

/// An interactive map showing a full route with start and end markers,
/// optionally colored by speed and with a car for trip replay.
struct RouteMap: View {
    let overlay: RouteOverlay
    var colorBySpeed = true
    var replay: ReplayState?
    @State private var position: MapCameraPosition
    @State private var cameraHeading: Double = 0

    init(overlay: RouteOverlay, colorBySpeed: Bool = true, replay: ReplayState? = nil) {
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
        Map(position: $position) {
            if overlay.full.pointCount > 1 {
                MapPolyline(overlay.full)
                    .stroke(.white.opacity(0.85), style: StrokeStyle(lineWidth: 9, lineCap: .round, lineJoin: .round))
                if colorBySpeed {
                    ForEach(overlay.speedSegments) { segment in
                        MapPolyline(segment.polyline)
                            .stroke(segment.color, style: StrokeStyle(lineWidth: 5.5, lineCap: .round, lineJoin: .round))
                    }
                } else {
                    MapPolyline(overlay.full)
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 5.5, lineCap: .round, lineJoin: .round))
                }
            }
            if let start = overlay.start {
                Annotation("Start", coordinate: start, anchor: .center) {
                    RouteEndpoint(color: .green, systemImage: "car.fill")
                }
            }
            if let end = overlay.end {
                Annotation("End", coordinate: end, anchor: .center) {
                    RouteEndpoint(color: .red, systemImage: "flag.checkered")
                }
            }
            if let replay {
                Annotation("Car", coordinate: replay.coordinate, anchor: .center) {
                    ReplayCar(rotation: replay.heading - cameraHeading)
                }
                .annotationTitles(.hidden)
            }
        }
        .mapStyle(.standard(elevation: .realistic, pointsOfInterest: .excludingAll))
        .mapControls {
            MapCompass()
            MapScaleView()
        }
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
