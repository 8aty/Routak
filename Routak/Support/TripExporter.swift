import Foundation

/// A trip copied out of SwiftData so files can be written off the main thread.
struct ExportTrip: Sendable {
    let title: String
    let startName: String
    let endName: String
    let startDate: Date
    let endDate: Date
    let distance: Double
    let maxSpeed: Double
    let category: String
    let notes: String
    let pointsData: Data

    @MainActor
    init(_ trip: Trip) {
        title = trip.title
        startName = trip.startName ?? ""
        endName = trip.endName ?? ""
        startDate = trip.startDate
        endDate = trip.endDate
        distance = trip.distance
        maxSpeed = trip.maxSpeed
        category = trip.label?.title ?? ""
        notes = trip.notes
        pointsData = trip.pointsData
    }

    var duration: TimeInterval { max(0, endDate.timeIntervalSince(startDate)) }
    var averageSpeed: Double { duration > 0 ? distance / duration : 0 }
}

/// Writes many trips at once as GPX, KML or a CSV summary.
enum TripExporter {
    enum FileFormat: String, CaseIterable, Identifiable, Sendable {
        case gpx, kml, csv
        var id: String { rawValue }

        var title: String {
            switch self {
            case .gpx: "GPX"
            case .kml: "KML"
            case .csv: "CSV"
            }
        }

        var detail: String {
            switch self {
            case .gpx: String(localized: "Full routes for other GPS and fitness apps")
            case .kml: String(localized: "Routes for Google Earth and Google My Maps")
            case .csv: String(localized: "One row per trip, for spreadsheets")
            }
        }
    }

    struct Options: Sendable {
        var useMiles: Bool
        var fuelEconomy: Double
        var fuelPrice: Double
        var label: String
    }

    static func export(_ trips: [ExportTrip], format: FileFormat, options: Options) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            let url = try exportFile(named: "Routak \(options.label)", ext: format.rawValue)
            let writer = try TextFileWriter(url: url)
            switch format {
            case .gpx: try writeGPX(trips, to: writer)
            case .kml: try writeKML(trips, useMiles: options.useMiles, to: writer)
            case .csv: try writeCSV(trips, options: options, to: writer)
            }
            try writer.close()
            return url
        }.value
    }

    /// A fresh file URL in a temporary "Exports" folder.
    static func exportFile(named name: String, ext: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Exports", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let safe = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: ".")
        let url = folder.appendingPathComponent(safe).appendingPathExtension(ext)
        try? FileManager.default.removeItem(at: url)
        return url
    }

    // MARK: GPX

    private static func writeGPX(_ trips: [ExportTrip], to w: TextFileWriter) throws {
        let iso = ISO8601DateFormatter()
        w.write("""
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="Routak" xmlns="http://www.topografix.com/GPX/1/1">
          <metadata><name>\(xml(String(localized: "Routak trips")))</name><time>\(iso.string(from: .now))</time></metadata>

        """)
        for trip in trips {
            let points = TrackPoint.decode(trip.pointsData)
            guard !points.isEmpty else { continue }
            w.write("  <trk>\n    <name>\(xml(trip.title))</name>\n")
            if !trip.notes.isEmpty { w.write("    <desc>\(xml(trip.notes))</desc>\n") }
            if !trip.category.isEmpty { w.write("    <type>\(xml(trip.category))</type>\n") }
            w.write("    <trkseg>\n")
            for p in points {
                w.write("      <trkpt lat=\"\(p.latitude)\" lon=\"\(p.longitude)\"><ele>\(round1(p.altitude))</ele><time>\(iso.string(from: p.timestamp))</time></trkpt>\n")
            }
            w.write("    </trkseg>\n  </trk>\n")
            try w.flushIfNeeded()
        }
        w.write("</gpx>\n")
    }

    // MARK: KML

    private static func writeKML(_ trips: [ExportTrip], useMiles: Bool, to w: TextFileWriter) throws {
        let iso = ISO8601DateFormatter()
        w.write("""
        <?xml version="1.0" encoding="UTF-8"?>
        <kml xmlns="http://www.opengis.net/kml/2.2">
        <Document>
          <name>\(xml(String(localized: "Routak trips")))</name>
          <Style id="route"><LineStyle><color>ffe0781e</color><width>4</width></LineStyle></Style>

        """)
        for trip in trips {
            let points = TrackPoint.decode(trip.pointsData)
            guard points.count > 1 else { continue }
            w.write("  <Placemark>\n    <name>\(xml(trip.title))</name>\n")
            var description = "\(trip.startDate.formatted(date: .abbreviated, time: .shortened)) · \(Format.distance(trip.distance, miles: useMiles)) · \(Format.duration(trip.duration))"
            if !trip.category.isEmpty { description += " · \(trip.category)" }
            if !trip.notes.isEmpty { description += "\n\(trip.notes)" }
            w.write("    <description>\(xml(description))</description>\n")
            w.write("    <TimeSpan><begin>\(iso.string(from: trip.startDate))</begin><end>\(iso.string(from: trip.endDate))</end></TimeSpan>\n")
            w.write("    <styleUrl>#route</styleUrl>\n    <LineString><tessellate>1</tessellate><coordinates>\n")
            for p in points {
                w.write("\(p.longitude),\(p.latitude),\(round1(p.altitude)) ")
            }
            w.write("\n    </coordinates></LineString>\n  </Placemark>\n")
            try w.flushIfNeeded()
        }
        w.write("</Document>\n</kml>\n")
    }

    // MARK: CSV

    private static func writeCSV(_ trips: [ExportTrip], options: Options, to w: TextFileWriter) throws {
        let unit = Costs.distanceUnit(miles: options.useMiles)
        let speedUnit = options.useMiles ? "mph" : "km/h"
        let perUnit = options.useMiles ? Costs.metersPerMile : 1_000
        let speedFactor = options.useMiles ? 2.236936 : 3.6
        let hasFuel = options.fuelPrice > 0 && options.fuelEconomy > 0
        var header = [
            String(localized: "Date"), String(localized: "Start time"), String(localized: "End time"),
            String(localized: "column.from", defaultValue: "From", comment: "Column header: start place"), String(localized: "column.to", defaultValue: "To", comment: "Column header: destination"),
            String(localized: "Type", comment: "Column header: trip label such as Work"), String(localized: "Distance (\(unit))"),
            String(localized: "Duration (min)"), String(localized: "Average speed (\(speedUnit))"),
            String(localized: "Max speed (\(speedUnit))"),
        ]
        if hasFuel { header.append(String(localized: "Fuel cost (\(Costs.currencyCode))")) }
        header.append(String(localized: "Notes"))
        w.write(csvRow(header))

        let day = TripExporter.fixedFormatter("yyyy-MM-dd")
        let time = TripExporter.fixedFormatter("HH:mm")
        for trip in trips {
            var row = [
                day.string(from: trip.startDate),
                time.string(from: trip.startDate),
                time.string(from: trip.endDate),
                trip.startName,
                trip.endName,
                trip.category,
                number(trip.distance / perUnit, digits: 2),
                number(trip.duration / 60, digits: 1),
                number(trip.averageSpeed * speedFactor, digits: 1),
                number(trip.maxSpeed * speedFactor, digits: 1),
            ]
            if hasFuel {
                let cost = Costs.fuelCost(for: trip.distance, economy: options.fuelEconomy, price: options.fuelPrice) ?? 0
                row.append(number(cost, digits: 2))
            }
            row.append(trip.notes)
            w.write(csvRow(row))
            try w.flushIfNeeded()
        }
    }

    // MARK: Helpers

    /// Dates for CSV files: the same in every language and region, so spreadsheets can read them.
    static func fixedFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter
    }

    static func csvRow(_ fields: [String]) -> String {
        fields.map { field in
            if field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) {
                return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            }
            return field
        }.joined(separator: ",") + "\r\n"
    }

    /// Plain machine-readable number (dot decimal separator), so spreadsheets in any locale can parse it.
    static func number(_ value: Double, digits: Int) -> String {
        String(format: "%.\(digits)f", value)
    }

    static func xml(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func round1(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
}

/// Appends text to a file in chunks, so exporting thousands of routes doesn't build one huge string.
final class TextFileWriter {
    private let handle: FileHandle
    private var buffer = ""

    init(url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
    }

    func write(_ text: String) {
        buffer += text
    }

    func flushIfNeeded() throws {
        if buffer.utf8.count > 512 * 1024 { try flush() }
    }

    func flush() throws {
        guard !buffer.isEmpty else { return }
        try handle.write(contentsOf: Data(buffer.utf8))
        buffer = ""
    }

    func close() throws {
        try flush()
        try handle.close()
    }
}
