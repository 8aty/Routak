import Charts
import SwiftData
import SwiftUI

/// Totals and charts for a week, month, year or all time, plus links to the heatmap,
/// commute times and the mileage log.
struct StatsView: View {
    @Query(filter: #Predicate<Trip> { $0.isActive == false }, sort: \Trip.startDate, order: .reverse)
    private var allTrips: [Trip]
    @Query(sort: \SavedPlace.createdAt) private var places: [SavedPlace]
    @AppStorage(Prefs.useMilesKey) private var useMiles = false
    @AppStorage(Prefs.fuelEconomyKey) private var fuelEconomy = 8.0
    @AppStorage(Prefs.fuelPriceKey) private var fuelPrice = 0.0
    @State private var period: Period = .month
    /// 0 = the current week/month/year, -1 the one before, and so on.
    @State private var offset = 0
    @State private var showMileageLog = false

    enum Period: String, CaseIterable, Identifiable {
        case week, month, year, all
        var id: String { rawValue }
        var title: String {
            switch self {
            case .week: String(localized: "Week")
            case .month: String(localized: "Month")
            case .year: String(localized: "Year")
            case .all: String(localized: "All", comment: "Stats period: all time")
            }
        }
        var component: Calendar.Component? {
            switch self {
            case .week: .weekOfYear
            case .month: .month
            case .year: .year
            case .all: nil
            }
        }
    }

    // MARK: Period math

    private func interval(offset: Int) -> DateInterval? {
        guard let component = period.component else { return nil }
        let calendar = Calendar.current
        guard let anchor = calendar.date(byAdding: component, value: offset, to: .now) else { return nil }
        return calendar.dateInterval(of: component, for: anchor)
    }

    private func trips(in interval: DateInterval?) -> [Trip] {
        guard let interval else { return allTrips }
        return allTrips.filter { $0.startDate >= interval.start && $0.startDate < interval.end }
    }

    private var periodTitle: String {
        guard let interval = interval(offset: offset) else { return String(localized: "All time") }
        switch period {
        case .week:
            if offset == 0 { return String(localized: "This week") }
            if offset == -1 { return String(localized: "Last week") }
            let end = interval.end.addingTimeInterval(-1)
            return "\(interval.start.formatted(.dateTime.month(.abbreviated).day())) – \(end.formatted(.dateTime.month(.abbreviated).day()))"
        case .month:
            return interval.start.formatted(.dateTime.month(.wide).year()).capitalizedFirst
        case .year:
            return interval.start.formatted(.dateTime.year())
        case .all:
            return String(localized: "All time")
        }
    }

    /// Caption under the change in distance.
    private var comparisonTitle: LocalizedStringKey {
        switch period {
        case .week: "vs the week before"
        case .month: "vs the month before"
        case .year, .all: "vs the year before"
        }
    }

    // MARK: Body

    var body: some View {
        NavigationStack {
            Group {
                if allTrips.isEmpty {
                    ContentUnavailableView {
                        Label("No stats yet", systemImage: "chart.bar.xaxis")
                    } description: {
                        Text("Totals, charts and commute times appear here after your first saved drive.")
                    }
                } else {
                    content
                }
            }
            .navigationTitle("Stats")
            .navigationDestination(for: Trip.self) { TripDetailView(trip: $0) }
            .toolbar {
                if !allTrips.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showMileageLog = true
                        } label: {
                            Label("Mileage Log", systemImage: "doc.text")
                        }
                    }
                }
            }
            .sheet(isPresented: $showMileageLog) { MileageLogView() }
        }
    }

    private var content: some View {
        let current = interval(offset: offset)
        let shown = trips(in: current)
        let previous = period == .all ? nil : trips(in: interval(offset: offset - 1))
        return ScrollViewReader { proxy in
        ScrollView {
            VStack(spacing: 16) {
                Picker("Period", selection: $period) {
                    ForEach(Period.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: period) { offset = 0 }

                periodNavigator
                totals(shown, previous: previous)
                if !shown.isEmpty {
                    distanceChart(shown, interval: current)
                    highlights(shown)
                }
                linksCard(shown)
                if !shown.isEmpty {
                    categoryCard(shown)
                    destinationsCard(shown)
                    DrivingTimesGrid(trips: shown)
                }
                Color.clear.frame(height: 1).id("bottom")
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
            .animation(.snappy, value: period)
            .animation(.snappy, value: offset)
        }
        #if DEBUG
        // `-statsScroll bottom` scrolls to the end (for screenshots).
        .task {
            if UserDefaults.standard.string(forKey: "statsScroll") == "bottom" {
                try? await Task.sleep(for: .milliseconds(500))
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
        #endif
        }
    }

    private var periodNavigator: some View {
        HStack {
            Button {
                offset -= 1
            } label: {
                Image(systemName: "chevron.left").frame(width: 36, height: 36)
            }
            .disabled(period == .all || !hasTrips(before: interval(offset: offset)))
            .accessibilityLabel("Previous")
            Spacer()
            Text(periodTitle)
                .font(.headline)
                .contentTransition(.numericText())
            Spacer()
            Button {
                offset += 1
            } label: {
                Image(systemName: "chevron.right").frame(width: 36, height: 36)
            }
            .disabled(period == .all || offset >= 0)
            .accessibilityLabel("Next")
        }
        .buttonStyle(.borderless)
        .opacity(period == .all ? 0.4 : 1)
    }

    private func hasTrips(before interval: DateInterval?) -> Bool {
        guard let interval, let oldest = allTrips.last else { return false }
        return oldest.startDate < interval.start
    }

    // MARK: Totals

    private func totals(_ trips: [Trip], previous: [Trip]?) -> some View {
        let distance = trips.reduce(0) { $0 + $1.distance }
        let time = trips.reduce(0) { $0 + $1.duration }
        let parts = Format.distanceParts(distance, miles: useMiles)
        let average = Format.speedParts(time > 0 ? distance / time : 0, miles: useMiles)
        let fuel = Costs.fuelCost(for: distance, economy: fuelEconomy, price: fuelPrice)
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                StatView(title: "Distance", value: parts.value, unit: parts.unit, valueFont: .largeTitle)
                Spacer()
                if let previous {
                    change(distance, versus: previous.reduce(0) { $0 + $1.distance })
                }
            }
            Divider()
            HStack {
                StatView(title: "Trips", value: "\(trips.count)")
                Spacer()
                StatView(title: "Driving", value: Format.duration(time))
                Spacer()
                StatView(title: "Avg speed", value: average.value, unit: average.unit)
            }
            if let fuel {
                Divider()
                HStack {
                    StatView(title: "Fuel (est.)", value: Costs.money(fuel))
                    Spacer()
                    let liters = Costs.liters(for: distance, economy: fuelEconomy)
                    StatView(
                        title: "Used",
                        value: (useMiles ? liters / Costs.litersPerGallon : liters).formatted(.number.precision(.fractionLength(1))),
                        unit: Costs.volumeUnit(miles: useMiles),
                        alignment: .trailing
                    )
                }
            }
        }
        .padding(16)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    @ViewBuilder
    private func change(_ value: Double, versus previous: Double) -> some View {
        if previous > 0 {
            let percent = (value - previous) / previous * 100
            let up = percent >= 0
            VStack(alignment: .trailing, spacing: 2) {
                Label(abs(percent / 100).formatted(.percent.precision(.fractionLength(0))), systemImage: up ? "arrow.up.right" : "arrow.down.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(up ? .orange : .green)
                    .monospacedDigit()
                Text(comparisonTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Chart

    private struct Bar: Identifiable {
        let date: Date
        let category: String
        let value: Double
        var id: String { "\(date.timeIntervalSinceReferenceDate)-\(category)" }
    }

    private var barUnit: Calendar.Component {
        switch period {
        case .week, .month: return .day
        case .year: return .month
        case .all:
            guard let first = allTrips.last?.startDate else { return .month }
            return Date.now.timeIntervalSince(first) > 2 * 365 * 86_400 ? .year : .month
        }
    }

    private func distanceChart(_ trips: [Trip], interval: DateInterval?) -> some View {
        let calendar = Calendar.current
        let unit = barUnit
        let perUnit = useMiles ? Costs.metersPerMile : 1_000
        var sums: [String: Bar] = [:]
        for trip in trips {
            let bucket = calendar.dateInterval(of: unit, for: trip.startDate)?.start ?? trip.startDate
            let category = trip.category?.title ?? Self.unlabeledTitle
            let key = "\(bucket.timeIntervalSinceReferenceDate)-\(category)"
            let value = (sums[key]?.value ?? 0) + trip.distance / perUnit
            sums[key] = Bar(date: bucket, category: category, value: value)
        }
        let bars = sums.values.sorted { $0.date < $1.date }
        let present = Set(bars.map(\.category))
        // Only the types that appear, in a fixed order.
        let legend = Self.categoryScale.filter { present.contains($0.title) }

        return VStack(alignment: .leading, spacing: 10) {
            Text(unit == .day ? "Distance by day" : unit == .month ? "Distance by month" : "Distance by year")
                .font(.headline)
            Chart(bars) { bar in
                BarMark(
                    x: .value("Date", bar.date, unit: unit),
                    y: .value(Costs.distanceUnit(miles: useMiles), bar.value)
                )
                .foregroundStyle(by: .value("Type", bar.category))
                .cornerRadius(3)
            }
            .chartForegroundStyleScale(domain: legend.map(\.title), range: legend.map(\.color))
            .chartXScale(domain: chartDomain(interval: interval, unit: unit, bars: bars))
            .chartXAxis {
                switch unit {
                case .day where period == .week:
                    AxisMarks(values: .stride(by: .day)) { _ in
                        AxisValueLabel(format: .dateTime.weekday(.narrow), centered: true)
                    }
                case .day:
                    AxisMarks(values: .stride(by: .day, count: 7)) { _ in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.day())
                    }
                case .month:
                    AxisMarks(values: .stride(by: .month, count: period == .year ? 1 : 3)) { _ in
                        AxisValueLabel(format: period == .year ? .dateTime.month(.narrow) : .dateTime.month(.abbreviated).year(.twoDigits), centered: true)
                    }
                default:
                    AxisMarks(values: .stride(by: .year)) { _ in
                        AxisValueLabel(format: .dateTime.year(), centered: true)
                    }
                }
            }
            .chartYAxisLabel(Costs.distanceUnit(miles: useMiles))
            .chartLegend(position: .bottom, alignment: .leading)
            .frame(height: 200)
        }
        .padding(16)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func chartDomain(interval: DateInterval?, unit: Calendar.Component, bars: [Bar]) -> ClosedRange<Date> {
        if let interval { return interval.start...interval.end.addingTimeInterval(-1) }
        let calendar = Calendar.current
        let first = bars.first?.date ?? .now
        let end = calendar.dateInterval(of: unit, for: .now)?.end ?? .now
        return first...end.addingTimeInterval(-1)
    }

    static var unlabeledTitle: String { String(localized: "Unlabeled", comment: "Trips without a label such as Work") }

    /// Chart colors for each label, in a fixed order.
    static var categoryScale: [(title: String, color: Color)] {
        TripCategory.allCases.map { ($0.title, color(for: $0)) } + [(unlabeledTitle, color(for: nil))]
    }

    static func color(for category: TripCategory?) -> Color {
        switch category {
        case .commute: .teal
        case .work: .indigo
        case .personal: .orange
        case nil: Color.accentColor.opacity(0.55)
        }
    }

    // MARK: Highlights

    private func highlights(_ trips: [Trip]) -> some View {
        let longest = trips.max { $0.distance < $1.distance }
        let longestTime = trips.max { $0.duration < $1.duration }
        let fastest = trips.max { $0.maxSpeed < $1.maxSpeed }
        return VStack(alignment: .leading, spacing: 4) {
            Text("Highlights").font(.headline).padding(.bottom, 6)
            if let longest {
                highlightRow("Longest trip", systemImage: "road.lanes", value: Format.distance(longest.distance, miles: useMiles), trip: longest)
            }
            if let longestTime, longestTime.id != longest?.id || trips.count == 1 {
                highlightRow("Longest drive", systemImage: "clock", value: Format.duration(longestTime.duration), trip: longestTime)
            }
            if let fastest, fastest.maxSpeed > 0 {
                highlightRow("Top speed", systemImage: "gauge.with.dots.needle.67percent", value: Format.speed(fastest.maxSpeed, miles: useMiles), trip: fastest)
            }
        }
        .padding(16)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func highlightRow(_ title: LocalizedStringKey, systemImage: String, value: String, trip: Trip) -> some View {
        NavigationLink(value: trip) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.caption).foregroundStyle(.secondary)
                    Text(trip.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(trip.startDate.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(value).font(.subheadline.weight(.semibold)).monospacedDigit()
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Links

    private func linksCard(_ trips: [Trip]) -> some View {
        let home = places.first { $0.kind == .home }
        let work = places.first { $0.kind == .work }
        return VStack(spacing: 0) {
            NavigationLink {
                HeatmapView()
            } label: {
                linkRow(
                    "Where you drive", systemImage: "flame.fill", tint: .orange,
                    detail: String(localized: "Every route on one map")
                )
            }
            Divider().padding(.leading, 56)
            NavigationLink {
                if let home, let work {
                    CommuteView(home: home, work: work)
                } else {
                    PlacesView()
                }
            } label: {
                linkRow(
                    "Commute times", systemImage: "arrow.triangle.swap", tint: .teal,
                    detail: commuteDetail(home: home, work: work)
                )
            }
            Divider().padding(.leading, 56)
            Button {
                showMileageLog = true
            } label: {
                linkRow(
                    "Mileage log", systemImage: "doc.text.fill", tint: .indigo,
                    detail: mileageDetail(trips)
                )
            }
        }
        .buttonStyle(.plain)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func commuteDetail(home: SavedPlace?, work: SavedPlace?) -> String {
        guard let home, let work else { return String(localized: "Set Home and Work to compare commutes") }
        let toWork = CommuteAnalysis(direction: .toWork, trips: allTrips, home: home, work: work)
        let toHome = CommuteAnalysis(direction: .toHome, trips: allTrips, home: home, work: work)
        switch (toWork.isEmpty, toHome.isEmpty) {
        case (true, true):
            return String(localized: "No drives between Home and Work yet")
        case (false, false):
            return String(localized: "To work \(Format.duration(toWork.average)) · home \(Format.duration(toHome.average)) on average")
        case (false, true):
            return String(localized: "To work \(Format.duration(toWork.average)) on average")
        case (true, false):
            return String(localized: "Home \(Format.duration(toHome.average)) on average", comment: "Average drive time from work to home")
        }
    }

    private func mileageDetail(_ trips: [Trip]) -> String {
        let work = trips.filter { $0.category == .work }
        guard !work.isEmpty else { return String(localized: "Label trips as Work to log business miles") }
        let distance = work.reduce(0) { $0 + $1.distance }
        return String(localized: "\(work.count) work trips, \(Format.distance(distance, miles: useMiles))")
    }

    private func linkRow(_ title: LocalizedStringKey, systemImage: String, tint: Color, detail: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(tint.gradient, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    // MARK: Breakdown

    private func categoryCard(_ trips: [Trip]) -> some View {
        let total = max(trips.reduce(0) { $0 + $1.distance }, 1)
        let groups: [(category: TripCategory?, distance: Double, count: Int)] =
            (TripCategory.allCases.map { Optional($0) } + [nil]).compactMap { category in
                let list = trips.filter { $0.category == category }
                guard !list.isEmpty else { return nil }
                return (category, list.reduce(0) { $0 + $1.distance }, list.count)
            }
        return VStack(alignment: .leading, spacing: 12) {
            Text("By type").font(.headline)
            GeometryReader { geometry in
                HStack(spacing: 2) {
                    ForEach(groups, id: \.category) { group in
                        Rectangle()
                            .fill(Self.color(for: group.category))
                            .frame(width: max(geometry.size.width * group.distance / total - 2, 2))
                    }
                }
            }
            .frame(height: 12)
            .clipShape(Capsule())
            ForEach(groups, id: \.category) { group in
                HStack(spacing: 10) {
                    Circle().fill(Self.color(for: group.category)).frame(width: 10, height: 10)
                    Text(group.category?.title ?? Self.unlabeledTitle).font(.subheadline)
                    Text(verbatim: "\(group.count)").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(Format.distance(group.distance, miles: useMiles))
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                    Text((group.distance / total).formatted(.percent.precision(.fractionLength(0))))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 38, alignment: .trailing)
                        .monospacedDigit()
                }
            }
        }
        .padding(16)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func destinationsCard(_ trips: [Trip]) -> some View {
        var counts: [String: Int] = [:]
        for trip in trips {
            if let end = trip.endName, !end.isEmpty { counts[end, default: 0] += 1 }
        }
        let top = counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.prefix(5)
        let maxCount = max(top.first?.value ?? 1, 1)
        return Group {
            if !top.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Top destinations").font(.headline)
                    ForEach(Array(top), id: \.key) { name, count in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(name).font(.subheadline).lineLimit(1)
                                Spacer()
                                Text("\(count) visits")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            GeometryReader { geometry in
                                Capsule()
                                    .fill(Color.accentColor.gradient)
                                    .frame(width: max(geometry.size.width * Double(count) / Double(maxCount), 6))
                            }
                            .frame(height: 6)
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
        }
    }
}

/// A weekday × hour grid showing when trips start; darker cells mean more trips.
struct DrivingTimesGrid: View {
    let trips: [Trip]

    var body: some View {
        let calendar = Calendar.current
        var counts = Array(repeating: Array(repeating: 0, count: 24), count: 7)
        for trip in trips {
            let weekday = calendar.component(.weekday, from: trip.startDate)
            let row = CommuteAnalysis.weekdayOrder(weekday)
            counts[row][calendar.component(.hour, from: trip.startDate)] += 1
        }
        let maxCount = max(counts.flatMap { $0 }.max() ?? 1, 1)
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let busiest = Self.busiest(counts)

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("When you drive").font(.headline)
                Spacer()
                if let busiest {
                    Text("Busiest: \(calendar.standaloneWeekdaySymbols[Self.weekday(forRow: busiest.row) - 1]) \(CommuteAnalysis.clockText(busiest.hour * 60))", comment: "Weekday name, then a time of day")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            VStack(spacing: 3) {
                ForEach(0..<7, id: \.self) { row in
                    HStack(spacing: 3) {
                        Text(symbols[Self.weekday(forRow: row) - 1])
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 14)
                        ForEach(0..<24, id: \.self) { hour in
                            let count = counts[row][hour]
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(count == 0 ? AnyShapeStyle(.fill.tertiary) : AnyShapeStyle(Color.accentColor.opacity(0.25 + 0.75 * Double(count) / Double(maxCount))))
                                .aspectRatio(1, contentMode: .fit)
                        }
                    }
                }
                HStack(spacing: 0) {
                    Color.clear.frame(width: 17)
                    ForEach([0, 6, 12, 18], id: \.self) { hour in
                        Text(CommuteAnalysis.clockText(hour * 60))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(busiest.map { String(localized: "Most trips start on \(calendar.standaloneWeekdaySymbols[Self.weekday(forRow: $0.row) - 1]) around \(CommuteAnalysis.clockText($0.hour * 60))", comment: "Weekday name, then a time of day") } ?? String(localized: "No trips"))
        }
        .padding(16)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    /// Row 0 is the first day of the user's week.
    private static func weekday(forRow row: Int) -> Int {
        (row + Calendar.current.firstWeekday - 1) % 7 + 1
    }

    private static func busiest(_ counts: [[Int]]) -> (row: Int, hour: Int)? {
        var best: (row: Int, hour: Int, count: Int)?
        for row in 0..<7 {
            for hour in 0..<24 where counts[row][hour] > (best?.count ?? 0) {
                best = (row, hour, counts[row][hour])
            }
        }
        return best.map { ($0.row, $0.hour) }
    }
}
