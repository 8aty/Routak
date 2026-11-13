import CoreLocation
import MapKit
import SwiftUI

/// The pieces of a route the trip map draws, computed once per trip (not on every frame of a replay).
struct RouteOverlay {
    struct Segment: Identifiable {
        let id: Int
        let polyline: MKPolyline
        let color: Color
    }

    let full: MKPolyline
    let speedSegments: [Segment]
    /// Speed (m/s) that counts as "fast", the green end of the scale.
    let referenceSpeed: CLLocationSpeed
    let start: CLLocationCoordinate2D?
    let end: CLLocationCoordinate2D?

    static let buckets = 7

    init(points: [TrackPoint]) {
        var coordinates = points.map(\.coordinate)
        full = MKPolyline(coordinates: &coordinates, count: coordinates.count)
        start = coordinates.first
        end = coordinates.count > 1 ? coordinates.last : nil

        let speeds = Self.smoothedSpeeds(points)
        let sorted = speeds.sorted()
        let p95 = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        referenceSpeed = max(p95, 8)

        var segments: [Segment] = []
        guard points.count > 1 else {
            speedSegments = []
            return
        }
        var runStart = 0
        var runBucket = Self.bucket(speeds[0], reference: referenceSpeed)
        for i in 1..<points.count {
            let bucket = Self.bucket(speeds[i], reference: referenceSpeed)
            let isLast = i == points.count - 1
            if bucket != runBucket || isLast {
                // Each run ends on the first point of the next one so the line has no gaps.
                var run = Array(coordinates[runStart...i])
                segments.append(Segment(
                    id: segments.count,
                    polyline: MKPolyline(coordinates: &run, count: run.count),
                    color: Self.color(forBucket: runBucket)
                ))
                runStart = i
                runBucket = bucket
            }
        }
        speedSegments = segments
    }

    /// Green when fast, through yellow, to red when crawling: like a traffic map.
    static func color(forFraction fraction: Double) -> Color {
        Color(hue: 0.33 * min(max(fraction, 0), 1), saturation: 0.85, brightness: 0.92)
    }

    private static func color(forBucket bucket: Int) -> Color {
        color(forFraction: Double(bucket) / Double(buckets - 1))
    }

    private static func bucket(_ speed: Double, reference: Double) -> Int {
        Int((min(max(speed / reference, 0), 1) * Double(buckets - 1)).rounded())
    }

    /// Speeds with gaps filled from neighboring points and short spikes averaged out.
    static func smoothedSpeeds(_ points: [TrackPoint]) -> [Double] {
        guard !points.isEmpty else { return [] }
        var raw = [Double](repeating: 0, count: points.count)
        for i in points.indices {
            if points[i].speed >= 0 {
                raw[i] = points[i].speed
            } else if i > 0 {
                let elapsed = points[i].timestamp.timeIntervalSince(points[i - 1].timestamp)
                raw[i] = elapsed > 0 ? points[i].location.distance(from: points[i - 1].location) / elapsed : raw[i - 1]
            }
        }
        let window = 3
        return points.indices.map { i in
            let lo = max(0, i - window), hi = min(points.count - 1, i + window)
            return raw[lo...hi].reduce(0, +) / Double(hi - lo + 1)
        }
    }
}

/// Where the car is at a given moment of a recorded trip.
struct ReplayState: Equatable {
    var coordinate: CLLocationCoordinate2D
    /// Degrees clockwise from north.
    var heading: Double
    /// Meters per second.
    var speed: Double

    static func == (a: ReplayState, b: ReplayState) -> Bool {
        a.coordinate.latitude == b.coordinate.latitude && a.coordinate.longitude == b.coordinate.longitude
            && a.heading == b.heading && a.speed == b.speed
    }

    /// Interpolates the position at `time` (absolute) along `points`, which must be sorted by time.
    static func at(_ time: Date, in points: [TrackPoint]) -> ReplayState? {
        guard let first = points.first, let last = points.last else { return nil }
        if points.count == 1 || time <= first.timestamp {
            return ReplayState(coordinate: first.coordinate, heading: bearingAhead(in: points, near: 0), speed: max(first.speed, 0))
        }
        if time >= last.timestamp {
            return ReplayState(coordinate: last.coordinate, heading: bearingAhead(in: points, near: points.count - 1), speed: 0)
        }
        // Binary search for the last point at or before `time`.
        var lo = 0, hi = points.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if points[mid].timestamp <= time { lo = mid } else { hi = mid }
        }
        let a = points[lo], b = points[hi]
        let span = b.timestamp.timeIntervalSince(a.timestamp)
        let t = span > 0 ? time.timeIntervalSince(a.timestamp) / span : 0
        let coordinate = CLLocationCoordinate2D(
            latitude: a.latitude + (b.latitude - a.latitude) * t,
            longitude: a.longitude + (b.longitude - a.longitude) * t
        )
        let speed = a.speed >= 0 && b.speed >= 0 ? a.speed + (b.speed - a.speed) * t : max(a.speed, b.speed, 0)
        return ReplayState(coordinate: coordinate, heading: bearingAhead(in: points, near: lo), speed: speed)
    }

    /// Bearing over the next stretch of road, so the arrow doesn't wobble on GPS noise.
    private static func bearingAhead(in points: [TrackPoint], near index: Int) -> Double {
        guard points.count > 1 else { return 0 }
        let from = points[max(0, min(index, points.count - 2))]
        var to = points[min(index + 1, points.count - 1)]
        var k = index + 1
        while k < points.count - 1, from.location.distance(from: to.location) < 25 {
            k += 1
            to = points[k]
        }
        return bearing(from: from.coordinate, to: to.coordinate)
    }

    static func bearing(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> Double {
        let lat1 = a.latitude * .pi / 180, lat2 = b.latitude * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        return (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }
}
