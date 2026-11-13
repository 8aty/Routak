import Charts
import SwiftData
import SwiftUI

/// Drives between Home and Work: typical times, best and worst, and the quickest time to leave.
struct CommuteView: View {
    let home: SavedPlace
    let work: SavedPlace
    @Query(filter: #Predicate<Trip> { $0.isActive == false }, sort: \Trip.startDate, order: .reverse)
    private var trips: [Trip]
    @AppStorage(Prefs.useMilesKey) private var useMiles = false
    @State private var direction: CommuteAnalysis.Direction = .toWork

    var body: some View {
        let analysis = CommuteAnalysis(direction: direction, trips: trips, home: home, work: work)
        ScrollView {
            VStack(spacing: 16) {
                Picker("Direction", selection: $direction) {
                    ForEach(CommuteAnalysis.Direction.allCases) { Label($0.title, systemImage: $0.systemImage).tag($0) }
                }
                .pickerStyle(.segmented)

                if analysis.isEmpty {
                    ContentUnavailableView {
                        Label("No commutes yet", systemImage: "arrow.triangle.swap")
                    } description: {
                        Text(direction == .toWork
                             ? "Drives that start at \(home.name) and end at \(work.name) show up here."
                             : "Drives that start at \(work.name) and end at \(home.name) show up here.")
                    }
                    .padding(.top, 40)
                } else {
                    summary(analysis)
                    if let advice = departureAdvice(analysis) { advice }
                    departureChart(analysis)
                    if analysis.byWeekday.count > 1 { weekdayChart(analysis) }
                    recent(analysis)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
            .animation(.snappy, value: direction)
        }
        .navigationTitle("Commute")
        .navigationBarTitleDisplayMode(.inline)
        #if DEBUG
        // `-commuteDirection toHome` opens the other direction.
        .onAppear {
            if let raw = UserDefaults.standard.string(forKey: "commuteDirection"),
               let value = CommuteAnalysis.Direction(rawValue: raw) { direction = value }
        }
        #endif
    }

    private func summary(_ analysis: CommuteAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                StatView(title: "Average", value: Format.duration(analysis.average), valueFont: .largeTitle)
                Spacer()
                StatView(title: "Typical", value: Format.duration(analysis.median), alignment: .trailing)
            }
            Divider()
            HStack {
                StatView(title: "Fastest", value: Format.duration(analysis.fastest?.duration ?? 0))
                Spacer()
                StatView(title: "Slowest", value: Format.duration(analysis.slowest?.duration ?? 0))
                Spacer()
                StatView(title: "Drives", value: "\(analysis.trips.count)", alignment: .trailing)
            }
            Text("\(Format.distance(analysis.averageDistance, miles: useMiles)) on average")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func departureAdvice(_ analysis: CommuteAnalysis) -> AnyView? {
        guard let best = analysis.bestSlot, let worst = analysis.worstSlot,
              best.minute != worst.minute, worst.averageDuration - best.averageDuration >= 60 else { return nil }
        let saved = worst.averageDuration - best.averageDuration
        return AnyView(
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "lightbulb.max.fill")
                    .font(.title2)
                    .foregroundStyle(.yellow)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Leave around \(best.title)")
                        .font(.headline)
                    Text("Drives leaving then took \(Format.duration(best.averageDuration)) on average, \(Format.duration(saved)) less than leaving around \(worst.title).")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .background(Color.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        )
    }

    private func departureChart(_ analysis: CommuteAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Departure time vs. drive time").font(.headline)
            Chart {
                ForEach(analysis.trips) { trip in
                    PointMark(
                        x: .value("Left at", CommuteAnalysis.timeOfDay(trip.startDate)),
                        y: .value("Minutes", trip.duration / 60)
                    )
                    .foregroundStyle(Color.accentColor.opacity(0.7))
                    .symbolSize(40)
                }
                ForEach(analysis.slots) { slot in
                    LineMark(
                        x: .value("Left at", Self.slotDate(slot)),
                        y: .value("Minutes", slot.averageDuration / 60)
                    )
                    .foregroundStyle(.orange)
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                }
            }
            .chartXScale(domain: Self.timeDomain(analysis))
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.hour().minute())
                }
            }
            .chartYAxisLabel("min")
            .frame(height: 200)
            if analysis.slots.count > 1 {
                Label("Average per 15 minutes of departure time", systemImage: "line.diagonal")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(16)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    /// Whole hours around the departures, at least two hours wide, so a few drives don't zoom in to minutes.
    private static func timeDomain(_ analysis: CommuteAnalysis) -> ClosedRange<Date> {
        let calendar = Calendar.current
        let times = analysis.trips.map { CommuteAnalysis.timeOfDay($0.startDate) }
        let dayStart = calendar.startOfDay(for: .now)
        guard let first = times.min(), let last = times.max() else { return dayStart...dayStart.addingTimeInterval(86_400) }
        var lower = calendar.dateInterval(of: .hour, for: first)?.start ?? first
        var upper = calendar.dateInterval(of: .hour, for: last)?.end ?? last
        if upper.timeIntervalSince(lower) < 2 * 3_600 {
            lower = lower.addingTimeInterval(-1_800)
            upper = upper.addingTimeInterval(1_800)
        }
        return max(lower, dayStart)...min(upper, dayStart.addingTimeInterval(86_399))
    }

    private static func slotDate(_ slot: CommuteAnalysis.Slot) -> Date {
        let middle = slot.minute + CommuteAnalysis.slotMinutes / 2
        return Calendar.current.date(bySettingHour: middle / 60, minute: middle % 60, second: 0,
                                     of: Calendar.current.startOfDay(for: .now)) ?? .now
    }

    private func weekdayChart(_ analysis: CommuteAnalysis) -> some View {
        let symbols = Calendar.current.shortStandaloneWeekdaySymbols
        let best = analysis.byWeekday.min { $0.average < $1.average }?.weekday
        return VStack(alignment: .leading, spacing: 10) {
            Text("By day of the week").font(.headline)
            Chart(analysis.byWeekday, id: \.weekday) { day in
                BarMark(
                    x: .value("Day", symbols[day.weekday - 1]),
                    y: .value("Minutes", day.average / 60)
                )
                .foregroundStyle(day.weekday == best ? Color.green.gradient : Color.accentColor.gradient)
                .cornerRadius(4)
                .annotation(position: .top) {
                    Text("\(Int((day.average / 60).rounded()))")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .chartYAxis(.hidden)
            .frame(height: 160)
        }
        .padding(16)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func recent(_ analysis: CommuteAnalysis) -> some View {
        let average = analysis.average
        return VStack(alignment: .leading, spacing: 4) {
            Text("Recent").font(.headline).padding(.bottom, 6)
            ForEach(analysis.trips.prefix(10)) { trip in
                NavigationLink {
                    TripDetailView(trip: trip)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(trip.startDate.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                                .font(.subheadline.weight(.semibold))
                            Text("Left \(trip.startDate.formatted(date: .omitted, time: .shortened))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        let delta = trip.duration - average
                        if abs(delta) >= 60 {
                            Text("\(delta > 0 ? "+" : "−")\(Format.duration(abs(delta)))")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(delta > 0 ? .orange : .green)
                                .monospacedDigit()
                        }
                        Text(Format.duration(trip.duration))
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                            .frame(minWidth: 60, alignment: .trailing)
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}
