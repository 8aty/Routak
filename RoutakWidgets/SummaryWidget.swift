import SwiftUI
import WidgetKit

struct SummaryEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
}

struct SummaryProvider: TimelineProvider {
    func placeholder(in context: Context) -> SummaryEntry {
        SummaryEntry(date: .now, snapshot: .preview)
    }

    func getSnapshot(in context: Context, completion: @escaping (SummaryEntry) -> Void) {
        completion(SummaryEntry(date: .now, snapshot: context.isPreview ? .preview : WidgetSnapshot.load() ?? .preview))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SummaryEntry>) -> Void) {
        // The app reloads the widget when trips change; a second entry at midnight
        // starts the new day (and week) on time.
        let snapshot = WidgetSnapshot.load()
        let now = Date.now
        let midnight = Calendar.current.nextDate(after: now, matching: DateComponents(hour: 0, minute: 0), matchingPolicy: .nextTime) ?? now.addingTimeInterval(3_600)
        completion(Timeline(
            entries: [SummaryEntry(date: now, snapshot: snapshot), SummaryEntry(date: midnight, snapshot: snapshot)],
            policy: .after(midnight)
        ))
    }
}

struct SummaryWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "RoutakSummary", provider: SummaryProvider()) { entry in
            SummaryEntryView(entry: entry)
        }
        .configurationDisplayName("This Week")
        .description("Distance driven this week and your last trip.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryCircular, .accessoryInline])
    }
}

private struct SummaryEntryView: View {
    let entry: SummaryEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        SummaryWidgetView(snapshot: entry.snapshot, date: entry.date, family: family)
            .containerBackground(.fill.tertiary, for: .widget)
    }
}
