import Foundation

/// Writes a trip as a GPX file so it can be shared or opened in other apps.
enum GPXExporter {
    static func export(title: String, startDate: Date, points: [TrackPoint]) -> URL? {
        guard !points.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        var gpx = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="Routak" xmlns="http://www.topografix.com/GPX/1/1">
          <trk>
            <name>\(escape(title))</name>
            <trkseg>

        """
        for p in points {
            gpx += "      <trkpt lat=\"\(p.latitude)\" lon=\"\(p.longitude)\"><ele>\(p.altitude)</ele><time>\(iso.string(from: p.timestamp))</time></trkpt>\n"
        }
        gpx += """
            </trkseg>
          </trk>
        </gpx>

        """
        let stamp = startDate.formatted(.iso8601.year().month().day().dateSeparator(.dash).time(includingFractionalSeconds: false).timeSeparator(.omitted))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Routak-\(stamp).gpx")
        do {
            try gpx.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
