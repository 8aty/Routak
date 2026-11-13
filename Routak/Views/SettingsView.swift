import AppIntents
import CloudKit
import CoreLocation
import SwiftData
import SwiftUI

struct SettingsView: View {
    @Environment(TripTracker.self) private var tracker
    @Environment(\.modelContext) private var context
    @AppStorage(Prefs.autoDetectKey) private var autoDetect = true
    @AppStorage(Prefs.minTripDistanceKey) private var minTripDistance = Prefs.defaultMinTripDistance
    @AppStorage(Prefs.stopTimeoutKey) private var stopTimeout = Prefs.defaultStopTimeout
    @AppStorage(Prefs.useMilesKey) private var useMiles = false
    @AppStorage(Prefs.snapToRoadsKey) private var snapToRoads = true
    @AppStorage(Prefs.mergeTripsKey) private var mergeTrips = true
    @AppStorage(Prefs.mergeGapKey) private var mergeGap = Prefs.defaultMergeGap
    @AppStorage(Prefs.lowBatteryStopKey) private var lowBatteryStop = true
    @AppStorage(Prefs.fuelPriceKey) private var fuelPrice = 0.0
    @AppStorage(Prefs.drivingReminderKey) private var drivingReminder = true
    @AppStorage(Prefs.liveActivityKey) private var liveActivity = true
    @AppStorage(Prefs.iCloudSyncKey) private var iCloudSync = true
    @State private var iCloudAccount: CKAccountStatus?
    @Query private var places: [SavedPlace]
    @Query(filter: #Predicate<Trip> { $0.isActive == false }) private var trips: [Trip]
    @State private var confirmDeleteAll = false
    @State private var whatsNew: ReleaseNotes?

    private let distanceOptions: [Double] = [500, 1_000, 2_000, 5_000, 10_000, 25_000]
    private let stopOptions: [Double] = [120, 180, 240, 300, 600]

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
            Form {
                Section {
                    LabeledContent("Location access", value: permissionText)
                    LabeledContent("Precise location", value: tracker.hasPreciseLocation ? String(localized: "On") : String(localized: "Off"))
                    if !tracker.hasAlwaysPermission || !tracker.hasPreciseLocation {
                        Button("Change in Settings") { tracker.requestPermission() }
                    }
                } header: {
                    Text("Permissions")
                } footer: {
                    Text("“Always” and Precise Location let Routak notice drives and record them while the app is closed.")
                }

                Section {
                    Toggle("Detect drives automatically", isOn: $autoDetect)
                    Picker("Save trips longer than", selection: $minTripDistance) {
                        ForEach(distanceOptions, id: \.self) { meters in
                            Text(Format.distance(meters, miles: useMiles)).tag(meters)
                        }
                    }
                    .disabled(!autoDetect)
                    Picker("End trip after parked for", selection: $stopTimeout) {
                        ForEach(stopOptions, id: \.self) { seconds in
                            Text("\(Int(seconds / 60)) min").tag(seconds)
                        }
                    }
                    .disabled(!autoDetect)
                } header: {
                    Text("Trip detection")
                } footer: {
                    Text("When you start moving faster than about 23 km/h (15 mph), Routak begins recording. Shorter trips are discarded, unless you end them yourself. Manual trips are always saved. While your phone still senses it's in a car, red lights and traffic jams don't end the trip.")
                }

                Section {
                    Toggle("Join trips split by short stops", isOn: $mergeTrips)
                    Toggle("Snap routes to roads", isOn: $snapToRoads)
                    Toggle("Stop GPS when battery is below 10%", isOn: $lowBatteryStop)
                    NavigationLink("Pause, Continue & Joining") { AdvancedSettingsView() }
                } header: {
                    Text("Recording")
                } footer: {
                    Text("Driving again within \(Int(mergeGap / 60)) minutes of where a trip ended, after a gas stop for example, continues the same trip. Snapping uses Apple Maps directions to line routes up with roads, which helps in tunnels and between tall buildings. GPS records less often on highways to save battery.")
                }

                Section {
                    Toggle("Cover the screen while driving", isOn: $drivingReminder)
                } header: {
                    Text("Safety")
                } footer: {
                    Text("In a moving car, Routak shows “Eyes on the road”. Passengers can close it with one tap.")
                }

                Section {
                    Toggle("Show trip on Lock Screen", isOn: $liveActivity)
                        .id("settingsShortcuts")
                    ShortcutsLink()
                        .frame(maxWidth: .infinity)
                } header: {
                    Text("Lock Screen & Shortcuts")
                } footer: {
                    Text("To start trips when your phone connects to CarPlay or your car's Bluetooth, make an automation in the Shortcuts app with Routak's Start Trip action.")
                }

                Section {
                    NavigationLink {
                        LabelsView()
                    } label: {
                        LabeledContent("Labels", value: "\(LabelBook.shared.labels.count)")
                    }
                } footer: {
                    Text("Your own labels for trips, like Work, Gym or School run.")
                }

                Section {
                    NavigationLink {
                        PlacesView()
                    } label: {
                        LabeledContent("Saved Places", value: places.isEmpty ? String(localized: "None") : "\(places.count)")
                    }
                } footer: {
                    Text("Set Home and Work once, and trips are named “Home → Work” automatically.")
                }

                Section {
                    NavigationLink {
                        CostSettingsView()
                    } label: {
                        LabeledContent("Fuel & Mileage", value: fuelPrice > 0 ? "\(Costs.money(Costs.displayPrice(fuelPrice, miles: useMiles))) / \(Costs.volumeUnit(miles: useMiles))" : String(localized: "Not set"))
                    }
                } footer: {
                    Text("Fuel price and economy for cost estimates, and the rate for the mileage log.")
                }

                Section("Units") {
                    Picker("Distance", selection: $useMiles) {
                        Text("Kilometers").tag(false)
                        Text("Miles").tag(true)
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    LabeledContent("Saved trips", value: "\(trips.count)")
                    LabeledContent("Total distance", value: Format.distance(trips.reduce(0) { $0 + $1.distance }, miles: useMiles))
                    if Persistence.supportsSync {
                        Toggle("Sync with iCloud", isOn: $iCloudSync)
                        LabeledContent("iCloud", value: iCloudStatusText)
                    }
                    NavigationLink("Export & Import") { ExportView() }
                    Button("Delete All Trips", role: .destructive) { confirmDeleteAll = true }
                        .id("settingsBottom")
                        .disabled(trips.isEmpty)
                } header: {
                    Text("Data")
                } footer: {
                    Text(Persistence.supportsSync && iCloudSync
                         ? "Trips and saved places sync to your other devices through your iCloud account."
                         : "Trips are stored only on this iPhone.")
                }
                if let notes = ReleaseNotes.current {
                    Section {
                        Button {
                            whatsNew = notes
                        } label: {
                            LabeledContent {
                                Text("Version \(notes.version)")
                            } label: {
                                Label("What's New", systemImage: "sparkles")
                            }
                        }
                        .tint(.primary)
                    }
                }
            }
            .navigationTitle("Settings")
            .sheet(item: $whatsNew) { WhatsNewView(notes: $0) }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: autoDetect) { tracker.settingsChanged() }
            .onChange(of: lowBatteryStop) { tracker.settingsChanged() }
            .onChange(of: useMiles) { WidgetSync.schedule() }
            .onChange(of: liveActivity) {
                LiveActivityController.shared.settingChanged()
            }
            .task {
                guard Persistence.isSyncing else { return }
                iCloudAccount = try? await CKContainer(identifier: Persistence.cloudContainerID).accountStatus()
            }
            .onChange(of: snapToRoads) { _, on in
                if on { TripMaintenance.snapPending(context: context) }
            }
            .confirmationDialog("Delete all \(trips.count) trips?", isPresented: $confirmDeleteAll, titleVisibility: .visible) {
                Button("Delete All Trips", role: .destructive) {
                    for trip in trips { context.delete(trip) }
                    try? context.save()
                    RouteSnapshotter.clearDiskCache()
                }
            }
            #if DEBUG
            // `-settingsScroll bottom|shortcuts` opens Settings scrolled down (for screenshots).
            .task {
                guard let target = UserDefaults.standard.string(forKey: "settingsScroll") else { return }
                try? await Task.sleep(for: .milliseconds(400))
                proxy.scrollTo(target == "bottom" ? "settingsBottom" : "settingsShortcuts", anchor: target == "bottom" ? .bottom : .center)
            }
            #endif
            }
        }
    }

    private var iCloudStatusText: String {
        if iCloudSync != Persistence.syncSettingAtLaunch {
            return String(localized: "Applies after restart", comment: "iCloud sync setting changed; takes effect when the app is reopened")
        }
        guard iCloudSync else { return String(localized: "Off") }
        guard Persistence.isSyncing else { return String(localized: "Unavailable", comment: "iCloud account status") }
        switch iCloudAccount {
        case .available: return String(localized: "On")
        case .noAccount: return String(localized: "Not signed in", comment: "iCloud account status")
        case .restricted, .temporarilyUnavailable: return String(localized: "Unavailable", comment: "iCloud account status")
        default: return String(localized: "Checking…", comment: "iCloud account status")
        }
    }

    private var permissionText: String {
        switch tracker.authorization {
        case .authorizedAlways: String(localized: "Always", comment: "Location permission state")
        case .authorizedWhenInUse: String(localized: "While Using", comment: "Location permission state")
        case .denied: String(localized: "Denied", comment: "Location permission state")
        case .restricted: String(localized: "Restricted", comment: "Location permission state")
        case .notDetermined: String(localized: "Not set")
        @unknown default: String(localized: "Unknown", comment: "Location permission state")
        }
    }
}
