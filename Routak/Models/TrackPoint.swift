import CoreLocation

/// A single GPS fix along a route. Stored packed as raw doubles to keep trips compact.
struct TrackPoint: Hashable, Sendable {
    var latitude: Double
    var longitude: Double
    var altitude: Double
    /// Meters per second, negative when unknown.
    var speed: Double
    var accuracy: Double
    var timestamp: Date

    init(latitude: Double, longitude: Double, altitude: Double, speed: Double, accuracy: Double, timestamp: Date) {
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.speed = speed
        self.accuracy = accuracy
        self.timestamp = timestamp
    }

    init(_ location: CLLocation) {
        self.init(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            altitude: location.altitude,
            speed: location.speed,
            accuracy: location.horizontalAccuracy,
            timestamp: location.timestamp
        )
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var location: CLLocation {
        CLLocation(
            coordinate: coordinate,
            altitude: altitude,
            horizontalAccuracy: accuracy,
            verticalAccuracy: -1,
            course: -1,
            speed: speed,
            timestamp: timestamp
        )
    }

    // MARK: - Packing

    private static let fieldCount = 6

    static func encode(_ points: [TrackPoint]) -> Data {
        var values = [Double]()
        values.reserveCapacity(points.count * fieldCount)
        for p in points {
            values.append(p.latitude)
            values.append(p.longitude)
            values.append(p.altitude)
            values.append(p.speed)
            values.append(p.accuracy)
            values.append(p.timestamp.timeIntervalSinceReferenceDate)
        }
        return values.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func decode(_ data: Data) -> [TrackPoint] {
        let count = data.count / MemoryLayout<Double>.stride
        guard count >= fieldCount else { return [] }
        var values = [Double](repeating: 0, count: count)
        _ = values.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        var points = [TrackPoint]()
        points.reserveCapacity(count / fieldCount)
        var i = 0
        while i + fieldCount <= count {
            points.append(TrackPoint(
                latitude: values[i],
                longitude: values[i + 1],
                altitude: values[i + 2],
                speed: values[i + 3],
                accuracy: values[i + 4],
                timestamp: Date(timeIntervalSinceReferenceDate: values[i + 5])
            ))
            i += fieldCount
        }
        return points
    }
}

/// Summary numbers computed from a list of points.
struct RouteStats {
    var distance: CLLocationDistance = 0
    var duration: TimeInterval = 0
    var maxSpeed: CLLocationSpeed = 0

    init(_ points: [TrackPoint]) {
        guard let first = points.first, let last = points.last else { return }
        duration = last.timestamp.timeIntervalSince(first.timestamp)
        var previous: CLLocation?
        for point in points {
            let location = point.location
            if let previous { distance += location.distance(from: previous) }
            previous = location
            if point.speed > maxSpeed, point.accuracy <= 30 { maxSpeed = point.speed }
        }
    }
}
