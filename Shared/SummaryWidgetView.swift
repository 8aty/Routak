import SwiftUI
import WidgetKit

/// This week's driving and the last trip, for the Home Screen and Lock Screen widgets.
struct SummaryWidgetView: View {
    let snapshot: WidgetSnapshot?
    let date: Date
    let family: WidgetFamily

    private var miles: Bool { snapshot?.useMiles ?? false }
    private var week: (distance: Double, duration: Double, trips: Int) {
        snapshot?.week(of: date) ?? (0, 0, 0)
    }

    var body: some View {
        switch family {
        case .accessoryRectangular: rectangular
        case .accessoryCircular: circular
        case .accessoryInline: inline
        case .systemMedium: medium
        default: small
        }
    }

    // MARK: Home Screen

    private var small: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            Spacer(minLength: 0)
            weekTotal
            WeekBars(values: snapshot?.dailyDistances(weekOf: date) ?? [], date: date)
                .frame(height: 26)
                .padding(.top, 4)
        }
    }

    private var medium: some View {
        HStack(spacing: 16) {
            small
            Divider()
            lastTripView
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Label("This week", systemImage: "car.fill")
                .font(.caption.weight(.bold))
                .foregroundStyle(Color.routakAccent)
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
            Spacer(minLength: 0)
            if snapshot?.isRecording == true {
                Circle().fill(.red).frame(width: 8, height: 8)
                    .accessibilityLabel(Text("Recording"))
            }
        }
    }

    private var weekTotal: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(SharedFormat.distanceNumber(week.distance, miles: miles))
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                Text(SharedFormat.unit(miles: miles))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Text("\(week.trips) trips")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var lastTripView: some View {
        if let trip = snapshot?.lastTrip {
            VStack(alignment: .leading, spacing: 4) {
                Text("Last trip")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                Text(trip.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Spacer(minLength: 0)
                Text(SharedFormat.distance(trip.distance, miles: miles))
                    .font(.title3.weight(.bold))
                Text(verbatim: "\(SharedFormat.duration(trip.duration)) · \(trip.endDate.formatted(.relative(presentation: .named)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text("No trips yet")
                    .font(.subheadline.weight(.semibold))
                Text("Drives show up here automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Lock Screen

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            Label("This week", systemImage: "car.fill")
                .font(.caption.weight(.semibold))
                .widgetAccentable()
            Text(SharedFormat.distance(week.distance, miles: miles))
                .font(.title3.weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text("\(week.trips) trips")
                .font(.caption)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 0) {
                Image(systemName: "car.fill")
                    .font(.caption2)
                    .widgetAccentable()
                Text(SharedFormat.distanceNumber(week.distance, miles: miles))
                    .font(.headline.weight(.bold))
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                Text(SharedFormat.unit(miles: miles))
                    .font(.caption2)
            }
            .padding(4)
        }
    }

    private var inline: some View {
        Label {
            Text("\(SharedFormat.distance(week.distance, miles: miles)) this week")
        } icon: {
            Image(systemName: "car.fill")
        }
    }
}

/// Seven small bars, one per day of the week.
struct WeekBars: View {
    let values: [Double]
    let date: Date

    var body: some View {
        let maxValue = max(values.max() ?? 0, 1)
        let today = todayIndex
        HStack(alignment: .bottom, spacing: 4) {
            ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                Capsule()
                    .fill(index == today ? Color.routakAccent : Color.routakAccent.opacity(index < today ? 0.45 : 0.15))
                    .frame(maxWidth: .infinity)
                    .frame(height: max(4, 26 * value / maxValue))
            }
        }
        .accessibilityHidden(true)
    }

    private var todayIndex: Int {
        let calendar = Calendar.current
        guard let start = calendar.dateInterval(of: .weekOfYear, for: date)?.start else { return 0 }
        return calendar.dateComponents([.day], from: start, to: calendar.startOfDay(for: date)).day ?? 0
    }
}
