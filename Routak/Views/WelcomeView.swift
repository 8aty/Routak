import CoreLocation
import SwiftUI

/// First-launch introduction: what Routak does, and why it asks for "Always" location access.
struct WelcomeView: View {
    @Environment(TripTracker.self) private var tracker
    var onFinish: () -> Void
    @State private var page = 0

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                introPage.tag(0)
                locationPage.tag(1)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .animation(.snappy, value: page)

            VStack(spacing: 12) {
                pageDots
                if page == 0 {
                    primaryButton("Continue") { page = 1 }
                } else {
                    locationButtons
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        }
        .background(Color(.systemBackground))
        .sensoryFeedback(.success, trigger: tracker.hasAlwaysPermission) { _, granted in granted }
        .interactiveDismissDisabled()
    }

    // MARK: Pages

    private var introPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 14) {
                    AppIconImage(size: 72)
                    Text("Welcome to Routak")
                        .font(.largeTitle.bold())
                    Text("Your drives, recorded automatically.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 22) {
                    feature("car.side.fill", color: .green, title: "Hands-free",
                            text: "Recording starts when you drive and stops when you park. No buttons to press.")
                    feature("map.fill", color: .blue, title: "Every route",
                            text: "Maps, speeds and replays for each trip, searchable by place, date and label.")
                    feature("chart.bar.fill", color: .orange, title: "Stats and logs",
                            text: "Weekly totals, commute times, fuel costs and mileage logs for expenses.")
                    feature("hand.raised.fill", color: .red, title: "Phone down while driving",
                            text: "Routak works on its own. You never need to look at it while driving.")
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 60)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var locationPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 14) {
                    Image(systemName: "location.fill")
                        .font(.system(size: 32, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 72, height: 72)
                        .background(Color.blue.gradient, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    Text("Allow location “Always”")
                        .font(.largeTitle.bold())
                    Text("Routak can only notice a drive starting if it may use your location while it's closed.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 20) {
                    feature("moon.zzz.fill", color: .indigo, title: "Works in the background",
                            text: "No need to open the app before you drive.")
                    feature("battery.75percent", color: .green, title: "Easy on battery",
                            text: "Until you drive, only low-power signals are used. GPS runs only during a drive.")
                    feature("lock.fill", color: .gray, title: "Private",
                            text: Persistence.supportsSync
                                ? "Your trips stay on your devices and in your own iCloud."
                                : "Your trips stay on your iPhone.")
                }
                steps
            }
            .padding(.horizontal, 24)
            .padding(.top, 60)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("iOS asks twice:")
                .font(.subheadline.weight(.semibold))
            step(1, "Tap **Allow While Using App**", done: tracker.isAuthorized)
            step(2, "Then tap **Change to Always Allow**", done: tracker.hasAlwaysPermission)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func step(_ number: Int, _ text: LocalizedStringKey, done: Bool) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(done ? Color.green : Color.accentColor.opacity(0.15))
                if done {
                    Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.white)
                } else {
                    Text(verbatim: "\(number)").font(.caption.weight(.bold)).foregroundStyle(Color.accentColor)
                }
            }
            .frame(width: 26, height: 26)
            .contentTransition(.symbolEffect(.replace))
            Text(text).font(.subheadline)
        }
        .animation(.snappy, value: done)
    }

    private func feature(_ systemImage: String, color: Color, title: LocalizedStringKey, text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(color)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(text).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Buttons

    private var pageDots: some View {
        HStack(spacing: 8) {
            ForEach(0..<2) { index in
                Capsule()
                    .fill(index == page ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: index == page ? 20 : 8, height: 8)
            }
        }
        .animation(.snappy, value: page)
        .padding(.bottom, 8)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var locationButtons: some View {
        if tracker.hasAlwaysPermission {
            primaryButton("Start Driving", action: onFinish)
        } else if tracker.isAuthorized {
            primaryButton("Change to Always") { tracker.requestPermission() }
            Button("Continue Without", action: onFinish)
                .font(.subheadline.weight(.semibold))
        } else if tracker.authorization == .notDetermined {
            primaryButton("Allow Location Access") { tracker.requestPermission() }
            Button("Not Now", action: onFinish)
                .font(.subheadline.weight(.semibold))
        } else {
            primaryButton("Open Settings") { tracker.openSettings() }
            Button("Not Now", action: onFinish)
                .font(.subheadline.weight(.semibold))
        }
    }

    private func primaryButton(_ title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }
}
