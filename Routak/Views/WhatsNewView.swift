import SwiftUI

/// What changed in this version, shown once after an update (and from Settings).
struct WhatsNewView: View {
    let notes: ReleaseNotes
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    private static let heroHeight: CGFloat = 300

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                hero
                ForEach(ReleaseNotes.Kind.allCases, id: \.self) { kind in
                    let items = notes.items.filter { $0.kind == kind }
                    if !items.isEmpty {
                        section(kind, items: items)
                            .padding(.horizontal, 24)
                    }
                }
            }
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .ignoresSafeArea(edges: .top)
        .background(Color(.systemBackground))
        .overlay(alignment: .topTrailing) { closeButton }
        .safeAreaInset(edge: .bottom) {
            Button {
                dismiss()
            } label: {
                Text("Continue")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 8)
            .background {
                LinearGradient(colors: [Color(.systemBackground).opacity(0), Color(.systemBackground)], startPoint: .top, endPoint: .center)
                    .ignoresSafeArea()
            }
        }
    }

    // MARK: Hero

    /// A blurred route map with the version on top. Stretches when pulled down.
    private var hero: some View {
        ZStack(alignment: .bottomLeading) {
            // In an overlay so the image's own width doesn't widen the page.
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: Self.heroHeight)
                .overlay {
                    Image("WhatsNewHero")
                        .resizable()
                        .scaledToFill()
                        .blur(radius: 4, opaque: true)
                        .saturation(1.15)
                        .overlay(Color.black.opacity(colorScheme == .dark ? 0.35 : 0))
                }
                .clipped()
                .overlay {
                    LinearGradient(
                        stops: [
                            .init(color: Color(.systemBackground).opacity(0), location: 0.3),
                            .init(color: Color(.systemBackground).opacity(0.75), location: 0.72),
                            .init(color: Color(.systemBackground), location: 1),
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                }
                .visualEffect { content, proxy in
                    let pull = max(0, proxy.frame(in: .scrollView(axis: .vertical)).minY)
                    return content.scaleEffect(1 + pull / Self.heroHeight, anchor: .bottom)
                }
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 10) {
                AppIconImage(size: 60)
                    .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
                    .padding(.bottom, 4)
                Text("Version \(notes.version)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.regularMaterial, in: Capsule())
                Text("What's New")
                    .font(.largeTitle.bold())
            }
            .padding(.horizontal, 24)
        }
        .frame(height: Self.heroHeight)
    }

    private var closeButton: some View {
        Button {
            dismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.primary)
                .frame(width: 32, height: 32)
                .background(.regularMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .padding(16)
        .accessibilityLabel("Close")
    }

    // MARK: Changes

    private func section(_ kind: ReleaseNotes.Kind, items: [ReleaseNotes.Item]) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Label {
                Text(kind.title)
            } icon: {
                Image(systemName: kind.symbol)
            }
            .font(.footnote.weight(.bold))
            .textCase(.uppercase)
            .foregroundStyle(kind.color)
            ForEach(items) { item in
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: item.symbol)
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(item.color.gradient, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.title).font(.headline)
                        Text(item.text)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// The app's real icon (light or dark). `AppIcon` itself can't be loaded as an image,
/// so a small copy lives in the asset catalog as `AppIconImage`.
struct AppIconImage: View {
    var size: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous)
        Image("AppIconImage")
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .clipShape(shape)
            .overlay(shape.strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
            .accessibilityHidden(true)
    }
}

/// The changes in one version. Add an entry to `all` for each release worth telling about.
struct ReleaseNotes {
    enum Kind: CaseIterable {
        case new, improved, fixed

        var title: LocalizedStringResource {
            switch self {
            case .new: LocalizedStringResource("whatsNew.new", defaultValue: "New", comment: "What's New section: new features")
            case .improved: LocalizedStringResource("whatsNew.improved", defaultValue: "Improved", comment: "What's New section: improvements")
            case .fixed: LocalizedStringResource("whatsNew.fixed", defaultValue: "Fixed", comment: "What's New section: bug fixes")
            }
        }

        var symbol: String {
            switch self {
            case .new: "sparkles"
            case .improved: "arrow.up.circle.fill"
            case .fixed: "checkmark.seal.fill"
            }
        }

        var color: Color {
            switch self {
            case .new: .accentColor
            case .improved: .green
            case .fixed: .orange
            }
        }
    }

    struct Item: Identifiable {
        let kind: Kind
        let symbol: String
        let color: Color
        let title: LocalizedStringResource
        let text: LocalizedStringResource
        var id: String { symbol }
    }

    /// "major.minor", e.g. "1.1". Patch releases share their version's notes.
    let version: String
    let items: [Item]

    static let all: [ReleaseNotes] = [
        ReleaseNotes(version: "1.1", items: [
            Item(kind: .new, symbol: "pause.fill", color: .orange,
                 title: "Pause and continue",
                 text: "Pause at a stop and Routak carries on when you drive off. Ended a trip too soon? Continue it."),
            Item(kind: .new, symbol: "tag.fill", color: .purple,
                 title: "Your own labels",
                 text: "Create labels with your own name, color and icon."),
            Item(kind: .new, symbol: "fuelpump.fill", color: .green,
                 title: "Trip cost",
                 text: "See roughly what each drive cost in fuel."),
            Item(kind: .improved, symbol: "location.fill", color: .blue,
                 title: "Smarter recording",
                 text: "Trips start where you parked, and trips you end yourself are always saved."),
            Item(kind: .improved, symbol: "chart.xyaxis.line", color: .teal,
                 title: "Speed chart",
                 text: "Touch the chart to see how fast you were going."),
            Item(kind: .fixed, symbol: "wrench.and.screwdriver.fill", color: .gray,
                 title: "Fixes",
                 text: "Route colors no longer flicker during a replay, plus smaller fixes."),
        ]),
    ]

    /// This build's version, e.g. "1.1".
    static var currentVersion: String {
        let full = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        return full.split(separator: ".").prefix(2).joined(separator: ".")
    }

    /// Notes for this version, if it has any.
    static var current: ReleaseNotes? {
        all.first { $0.version == currentVersion }
    }

    private static let lastSeenKey = "whatsNewSeenVersion"

    /// Notes to show on launch: only once per version, and not on a fresh install.
    static var unseen: ReleaseNotes? {
        guard let current, UserDefaults.standard.string(forKey: lastSeenKey) != current.version else { return nil }
        return current
    }

    static func markSeen() {
        UserDefaults.standard.set(currentVersion, forKey: lastSeenKey)
    }
}

extension ReleaseNotes: Identifiable {
    var id: String { version }
}
