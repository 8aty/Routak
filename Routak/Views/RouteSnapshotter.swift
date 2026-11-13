import MapKit
import UIKit

/// Renders static map images with the route drawn on top, for the history list.
/// Images are cached in memory and on disk so scrolling stays smooth.
enum RouteSnapshotter {
    private static let memory = NSCache<NSString, UIImage>()

    private static let directory: URL = {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RouteSnapshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static func cacheKey(trip: String, size: CGSize, dark: Bool) -> String {
        "\(trip)-\(Int(size.width))x\(Int(size.height))-\(dark ? "d" : "l")"
    }

    static func cached(_ key: String) -> UIImage? {
        if let image = memory.object(forKey: key as NSString) { return image }
        let file = directory.appendingPathComponent("\(key).png")
        guard let image = UIImage(contentsOfFile: file.path) else { return nil }
        memory.setObject(image, forKey: key as NSString)
        return image
    }

    static func render(
        _ coordinates: [CLLocationCoordinate2D],
        key: String,
        size: CGSize,
        dark: Bool,
        routeColor: UIColor
    ) async -> UIImage? {
        if let image = cached(key) { return image }
        guard coordinates.count >= 2, size.width > 10, size.height > 10 else { return nil }

        let options = MKMapSnapshotter.Options()
        options.mapRect = fittedRect(for: coordinates, aspect: size.width / size.height)
        options.size = size
        options.traitCollection = UITraitCollection { traits in
            traits.userInterfaceStyle = dark ? .dark : .light
            traits.displayScale = 3
        }
        options.pointOfInterestFilter = .excludingAll
        options.showsBuildings = false

        guard let snapshot = try? await MKMapSnapshotter(options: options).start() else { return nil }

        let format = UIGraphicsImageRendererFormat()
        format.scale = snapshot.image.scale
        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            snapshot.image.draw(at: .zero)

            let path = UIBezierPath()
            var lastPoint: CGPoint?
            for (index, coordinate) in coordinates.enumerated() {
                let point = snapshot.point(for: coordinate)
                if let lastPoint, index < coordinates.count - 1,
                   hypot(point.x - lastPoint.x, point.y - lastPoint.y) < 1.5 { continue }
                if lastPoint == nil { path.move(to: point) } else { path.addLine(to: point) }
                lastPoint = point
            }
            path.lineJoinStyle = .round
            path.lineCapStyle = .round

            UIColor.white.withAlphaComponent(dark ? 0.35 : 0.9).setStroke()
            path.lineWidth = 8
            path.stroke()
            routeColor.setStroke()
            path.lineWidth = 4.5
            path.stroke()

            drawDot(at: snapshot.point(for: coordinates[0]), color: .systemGreen)
            drawDot(at: snapshot.point(for: coordinates[coordinates.count - 1]), color: .systemRed)
        }

        memory.setObject(image, forKey: key as NSString)
        if let data = image.pngData() {
            try? data.write(to: directory.appendingPathComponent("\(key).png"), options: .atomic)
        }
        return image
    }

    static func clearDiskCache() {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        memory.removeAllObjects()
    }

    private static func drawDot(at point: CGPoint, color: UIColor) {
        let outer = UIBezierPath(ovalIn: CGRect(x: point.x - 8, y: point.y - 8, width: 16, height: 16))
        UIColor.white.setFill()
        outer.fill()
        let inner = UIBezierPath(ovalIn: CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10))
        color.setFill()
        inner.fill()
    }

    /// Bounding map rect of the route, padded and stretched to the image's aspect ratio.
    static func fittedRect(for coordinates: [CLLocationCoordinate2D], aspect: CGFloat) -> MKMapRect {
        var rect = MKMapRect.null
        for coordinate in coordinates {
            let point = MKMapPoint(coordinate)
            rect = rect.union(MKMapRect(x: point.x, y: point.y, width: 0, height: 0))
        }
        let minSide = MKMapPointsPerMeterAtLatitude(coordinates[0].latitude) * 600
        var width = max(rect.width, minSide) * 1.3
        var height = max(rect.height, minSide) * 1.3
        if width / height < aspect {
            width = height * aspect
        } else {
            height = width / aspect
        }
        return MKMapRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height)
    }
}
