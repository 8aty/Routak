import CoreLocation
import Foundation
import SwiftData

/// Reads GPX files (from Routak or other apps) and saves their tracks as trips.
enum GPXImporter {
    struct Track: Sendable {
        var name = ""
        var description = ""
        var points: [TrackPoint] = []
    }

    struct Result {
        var imported = 0
        var duplicates = 0
        /// Tracks without timestamps or with too few points.
        var skipped = 0
        var failedFiles = 0
        var trips: [Trip] = []

        var summary: String {
            var parts: [String] = []
            parts.append(String(localized: "Imported \(imported) trips."))
            if duplicates > 0 { parts.append(String(localized: "\(duplicates) were already saved.", comment: "Import summary: trips that were already saved")) }
            if skipped > 0 { parts.append(String(localized: "\(skipped) tracks had no times and were skipped.")) }
            if failedFiles > 0 { parts.append(String(localized: "\(failedFiles) files couldn't be read.")) }
            return parts.joined(separator: " ")
        }
    }

    /// Parses a GPX file. Returns nil if it isn't valid XML.
    static func parse(_ data: Data) -> [Track]? {
        let delegate = ParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else { return nil }
        return delegate.tracks
    }

    /// Reads the files (security-scoped URLs from the file picker) and inserts the tracks as trips.
    @MainActor
    static func importFiles(_ urls: [URL], context: ModelContext) async -> Result {
        var result = Result()
        var tracks: [Track] = []
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else {
                result.failedFiles += 1
                continue
            }
            let parsed = await Task.detached { parse(data) }.value
            guard let parsed else {
                result.failedFiles += 1
                continue
            }
            tracks += parsed
        }

        let existing = ((try? context.fetch(FetchDescriptor<Trip>())) ?? []).map(\.startDate)
        for track in tracks {
            let points = prepared(track.points)
            guard points.count >= 2 else {
                result.skipped += 1
                continue
            }
            let start = points[0].timestamp
            if existing.contains(where: { abs($0.timeIntervalSince(start)) < 2 }) {
                result.duplicates += 1
                continue
            }
            let trip = Trip(startDate: start, isManual: false)
            trip.apply(points: points)
            trip.isActive = false
            trip.notes = [track.name, track.description].filter { !$0.isEmpty }.joined(separator: "\n")
            context.insert(trip)
            result.trips.append(trip)
            result.imported += 1
        }
        try? context.save()
        return result
    }

    /// Names imported trips one by one (address lookups are rate limited), then queues road snapping.
    @MainActor
    static func nameInBackground(_ trips: [Trip], context: ModelContext) {
        guard !trips.isEmpty else { return }
        Task {
            for trip in trips where !trip.isDeleted {
                await TripNamer.nameEndpoints(of: trip, context: context)
                try? await Task.sleep(for: .milliseconds(600))
            }
            TripMaintenance.snapPending(context: context)
        }
    }

    /// Sorts by time, drops points without times and fills in speeds where the file had none.
    private static func prepared(_ input: [TrackPoint]) -> [TrackPoint] {
        var points = input.filter { $0.timestamp != .distantPast }.sorted { $0.timestamp < $1.timestamp }
        guard points.count >= 2 else { return [] }
        for i in points.indices where points[i].speed < 0 {
            let a = points[max(i - 1, 0)], b = points[min(i + 1, points.count - 1)]
            let elapsed = b.timestamp.timeIntervalSince(a.timestamp)
            if elapsed > 0 {
                points[i].speed = a.location.distance(from: b.location) / elapsed
            }
        }
        return points
    }

    // MARK: - XML

    private final class ParserDelegate: NSObject, XMLParserDelegate {
        var tracks: [Track] = []
        private var current: Track?
        private var point: TrackPoint?
        private var text = ""
        private var path: [String] = []
        private let iso = ISO8601DateFormatter()
        private let isoFractional: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f
        }()

        func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            let name = Self.local(element)
            path.append(name)
            text = ""
            switch name {
            case "trk", "rte":
                current = Track()
            case "trkpt", "rtept":
                guard let lat = attributes["lat"].flatMap(Double.init),
                      let lon = attributes["lon"].flatMap(Double.init),
                      CLLocationCoordinate2DIsValid(CLLocationCoordinate2D(latitude: lat, longitude: lon)) else { return }
                point = TrackPoint(latitude: lat, longitude: lon, altitude: 0, speed: -1, accuracy: 5, timestamp: .distantPast)
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
            let name = Self.local(element)
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let parent = path.count >= 2 ? path[path.count - 2] : ""
            defer {
                path.removeLast()
                text = ""
            }

            if point != nil {
                switch name {
                case "ele": point?.altitude = Double(value) ?? 0
                case "time": point?.timestamp = date(value) ?? .distantPast
                case "speed": if let speed = Double(value) { point?.speed = speed }
                case "trkpt", "rtept":
                    if let point { current?.points.append(point) }
                    self.point = nil
                default: break
                }
                return
            }
            switch name {
            case "name" where parent == "trk" || parent == "rte":
                current?.name = value
            case "desc" where parent == "trk" || parent == "rte":
                current?.description = value
            case "trk", "rte":
                if let current { tracks.append(current) }
                current = nil
            default:
                break
            }
        }

        private func date(_ string: String) -> Date? {
            iso.date(from: string) ?? isoFractional.date(from: string)
        }

        /// Drops a namespace prefix like "gpxtpx:speed".
        private static func local(_ name: String) -> String {
            name.split(separator: ":").last.map(String.init) ?? name
        }
    }
}
