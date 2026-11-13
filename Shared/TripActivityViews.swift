import AppIntents
import SwiftUI

/// The Live Activity's pieces. Deliberately sparse: a driver should be able to take it in at a glance.
struct TripActivityContent {
    let attributes: TripActivityAttributes
    let state: TripActivityAttributes.ContentState

    var isEnded: Bool { state.endDate != nil }
    var isPaused: Bool { !isEnded && state.pausedSince != nil }

    var status: LocalizedStringKey {
        if isEnded { return "Trip saved" }
        if isPaused { return "Paused" }
        if state.isStopped { return "Stopped · still recording" }
        return "Recording drive"
    }

    /// Where the trip timer starts: pauses are left out of the trip time.
    private var timerStart: Date { attributes.startDate.addingTimeInterval(state.pausedTotal ?? 0) }

    var symbol: String { isEnded ? "checkmark" : (isPaused ? "pause.fill" : "car.fill") }

    var tint: Color { isEnded ? .green : (isPaused ? .orange : .routakAccent) }

    var distance: String { SharedFormat.distance(state.distance, miles: attributes.useMiles) }

    /// Counts up by itself while recording, so the activity needn't be updated every second.
    @ViewBuilder
    var elapsed: some View {
        if let end = state.endDate ?? state.pausedSince {
            // Ended or paused: the trip time stands still.
            Text(SharedFormat.duration(max(0, end.timeIntervalSince(timerStart))))
        } else {
            Text(timerInterval: timerStart...Date.distantFuture, countsDown: false)
        }
    }

    var icon: some View {
        Image(systemName: symbol)
            .font(.headline)
            .foregroundStyle(.white)
            .frame(width: 40, height: 40)
            .background(tint, in: Circle())
    }

    /// Pause while recording, resume while paused.
    @ViewBuilder
    var pauseButton: some View {
        if isPaused {
            Button(intent: ResumeTripIntent()) {
                roundButton("play.fill", color: .green)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Resume Trip"))
        } else {
            Button(intent: PauseTripIntent()) {
                roundButton("pause.fill", color: .orange)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Pause Trip"))
        }
    }

    private func roundButton(_ systemImage: String, color: Color) -> some View {
        Image(systemName: systemImage)
            .font(.headline)
            .foregroundStyle(.white)
            .frame(width: 44, height: 44)
            .background(color, in: Circle())
    }

    /// A round stop button: no text, so it fits in every language and reads at a glance.
    var endButton: some View {
        Button(intent: EndTripIntent()) {
            Image(systemName: "stop.fill")
                .font(.headline)
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(Color.red, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("End Trip"))
    }
}

/// Lock Screen and notification banner.
struct TripActivityLockScreenView: View {
    let content: TripActivityContent

    var body: some View {
        HStack(spacing: 14) {
            content.icon
            VStack(alignment: .leading, spacing: 2) {
                Text(content.status)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(content.distance)
                        .font(.title2.weight(.bold))
                        .layoutPriority(1)
                    content.elapsed
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .monospacedDigit()
                .lineLimit(1)
            }
            Spacer(minLength: 0)
            if !content.isEnded {
                content.pauseButton
                content.endButton
            }
        }
        .padding(16)
    }
}
