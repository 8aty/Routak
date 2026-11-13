import SwiftData
import SwiftUI

struct RootView: View {
    @State private var tab = RootView.initialTab
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var context
    @Environment(TripTracker.self) private var tracker
    @AppStorage(Prefs.hasOnboardedKey) private var hasOnboarded = false
    @State private var showWelcome = false
    @AppStorage(Prefs.drivingReminderKey) private var drivingReminder = true
    /// The trip (by start date) the road reminder was triggered for, and the one a passenger dismissed it for.
    @State private var remindedTrip: Date?
    @State private var passengerTrip: Date?
    #if DEBUG
    @State private var debugScreen: DebugScreen?
    #endif

    /// Debug builds accept `-initialTab history|stats|settings` as a launch argument (handy for screenshots).
    private static var initialTab: Tab {
        #if DEBUG
        Tab(rawValue: UserDefaults.standard.string(forKey: "initialTab") ?? "") ?? .drive
        #else
        .drive
        #endif
    }

    private func decideWelcome() {
        #if DEBUG
        // `-showWelcome YES` shows the welcome screen again.
        if UserDefaults.standard.bool(forKey: "showWelcome") {
            showWelcome = true
            return
        }
        #endif
        guard !hasOnboarded else { return }
        if tracker.authorization != .notDetermined {
            // Someone who used Routak before the welcome screen existed.
            hasOnboarded = true
        } else {
            showWelcome = true
        }
    }

    /// Speed above which the car counts as moving for the reminder (~15 km/h).
    private static let reminderSpeed = 4.2

    /// Once the car moves, the reminder stays up for the rest of the trip (red lights included)
    /// until a passenger dismisses it.
    private var showsDrivingReminder: Bool {
        guard drivingReminder, tracker.mode == .recording, let trip = tracker.activeStartDate else { return false }
        return remindedTrip == trip && passengerTrip != trip
    }

    private func updateDrivingReminder() {
        if tracker.mode == .recording, tracker.currentSpeed >= Self.reminderSpeed {
            remindedTrip = tracker.activeStartDate
        }
        #if DEBUG
        // `-drivingReminderPreview YES` shows the reminder without driving.
        if UserDefaults.standard.bool(forKey: "drivingReminderPreview") {
            DrivingReminderWindow.shared.show { DrivingReminderWindow.shared.hide() }
            return
        }
        #endif
        if showsDrivingReminder {
            DrivingReminderWindow.shared.show { passengerTrip = tracker.activeStartDate }
        } else {
            DrivingReminderWindow.shared.hide()
        }
    }

    enum Tab: String, Hashable {
        case drive, history, stats, settings
    }

    var body: some View {
        TabView(selection: $tab) {
            LiveView()
                .tabItem { Label("Drive", systemImage: "car.fill") }
                .tag(Tab.drive)
            HistoryView()
                .tabItem { Label("History", systemImage: "map.fill") }
                .tag(Tab.history)
            StatsView()
                .tabItem { Label("Stats", systemImage: "chart.bar.fill") }
                .tag(Tab.stats)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                .tag(Tab.settings)
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active {
                TripMaintenance.run(context: context)
                LiveActivityController.shared.appBecameActive(
                    isRecording: tracker.mode == .recording, startDate: tracker.activeStartDate, distance: tracker.activeDistance
                )
                WidgetSync.schedule()
            }
        }
        .onAppear(perform: decideWelcome)
        .onChange(of: tracker.currentSpeed) { updateDrivingReminder() }
        .onChange(of: tracker.mode) { updateDrivingReminder() }
        .onChange(of: drivingReminder) { updateDrivingReminder() }
        .onChange(of: passengerTrip) { updateDrivingReminder() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { updateDrivingReminder() } }
        #if DEBUG
        // `-debugScreen heatmap|commute|mileage|export|costs|fix` opens a screen directly (for screenshots).
        .sheet(item: $debugScreen) { screen in
            NavigationStack { DebugScreenView(screen: screen) }
        }
        .onAppear {
            debugScreen = UserDefaults.standard.string(forKey: "debugScreen").flatMap(DebugScreen.init(rawValue:))
        }
        #endif
        .fullScreenCover(isPresented: $showWelcome) {
            WelcomeView {
                hasOnboarded = true
                showWelcome = false
            }
        }
        // A light tap when a drive starts, a success buzz when it's saved (only felt with the app open).
        .sensoryFeedback(trigger: tracker.mode == .recording) { wasRecording, isRecording in
            isRecording ? .start : (wasRecording ? .success : nil)
        }
    }
}

#if DEBUG
enum DebugScreen: String, Identifiable {
    case heatmap, commute, mileage, export, costs, fix, widgets
    var id: String { rawValue }
}

private struct DebugScreenView: View {
    let screen: DebugScreen
    @Query(filter: #Predicate<Trip> { $0.isActive == false }, sort: \Trip.startDate, order: .reverse)
    private var trips: [Trip]
    @Query private var places: [SavedPlace]

    var body: some View {
        switch screen {
        case .heatmap: HeatmapView()
        case .commute:
            if let home = places.first(where: { $0.kind == .home }), let work = places.first(where: { $0.kind == .work }) {
                CommuteView(home: home, work: work)
            } else {
                Text("Set Home and Work first")
            }
        case .mileage: MileageLogView()
        case .export: ExportView()
        case .costs: CostSettingsView()
        case .widgets: WidgetGallery()
        case .fix:
            if let trip = trips.first(where: { $0.title.localizedCaseInsensitiveContains(UserDefaults.standard.string(forKey: "openTrip") ?? "") }) ?? trips.first {
                TripFixView(trip: trip) {}
            }
        }
    }
}
#endif

#if DEBUG
import WidgetKit

/// Every widget size and Live Activity state, drawn in the app for checking layouts.
private struct WidgetGallery: View {
    private let snapshot: WidgetSnapshot = {
        var snapshot = WidgetSnapshot.load() ?? .preview
        if UserDefaults.standard.bool(forKey: "galleryPreviewData") { snapshot = .preview }
        return snapshot
    }()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 16) {
                    tile(.systemSmall, width: 170, height: 170)
                    VStack(spacing: 12) {
                        tile(.accessoryCircular, width: 76, height: 76, lockScreen: true)
                        tile(.accessoryInline, width: 170, height: 24, lockScreen: true)
                    }
                }
                tile(.systemMedium, width: 364, height: 170)
                tile(.accessoryRectangular, width: 172, height: 76, lockScreen: true)
                activity(.init(distance: 12_400))
                activity(.init(distance: 12_400, isStopped: true))
                activity(.init(distance: 18_300, endDate: .now))
            }
            .padding(16)
        }
        .background(Color(white: 0.35))
        .navigationTitle(Text(verbatim: "Widgets"))
    }

    private func tile(_ family: WidgetFamily, width: CGFloat, height: CGFloat, lockScreen: Bool = false) -> some View {
        SummaryWidgetView(snapshot: snapshot, date: .now, family: family)
            .padding(lockScreen ? 0 : 16)
            .frame(width: width, height: height)
            .foregroundStyle(lockScreen ? Color.white : Color.primary)
            .background(lockScreen ? AnyShapeStyle(Color.clear) : AnyShapeStyle(Color(.systemBackground)),
                        in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func activity(_ state: TripActivityAttributes.ContentState) -> some View {
        TripActivityLockScreenView(content: TripActivityContent(
            attributes: TripActivityAttributes(startDate: .now.addingTimeInterval(-1_520), useMiles: Prefs.useMiles),
            state: state
        ))
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .environment(\.colorScheme, .dark)
    }
}
#endif
