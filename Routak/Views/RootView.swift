import SwiftData
import SwiftUI

struct RootView: View {
    @State private var tab = RootView.initialTab
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var context
    @Environment(TripTracker.self) private var tracker
    @AppStorage(Prefs.hasOnboardedKey) private var hasOnboarded = false
    @State private var showWelcome = false
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
            if phase == .active { TripMaintenance.run(context: context) }
        }
        .onAppear(perform: decideWelcome)
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
    case heatmap, commute, mileage, export, costs, fix
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
        case .fix:
            if let trip = trips.first(where: { $0.title.localizedCaseInsensitiveContains(UserDefaults.standard.string(forKey: "openTrip") ?? "") }) ?? trips.first {
                TripFixView(trip: trip) {}
            }
        }
    }
}
#endif
