import ActivityKit
import SwiftUI
import WidgetKit

struct TripLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TripActivityAttributes.self) { context in
            TripActivityLockScreenView(content: TripActivityContent(attributes: context.attributes, state: context.state))
                .activitySystemActionForegroundColor(Color.routakAccent)
        } dynamicIsland: { context in
            let content = TripActivityContent(attributes: context.attributes, state: context.state)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label {
                        Text(content.distance).font(.title3.weight(.bold)).monospacedDigit()
                    } icon: {
                        Image(systemName: content.isEnded ? "checkmark.circle.fill" : "car.fill")
                            .foregroundStyle(content.isEnded ? Color.green : Color.routakAccent)
                    }
                    .padding(.leading, 6)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    content.elapsed
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 90, alignment: .trailing)
                        .padding(.trailing, 6)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Text(content.status)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if !content.isEnded { content.endButton }
                    }
                    .padding(.horizontal, 6)
                }
            } compactLeading: {
                Image(systemName: content.isEnded ? "checkmark" : "car.fill")
                    .foregroundStyle(content.isEnded ? Color.green : Color.routakAccent)
            } compactTrailing: {
                Text(content.distance)
                    .font(.footnote.weight(.semibold))
                    .monospacedDigit()
            } minimal: {
                Image(systemName: content.isEnded ? "checkmark" : "car.fill")
                    .foregroundStyle(content.isEnded ? Color.green : Color.routakAccent)
            }
            .keylineTint(Color.routakAccent)
        }
    }
}
