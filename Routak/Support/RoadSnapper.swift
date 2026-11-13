import CoreLocation
import MapKit

/// Lines a recorded route up with real roads using Apple's driving directions.
///
/// The route is cut into legs between waypoints a kilometer or so apart (plus both sides of
/// every GPS gap, like a tunnel). For each leg we ask MapKit for driving directions and keep
/// the alternative that hugs the recorded points best. Legs where no route matches stay as
/// recorded, so a snapped route is never worse than the raw one.
@MainActor
enum RoadSnapper {
    enum State: Int {
        /// Not tried yet, or interrupted (throttled, offline). Retried later.
        case pending = 0
        case matched = 1
        /// Tried, but nothing matched or the trip is too short.
        case unavailable = 2
    }

    struct Throttled: Error {}

    private static let maxLegs = 45
    /// A gap this long between two fixes is filled in with directions.
    private static let gapDistance: CLLocationDistance = 250
    /// How far recorded points may sit from the matched road (95th percentile).
    private static let maxDeviation: CLLocationDistance = 45

    /// Returns the matched route, or nil if no leg could be matched.
    /// Throws `Throttled` when MapKit asks us to slow down; try again later.
    static func snap(_ points: [TrackPoint]) async throws -> [TrackPoint]? {
        guard points.count >= 2 else { return nil }
        let cumulative = cumulativeDistances(points)
        guard let total = cumulative.last, total >= 300 else { return nil }

        let legs = waypointLegs(points, cumulative: cumulative, total: total)
        var output: [TrackPoint] = []
        var matchedLegs = 0

        for (index, leg) in legs.enumerated() {
            try Task.checkCancellation()
            let raw = Array(points[leg.lowerBound...leg.upperBound])
            var legPoints = raw
            let legDistance = cumulative[leg.upperBound] - cumulative[leg.lowerBound]
            let isGap = leg.count == 2 && legDistance >= gapDistance
            if leg.count > 2 || isGap {
                if let matched = try await match(raw, isGap: isGap) {
                    legPoints = matched
                    matchedLegs += 1
                }
                if index < legs.count - 1 { try await Task.sleep(for: .milliseconds(250)) }
            }
            if !output.isEmpty { legPoints.removeFirst() }
            output.append(contentsOf: legPoints)
        }
        return matchedLegs > 0 ? output : nil
    }

    // MARK: - Legs

    private static func cumulativeDistances(_ points: [TrackPoint]) -> [CLLocationDistance] {
        var result = [CLLocationDistance](repeating: 0, count: points.count)
        for i in 1..<points.count {
            result[i] = result[i - 1] + points[i].location.distance(from: points[i - 1].location)
        }
        return result
    }

    private static func waypointLegs(_ points: [TrackPoint], cumulative: [CLLocationDistance], total: CLLocationDistance) -> [ClosedRange<Int>] {
        let spacing = min(max(total / Double(maxLegs - 10), 700), 4_000)
        var indices: [Int] = [0]
        var since = 0.0
        for i in 1..<points.count {
            let step = cumulative[i] - cumulative[i - 1]
            if step >= gapDistance {
                if indices.last != i - 1 { indices.append(i - 1) }
                indices.append(i)
                since = 0
                continue
            }
            since += step
            if since >= spacing {
                indices.append(i)
                since = 0
            }
        }
        if indices.last != points.count - 1 {
            // Fold a tiny final leg into the previous one.
            if indices.count > 1, cumulative[points.count - 1] - cumulative[indices.last!] < spacing / 3,
               indices.last! - indices[indices.count - 2] > 1 {
                indices.removeLast()
            }
            indices.append(points.count - 1)
        }
        return zip(indices, indices.dropFirst()).map { $0...$1 }
    }

    // MARK: - Matching one leg

    private static func match(_ raw: [TrackPoint], isGap: Bool) async throws -> [TrackPoint]? {
        guard let first = raw.first, let last = raw.last else { return nil }
        let request = MKDirections.Request()
        request.source = mapItem(first.coordinate)
        request.destination = mapItem(last.coordinate)
        request.transportType = .automobile
        request.requestsAlternateRoutes = true

        let response: MKDirections.Response
        do {
            response = try await MKDirections(request: request).calculate()
        } catch let error as MKError where error.code == .loadingThrottled || error.code == .serverFailure {
            throw Throttled()
        } catch {
            if (error as NSError).domain == NSURLErrorDomain { throw Throttled() } // offline: retry later
            return nil
        }

        let rawLength = zip(raw, raw.dropFirst()).reduce(0) { $0 + $1.0.location.distance(from: $1.1.location) }
        let elapsed = last.timestamp.timeIntervalSince(first.timestamp)

        var best: (coordinates: [CLLocationCoordinate2D], score: Double)?
        for route in response.routes {
            let coordinates = route.polyline.coordinates
            guard coordinates.count >= 2 else { continue }
            if isGap {
                // Nothing recorded in between: the route must be plausible for the time it took.
                guard route.distance <= rawLength * 2.2 + 400,
                      route.distance / max(elapsed, 1) <= TrackCleaner.maxPlausibleSpeed * 0.6 else { continue }
                let score = route.distance
                if best == nil || score < best!.score { best = (coordinates, score) }
            } else {
                guard route.distance <= rawLength * 1.3 + 150,
                      route.distance >= rawLength * 0.7 - 150 else { continue }
                let deviation = deviation95(of: raw, from: coordinates)
                guard deviation <= maxDeviation else { continue }
                if best == nil || deviation < best!.score { best = (coordinates, deviation) }
            }
        }
        guard let best else { return nil }
        return timed(best.coordinates, along: raw)
    }

    private static func mapItem(_ coordinate: CLLocationCoordinate2D) -> MKMapItem {
        if #available(iOS 26.0, *) {
            return MKMapItem(location: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude), address: nil)
        } else {
            return MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
        }
    }

    /// Gives each road coordinate a time, speed and altitude by matching its position
    /// (as a fraction of the leg's length) to the recorded points.
    private static func timed(_ coordinates: [CLLocationCoordinate2D], along raw: [TrackPoint]) -> [TrackPoint] {
        let rawCumulative = cumulativeDistances(raw)
        let rawTotal = max(rawCumulative.last ?? 0, 1)
        var roadCumulative = [CLLocationDistance](repeating: 0, count: coordinates.count)
        for i in 1..<coordinates.count {
            roadCumulative[i] = roadCumulative[i - 1] + MKMapPoint(coordinates[i]).distance(to: MKMapPoint(coordinates[i - 1]))
        }
        let roadTotal = max(roadCumulative.last ?? 0, 1)

        var result: [TrackPoint] = []
        result.reserveCapacity(coordinates.count)
        var j = 0
        for (i, coordinate) in coordinates.enumerated() {
            let target = roadCumulative[i] / roadTotal * rawTotal
            while j < raw.count - 2, rawCumulative[j + 1] < target { j += 1 }
            let a = raw[j], b = raw[min(j + 1, raw.count - 1)]
            let span = rawCumulative[min(j + 1, raw.count - 1)] - rawCumulative[j]
            let t = span > 0 ? min(max((target - rawCumulative[j]) / span, 0), 1) : 0
            let time = a.timestamp.addingTimeInterval(b.timestamp.timeIntervalSince(a.timestamp) * t)
            let speed = a.speed >= 0 && b.speed >= 0 ? a.speed + (b.speed - a.speed) * t : max(a.speed, b.speed)
            result.append(TrackPoint(
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                altitude: a.altitude + (b.altitude - a.altitude) * t,
                speed: speed,
                accuracy: 0,
                timestamp: time
            ))
        }
        // Timestamps must never go backwards.
        for i in 1..<result.count where result[i].timestamp < result[i - 1].timestamp {
            result[i].timestamp = result[i - 1].timestamp
        }
        return result
    }

    /// 95th-percentile distance from the recorded points to the polyline, in meters.
    private static func deviation95(of raw: [TrackPoint], from coordinates: [CLLocationCoordinate2D]) -> CLLocationDistance {
        let line = coordinates.map(MKMapPoint.init)
        var distances = raw.map { point -> Double in
            let p = MKMapPoint(point.coordinate)
            var best = Double.greatestFiniteMagnitude
            for k in 1..<line.count {
                best = min(best, distanceToSegment(p, line[k - 1], line[k]))
            }
            return best * MKMetersPerMapPointAtLatitude(point.latitude)
        }
        distances.sort()
        return distances[min(distances.count - 1, Int(Double(distances.count) * 0.95))]
    }

    private static func distanceToSegment(_ p: MKMapPoint, _ a: MKMapPoint, _ b: MKMapPoint) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = min(max(((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared, 0), 1)
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }
}

extension MKPolyline {
    var coordinates: [CLLocationCoordinate2D] {
        var result = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: pointCount)
        getCoordinates(&result, range: NSRange(location: 0, length: pointCount))
        return result
    }
}
