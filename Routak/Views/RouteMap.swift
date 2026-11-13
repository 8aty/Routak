import MapKit
import SwiftUI

/// An interactive map showing a full route with start and end markers.
struct RouteMap: View {
    let points: [TrackPoint]
    @State private var position: MapCameraPosition

    init(points: [TrackPoint]) {
        self.points = points
        let coordinates = points.map(\.coordinate)
        if coordinates.isEmpty {
            _position = State(initialValue: .automatic)
        } else {
            _position = State(initialValue: .rect(RouteSnapshotter.fittedRect(for: coordinates, aspect: 0.8)))
        }
    }

    var body: some View {
        let coordinates = points.map(\.coordinate)
        Map(position: $position) {
            if coordinates.count > 1 {
                MapPolyline(coordinates: coordinates)
                    .stroke(.white.opacity(0.85), style: StrokeStyle(lineWidth: 9, lineCap: .round, lineJoin: .round))
                MapPolyline(coordinates: coordinates)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 5.5, lineCap: .round, lineJoin: .round))
            }
            if let first = coordinates.first {
                Annotation("Start", coordinate: first, anchor: .center) {
                    RouteEndpoint(color: .green, systemImage: "car.fill")
                }
            }
            if let last = coordinates.last, coordinates.count > 1 {
                Annotation("End", coordinate: last, anchor: .center) {
                    RouteEndpoint(color: .red, systemImage: "flag.checkered")
                }
            }
        }
        .mapStyle(.standard(elevation: .realistic, pointsOfInterest: .excludingAll))
        .mapControls {
            MapCompass()
            MapScaleView()
        }
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
