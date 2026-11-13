import UIKit

/// A mileage log for expenses or taxes: one line per trip with distance and the amount at a set rate.
struct MileageLog {
    struct Entry: Identifiable {
        let id = UUID()
        let start: Date
        let end: Date
        let from: String
        let to: String
        let purpose: String
        let meters: Double
    }

    var entries: [Entry]
    var periodLabel: String
    var useMiles: Bool
    /// Stored per km, like `Prefs.mileageRate`.
    var ratePerKm: Double

    @MainActor
    static func entry(for trip: Trip) -> Entry {
        let purpose = [trip.category?.title, trip.notes.isEmpty ? nil : trip.notes]
            .compactMap { $0 }
            .joined(separator: ": ")
        return Entry(
            start: trip.startDate, end: trip.endDate,
            from: trip.startName ?? "", to: trip.endName ?? "",
            purpose: purpose, meters: trip.distance
        )
    }

    var totalMeters: Double { entries.reduce(0) { $0 + $1.meters } }
    var totalAmount: Double { Costs.reimbursement(for: totalMeters, ratePerKm: ratePerKm) }
    var unit: String { Costs.distanceUnit(miles: useMiles) }
    var displayRate: Double { Costs.displayRate(ratePerKm, miles: useMiles) }

    func distance(_ meters: Double) -> Double {
        meters / (useMiles ? Costs.metersPerMile : 1_000)
    }

    func amount(_ meters: Double) -> Double {
        Costs.reimbursement(for: meters, ratePerKm: ratePerKm)
    }

    private var fileName: String { "Mileage Log \(periodLabel)" }

    // MARK: CSV

    func csv() throws -> URL {
        let url = try TripExporter.exportFile(named: fileName, ext: "csv")
        let writer = try TextFileWriter(url: url)
        let currency = Costs.currencyCode
        writer.write(TripExporter.csvRow([
            "Date", "Start time", "End time", "From", "To", "Purpose",
            "Distance (\(unit))", "Rate (\(currency)/\(unit))", "Amount (\(currency))",
        ]))
        let day = TripExporter.fixedFormatter("yyyy-MM-dd")
        let time = TripExporter.fixedFormatter("HH:mm")
        for e in entries {
            writer.write(TripExporter.csvRow([
                day.string(from: e.start), time.string(from: e.start), time.string(from: e.end),
                e.from, e.to, e.purpose,
                TripExporter.number(distance(e.meters), digits: 2),
                TripExporter.number(displayRate, digits: 3),
                TripExporter.number(amount(e.meters), digits: 2),
            ]))
        }
        writer.write(TripExporter.csvRow([
            "Total", "", "", "", "", "\(entries.count) trips",
            TripExporter.number(distance(totalMeters), digits: 2), "",
            TripExporter.number(totalAmount, digits: 2),
        ]))
        try writer.close()
        return url
    }

    // MARK: PDF

    private enum Layout {
        static let page = CGRect(x: 0, y: 0, width: 612, height: 792) // US Letter
        static let margin: CGFloat = 40
        static let rowHeight: CGFloat = 30
        static let headerHeight: CGFloat = 22
        /// Date, From, To, Purpose, Distance, Amount.
        static let columns: [CGFloat] = [78, 116, 116, 98, 58, 66]
    }

    func pdf() throws -> URL {
        let url = try TripExporter.exportFile(named: fileName, ext: "pdf")
        let bounds = Layout.page
        let renderer = UIGraphicsPDFRenderer(bounds: bounds, format: {
            let format = UIGraphicsPDFRendererFormat()
            format.documentInfo = [
                kCGPDFContextTitle as String: fileName,
                kCGPDFContextCreator as String: "Routak",
            ]
            return format
        }())

        let firstPageTop: CGFloat = 200
        let otherPageTop: CGFloat = Layout.margin + Layout.headerHeight
        let bottom = bounds.height - Layout.margin - 24
        let firstPageRows = Int((bottom - firstPageTop - Layout.headerHeight) / Layout.rowHeight)
        let otherPageRows = Int((bottom - otherPageTop) / Layout.rowHeight)
        // +1 for the totals row.
        let rowCount = entries.count + 1
        let pageCount = rowCount <= firstPageRows ? 1 : 1 + Int(ceil(Double(rowCount - firstPageRows) / Double(otherPageRows)))

        try renderer.writePDF(to: url) { context in
            var index = 0
            for page in 0..<pageCount {
                context.beginPage()
                var y: CGFloat
                if page == 0 {
                    drawTitleBlock()
                    y = firstPageTop
                } else {
                    y = Layout.margin
                }
                drawHeaderRow(at: y)
                y += Layout.headerHeight
                let capacity = page == 0 ? firstPageRows : otherPageRows
                var drawn = 0
                while drawn < capacity, index <= entries.count {
                    if index == entries.count {
                        drawTotalRow(at: y)
                    } else {
                        drawRow(entries[index], at: y, shaded: index % 2 == 1)
                    }
                    y += Layout.rowHeight
                    index += 1
                    drawn += 1
                }
                drawFooter(page: page + 1, of: pageCount)
            }
        }
        return url
    }

    private func drawTitleBlock() {
        let m = Layout.margin
        let width = Layout.page.width - m * 2
        text("Mileage Log", font: .systemFont(ofSize: 24, weight: .bold)).draw(at: CGPoint(x: m, y: m))
        text(periodLabel, font: .systemFont(ofSize: 13, weight: .medium), color: .darkGray)
            .draw(at: CGPoint(x: m, y: m + 32))
        text("Generated \(Date.now.formatted(date: .long, time: .shortened)) with Routak",
             font: .systemFont(ofSize: 10), color: .gray)
            .draw(at: CGPoint(x: m, y: m + 52))

        // Summary boxes.
        let boxTop = m + 80
        let boxWidth = (width - 30) / 4
        let summary: [(String, String)] = [
            ("Trips", "\(entries.count)"),
            ("Distance", "\(Format.distance(totalMeters, miles: useMiles))"),
            ("Rate", "\(Costs.money(displayRate)) / \(unit)"),
            ("Amount", Costs.money(totalAmount)),
        ]
        for (i, item) in summary.enumerated() {
            let rect = CGRect(x: m + CGFloat(i) * (boxWidth + 10), y: boxTop, width: boxWidth, height: 56)
            let path = UIBezierPath(roundedRect: rect, cornerRadius: 8)
            UIColor(white: 0.95, alpha: 1).setFill()
            path.fill()
            text(item.0.uppercased(), font: .systemFont(ofSize: 8, weight: .semibold), color: .gray)
                .draw(at: CGPoint(x: rect.minX + 10, y: rect.minY + 10))
            text(item.1, font: .systemFont(ofSize: 15, weight: .semibold))
                .draw(in: CGRect(x: rect.minX + 10, y: rect.minY + 24, width: rect.width - 20, height: 22))
        }
    }

    private func drawHeaderRow(at y: CGFloat) {
        let titles = ["Date", "From", "To", "Purpose", "Distance", "Amount"]
        var x = Layout.margin
        for (i, title) in titles.enumerated() {
            let rightAligned = i >= 4
            text(title, font: .systemFont(ofSize: 9, weight: .semibold), color: .darkGray, alignment: rightAligned ? .right : .left)
                .draw(in: CGRect(x: x + 4, y: y + 5, width: Layout.columns[i] - 8, height: 14))
            x += Layout.columns[i]
        }
        let line = UIBezierPath()
        line.move(to: CGPoint(x: Layout.margin, y: y + Layout.headerHeight - 1))
        line.addLine(to: CGPoint(x: Layout.page.width - Layout.margin, y: y + Layout.headerHeight - 1))
        UIColor.lightGray.setStroke()
        line.lineWidth = 0.75
        line.stroke()
    }

    private func drawRow(_ e: Entry, at y: CGFloat, shaded: Bool) {
        if shaded {
            UIColor(white: 0.97, alpha: 1).setFill()
            UIRectFill(CGRect(x: Layout.margin, y: y, width: Layout.page.width - Layout.margin * 2, height: Layout.rowHeight))
        }
        let main = UIFont.systemFont(ofSize: 9)
        let small = UIFont.systemFont(ofSize: 7.5)
        var x = Layout.margin
        func cell(_ i: Int, _ top: String, _ bottom: String? = nil, right: Bool = false) {
            let width = Layout.columns[i] - 8
            let alignment: NSTextAlignment = right ? .right : .left
            text(top, font: main, alignment: alignment)
                .draw(in: CGRect(x: x + 4, y: y + (bottom == nil ? 9 : 4), width: width, height: 12))
            if let bottom {
                text(bottom, font: small, color: .gray, alignment: alignment)
                    .draw(in: CGRect(x: x + 4, y: y + 16, width: width, height: 11))
            }
            x += Layout.columns[i]
        }
        cell(0, e.start.formatted(date: .abbreviated, time: .omitted), Format.timeRange(e.start, e.end))
        cell(1, e.from.isEmpty ? "—" : e.from)
        cell(2, e.to.isEmpty ? "—" : e.to)
        cell(3, e.purpose.isEmpty ? "—" : e.purpose)
        cell(4, "\(distance(e.meters).formatted(.number.precision(.fractionLength(1)))) \(unit)", right: true)
        cell(5, Costs.money(amount(e.meters)), right: true)
    }

    private func drawTotalRow(at y: CGFloat) {
        let line = UIBezierPath()
        line.move(to: CGPoint(x: Layout.margin, y: y + 1))
        line.addLine(to: CGPoint(x: Layout.page.width - Layout.margin, y: y + 1))
        UIColor.darkGray.setStroke()
        line.lineWidth = 1
        line.stroke()
        let bold = UIFont.systemFont(ofSize: 10, weight: .bold)
        let distanceX = Layout.margin + Layout.columns[0..<4].reduce(0, +)
        text("Total · \(entries.count) trips", font: bold).draw(at: CGPoint(x: Layout.margin + 4, y: y + 9))
        text("\(distance(totalMeters).formatted(.number.precision(.fractionLength(1)))) \(unit)", font: bold, alignment: .right)
            .draw(in: CGRect(x: distanceX + 4, y: y + 9, width: Layout.columns[4] - 8, height: 14))
        text(Costs.money(totalAmount), font: bold, alignment: .right)
            .draw(in: CGRect(x: distanceX + Layout.columns[4] + 4, y: y + 9, width: Layout.columns[5] - 8, height: 14))
    }

    private func drawFooter(page: Int, of count: Int) {
        let y = Layout.page.height - Layout.margin
        text("Page \(page) of \(count)", font: .systemFont(ofSize: 8), color: .gray, alignment: .right)
            .draw(in: CGRect(x: Layout.margin, y: y - 10, width: Layout.page.width - Layout.margin * 2, height: 12))
    }

    private func text(_ string: String, font: UIFont, color: UIColor = .black, alignment: NSTextAlignment = .left) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        style.lineBreakMode = .byTruncatingTail
        return NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
    }
}
