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
    @AppStorage(Prefs.lowBatteryStopKey) private var lowBatteryStop = true
    @Query private var places: [SavedPlace]
    @Query(filter: #Predicate<Trip> { $0.isActive == false }) private var trips: [Trip]
    @State private var confirmDeleteAll = false

    private let distanceOptions: [Double] = [500, 1_000, 2_000, 5_000, 10_000, 25_000]
    private let stopOptions: [Double] = [120, 180, 240, 300, 600]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Location access", value: permissionText)
                    LabeledContent("Precise location", value: tracker.hasPreciseLocation ? "On" : "Off")
                    if !tracker.hasAlwaysPermission || !tracker.hasPreciseLocation {
                        Button("Change in Settings") { tracker.requestPermission() }
                    }
                } header: {
                    Text("Permissions")
                } footer: {
                    Text("\"Always\" and Precise Location let Routak notice drives and record them while the app is closed.")
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
                    Text("When you start moving faster than about 23 km/h (15 mph), Routak begins recording. Shorter trips are discarded. Manual trips are always saved. While your phone still senses it's in a car, red lights and traffic jams don't end the trip.")
                }

                Section {
                    Toggle("Join trips split by short stops", isOn: $mergeTrips)
                    Toggle("Snap routes to roads", isOn: $snapToRoads)
                    Toggle("Stop GPS when battery is below 10%", isOn: $lowBatteryStop)
                } header: {
                    Text("Recording")
                } footer: {
                    Text("Driving again within 5 minutes of where a trip ended, after a gas stop for example, continues the same trip. Snapping uses Apple Maps directions to line routes up with roads, which helps in tunnels and between tall buildings. GPS records less often on highways to save battery.")
                }

                Section {
                    NavigationLink {
                        PlacesView()
                    } label: {
                        LabeledContent("Saved Places", value: places.isEmpty ? "None" : "\(places.count)")
                    }
                } footer: {
                    Text("Set Home and Work once, and trips are named “Home → Work” automatically.")
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
                    Button("Delete All Trips", role: .destructive) { confirmDeleteAll = true }
                        .disabled(trips.isEmpty)
                } header: {
                    Text("Data")
                } footer: {
                    Text("Trips are stored only on this iPhone.")
                }
            }
            .navigationTitle("Settings")
            .onChange(of: autoDetect) { tracker.settingsChanged() }
            .onChange(of: lowBatteryStop) { tracker.settingsChanged() }
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
        }
    }

    private var permissionText: String {
        switch tracker.authorization {
        case .authorizedAlways: "Always"
        case .authorizedWhenInUse: "While Using"
        case .denied: "Denied"
        case .restricted: "Restricted"
        case .notDetermined: "Not set"
        @unknown default: "Unknown"
        }
    }
}
