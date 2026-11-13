import CoreLocation
import Foundation

/// Removes GPS errors from a track: poor-accuracy fixes, jumps, out-and-back spikes
/// and jitter while standing still. Used live while recording and again when a trip is saved.
enum TrackCleaner {
    /// Fixes worse than this are never kept.
    static let maxAccuracy: CLLocationAccuracy = 50
    /// Faster than any car (~320 km/h).
    static let maxPlausibleSpeed: CLLocationSpeed = 90
    static let minSpacing: CLLocationDistance = 8

    enum Verdict: Equatable {
        case accept
        /// Too close to the previous point to add anything.
        case tooClose
        /// Looks like a GPS error.
        case reject
    }

    /// Decides whether `location` should be added after `last` (the previously kept point).
    static func verdict(for location: CLLocation, after last: CLLocation?) -> Verdict {
        guard location.horizontalAccuracy >= 0, location.horizontalAccuracy <= maxAccuracy else { return .reject }
        guard let last else { return .accept }
        let elapsed = location.timestamp.timeIntervalSince(last.timestamp)
        guard elapsed > 0 else { return .reject } // stale or duplicate fix
        let delta = location.distance(from: last)

        // Standing still or crawling: movement within the accuracy circle is just noise.
        let isSlow = location.speed >= 0 && location.speed < 1.5
        let noiseFloor = isSlow ? max(minSpacing, min(location.horizontalAccuracy * 1.5, 30)) : minSpacing
        if delta < noiseFloor { return .tooClose }

        let implied = delta / max(elapsed, 0.5)
        if implied > maxPlausibleSpeed { return .reject }
        // A big jump much faster than the car says it is going.
        if location.speed >= 0, last.speed >= 0, delta > 120,
           implied > max(location.speed, last.speed) * 2.5 + 15 {
            return .reject
        }
        return .accept
    }

    /// Full cleanup of a finished track.
    static func clean(_ input: [TrackPoint]) -> [TrackPoint] {
        guard input.count > 2 else { return input }

        // 1. Accuracy, ordering, jumps and jitter, in one forward pass.
        var kept: [TrackPoint] = []
        kept.reserveCapacity(input.count)
        var rejectedRun = 0
        for point in input {
            let location = point.location
            switch verdict(for: location, after: kept.last?.location) {
            case .accept:
                kept.append(point)
                rejectedRun = 0
            case .tooClose:
                rejectedRun = 0
            case .reject:
                rejectedRun += 1
                // Several rejections in a row means the anchor was the bad fix, not these.
                if rejectedRun >= 3, location.horizontalAccuracy <= maxAccuracy, let anchor = kept.last,
                   location.timestamp > anchor.timestamp {
                    if kept.count == 1 { kept.removeLast() }
                    kept.append(point)
                    rejectedRun = 0
                }
            }
        }

        // 2. Spikes: a point that pokes out and comes straight back.
        for _ in 0..<3 {
            let before = kept.count
            kept = removeSpikes(kept)
            if kept.count == before { break }
        }
        return kept
    }

    private static func removeSpikes(_ points: [TrackPoint]) -> [TrackPoint] {
        guard points.count > 2 else { return points }
        var result: [TrackPoint] = [points[0]]
        var i = 1
        while i < points.count - 1 {
            let a = result[result.count - 1].location
            let b = points[i].location
            let c = points[i + 1].location
            let ab = a.distance(from: b), bc = b.distance(from: c), ac = a.distance(from: c)
            let elapsed = max(c.timestamp.timeIntervalSince(a.timestamp), 1)
            let detourSpeed = (ab + bc) / elapsed
            let reported = max(b.speed, a.speed, c.speed, 0)
            let isSpike = ab > 40 && bc > 40
                && ab + bc > ac * 3 + 30
                && detourSpeed > reported * 1.5 + 5
            if !isSpike { result.append(points[i]) }
            i += 1
        }
        result.append(points[points.count - 1])
        return result
    }
}
