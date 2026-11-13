import SwiftUI

struct RootView: View {
    @State private var tab = RootView.initialTab

    /// Debug builds accept `-initialTab history|settings` as a launch argument (handy for screenshots).
    private static var initialTab: Tab {
        #if DEBUG
        Tab(rawValue: UserDefaults.standard.string(forKey: "initialTab") ?? "") ?? .drive
        #else
        .drive
        #endif
    }

    enum Tab: String, Hashable {
        case drive, history, settings
    }

    var body: some View {
        TabView(selection: $tab) {
            LiveView()
                .tabItem { Label("Drive", systemImage: "car.fill") }
                .tag(Tab.drive)
            HistoryView()
                .tabItem { Label("History", systemImage: "map.fill") }
                .tag(Tab.history)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                .tag(Tab.settings)
        }
    }
}
