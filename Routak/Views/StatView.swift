import SwiftUI

/// A big number with a small unit and caption, used across the app.
struct StatView: View {
    let title: LocalizedStringKey
    let value: String
    var unit: String = ""
    var alignment: HorizontalAlignment = .leading
    var valueFont: Font = .title2
    /// Shows an ⓘ button next to the caption that explains the number (e.g. that it's an estimate).
    var info: LocalizedStringKey?
    @State private var showsInfo = false

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
            HStack(spacing: 4) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                if let info {
                    Button {
                        showsInfo = true
                    } label: {
                        Image(systemName: "info.circle")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            // A bigger target than the small icon.
                            .padding(6)
                            .contentShape(Rectangle())
                            .padding(-6)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("More info")
                    .popover(isPresented: $showsInfo) {
                        Text(info)
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding()
                            .frame(width: 290)
                            .presentationCompactAdaptation(.popover)
                    }
                }
            }
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
