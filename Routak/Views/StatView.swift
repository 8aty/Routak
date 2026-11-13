import SwiftUI

/// A big number with a small unit and caption, used across the app.
struct StatView: View {
    let title: String
    let value: String
    var unit: String = ""
    var alignment: HorizontalAlignment = .leading
    var valueFont: Font = .title2

    var body: some View {
        VStack(alignment: alignment, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(valueFont.weight(.semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                if !unit.isEmpty {
                    Text(unit)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
        }
    }
}

/// A compact icon + text pill used on trip cards.
struct MetricLabel: View {
    let systemImage: String
    let text: String

    var body: some View {
        Label {
            Text(text).monospacedDigit()
        } icon: {
            Image(systemName: systemImage).foregroundStyle(.tint)
        }
        .font(.subheadline.weight(.medium))
        .labelStyle(.titleAndIcon)
    }
}
