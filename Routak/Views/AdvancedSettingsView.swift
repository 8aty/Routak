import SwiftUI

/// Fine-tuning for pausing, continuing and joining trips.
struct AdvancedSettingsView: View {
    @AppStorage(Prefs.maxPauseKey) private var maxPause = Prefs.defaultMaxPause
    @AppStorage(Prefs.continueWindowKey) private var continueWindow = Prefs.defaultContinueWindow
    @AppStorage(Prefs.continueRadiusKey) private var continueRadius = Prefs.defaultContinueRadius
    @AppStorage(Prefs.mergeTripsKey) private var mergeTrips = true
    @AppStorage(Prefs.mergeGapKey) private var mergeGap = Prefs.defaultMergeGap
    @AppStorage(Prefs.useMilesKey) private var useMiles = false

    private let pauseOptions: [Double] = [1_800, 3_600, 7_200, 14_400]
    private let continueTimeOptions: [Double] = [600, 900, 1_800, 3_600]
    private let continueDistanceOptions: [Double] = [250, 500, 1_000, 2_000]
    private let mergeOptions: [Double] = [300, 600, 900, 1_800]

    var body: some View {
        Form {
            Section {
                Picker("End paused trip after", selection: $maxPause) {
                    ForEach(pauseOptions, id: \.self) { Text(Format.duration($0)).tag($0) }
                }
            } header: {
                Text("Pause")
            } footer: {
                Text("A paused trip resumes by itself when you drive off. If it stays paused this long, it's saved and ends where you paused.")
            }

            Section {
                Picker("Within", selection: $continueWindow) {
                    ForEach(continueTimeOptions, id: \.self) { Text(Format.duration($0)).tag($0) }
                }
                Picker("Distance", selection: $continueRadius) {
                    ForEach(continueDistanceOptions, id: \.self) { Text(Format.distance($0, miles: useMiles)).tag($0) }
                }
            } header: {
                Text("Continue last trip")
            } footer: {
                Text("After a trip ends, the Drive screen offers to continue it while you're still this close to where it ended. The time in between counts as a pause.")
            }

            Section {
                Picker("Join if driving again within", selection: $mergeGap) {
                    ForEach(mergeOptions, id: \.self) { Text(Format.duration($0)).tag($0) }
                }
                .disabled(!mergeTrips)
            } header: {
                Text("Joining trips")
            } footer: {
                Text("When a drive starts this soon after the last one, close to where it ended, both become one trip with a pause in between. Turn joining on or off on the Settings screen.")
            }
        }
        .navigationTitle("Pause, Continue & Joining")
        .navigationBarTitleDisplayMode(.inline)
    }
}
