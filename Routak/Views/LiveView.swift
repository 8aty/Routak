import MapKit
import SwiftData
import SwiftUI

/// The main screen: a live map, current tracking status and manual trip controls.
///
/// The map, the control panel and the route syncing are separate views on purpose:
/// the map only re-renders when the drawn route changes, not on every speed/distance update,
/// and the panel floats over the map instead of animating the map's layout.
/// Animating the map's insets makes MapKit redraw every frame, which shows up as
/// "Failed to acquire drawable" and a black flash behind the panel.
struct LiveView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var position: MapCameraPosition = .userLocation(fallback: .automatic)
    /// The route drawn on the map. Only refreshed while the map is on screen.
    @State private var routeCoordinates: [CLLocationCoordinate2D] = []
    @State private var isVisible = false
    @State private var panelHeight: CGFloat = 0
    @Namespace private var mapScope

    var body: some View {
        ZStack(alignment: .bottom) {
            LiveMap(position: $position, route: routeCoordinates, scope: mapScope)
                .safeAreaPadding(.bottom, panelHeight)

            VStack(alignment: .trailing, spacing: 10) {
                // Map buttons sit just above the panel, within thumb reach.
                VStack(spacing: 10) {
                    MapCompass(scope: mapScope)
                    MapUserLocationButton(scope: mapScope)
                }
                .buttonBorderShape(.circle)
                .controlSize(.large)

                LiveControlPanel()
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                        // Move the map's legal/logo area once, without animation.
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) { panelHeight = height + 8 }
                    }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        .mapScope(mapScope)
        .background {
            RouteSync(
                isActive: isVisible && scenePhase == .active,
                route: $routeCoordinates,
                position: $position
            )
        }
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
    }
}

/// Copies the recorded route into the map's state, only while the map is visible.
private struct RouteSync: View {
    @Environment(TripTracker.self) private var tracker
    let isActive: Bool
    @Binding var route: [CLLocationCoordinate2D]
    @Binding var position: MapCameraPosition

    var body: some View {
        Color.clear
            .onChange(of: tracker.activePoints.count, initial: true) { sync() }
            .onChange(of: isActive) { sync() }
            .onChange(of: tracker.mode) { _, mode in
                if mode == .recording {
                    withAnimation { position = .userLocation(followsHeading: false, fallback: .automatic) }
                }
            }
    }

    private func sync() {
        guard isActive else { return }
        let coordinates = tracker.activePoints.map(\.coordinate)
        if coordinates.count != route.count { route = coordinates }
    }
}

private struct LiveMap: View {
    @Binding var position: MapCameraPosition
    let route: [CLLocationCoordinate2D]
    let scope: Namespace.ID

    var body: some View {
        Map(position: $position, scope: scope) {
            UserAnnotation()
            if route.count > 1 {
                // Separate levels keep the outline under the line when the route updates.
                MapPolyline(coordinates: route)
                    .stroke(.white.opacity(0.85), style: StrokeStyle(lineWidth: 9, lineCap: .round, lineJoin: .round))
                    .mapOverlayLevel(level: .aboveRoads)
                MapPolyline(coordinates: route)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 5.5, lineCap: .round, lineJoin: .round))
                    .mapOverlayLevel(level: .aboveLabels)
            }
            if let first = route.first {
                Annotation(String(localized: "Start"), coordinate: first, anchor: .center) {
                    RouteEndpoint(color: .green, systemImage: "car.fill")
                }
            }
        }
        .mapStyle(.standard(elevation: .realistic))
        // Controls are placed by LiveView near the bottom instead of MapKit's top corner.
        .mapControls {}
    }
}

private struct LiveControlPanel: View {
    @Environment(TripTracker.self) private var tracker
    @AppStorage(Prefs.useMilesKey) private var useMiles = false
    @Query(lastTripDescriptor) private var lastTrips: [Trip]

    private static var lastTripDescriptor: FetchDescriptor<Trip> {
        var descriptor = FetchDescriptor<Trip>(
            predicate: #Predicate { $0.isActive == false },
            sortBy: [SortDescriptor(\.startDate, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return descriptor
    }

    var body: some View {
        VStack(spacing: 12) {
            if !tracker.hasAlwaysPermission || !tracker.hasPreciseLocation {
                PermissionCard()
            }
            if tracker.mode == .recording {
                recordingPanel
                    .transition(.blurReplace)
            } else if tracker.mode == .paused {
                pausedPanel
                    .transition(.blurReplace)
            } else {
                idlePanel
                    .transition(.blurReplace)
            }
        }
        .animation(.snappy, value: tracker.mode)
        .animation(.snappy, value: tracker.continuableTrip == nil)
        .animation(.snappy, value: tracker.stopCheckDeadline == nil)
        // "Continue last trip" depends on time and place, so check again now and then.
        .task(id: tracker.hasOpenTrip) {
            guard !tracker.hasOpenTrip else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                tracker.refreshContinuableTrip()
            }
        }
    }

    private var recordingPanel: some View {
        VStack(spacing: 14) {
            HStack(spacing: 8) {
                RecordingBadge()
                Spacer()
                Text(recordingNote)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .top) {
                let distance = Format.distanceParts(tracker.activeDistance, miles: useMiles)
                StatView(title: "Distance", value: distance.value, unit: distance.unit, valueFont: .largeTitle)
                Spacer()
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    StatView(
                        title: "Time",
                        value: Format.clock(context.date.timeIntervalSince(tracker.activeTimerStart ?? context.date)),
                        alignment: .center,
                        valueFont: .largeTitle
                    )
                }
                Spacer()
                let speed = Format.speedParts(tracker.currentSpeed, miles: useMiles)
                StatView(title: "Speed", value: speed.value, unit: speed.unit, alignment: .trailing, valueFont: .largeTitle)
            }
            if let deadline = tracker.stopCheckDeadline {
                stopCheckRow(deadline: deadline)
            }
            HStack(spacing: 10) {
                Button {
                    tracker.pauseTrip()
                } label: {
                    Label("Pause", systemImage: "pause.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
                .tint(.orange)
                .disabled(!tracker.canPause)
                endTripButton
            }
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    private var endTripButton: some View {
        Button(role: .destructive) {
            tracker.stopTrip()
        } label: {
            Label("End Trip", systemImage: "stop.fill")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .tint(.red)
    }

    /// A manual trip that stopped moving: it ends soon unless you keep it going.
    private func stopCheckRow(deadline: Date) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "hourglass")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("Still driving?").font(.subheadline.weight(.semibold))
                Text("Ends in \(Text(timerInterval: Date.now...max(deadline, .now), countsDown: true))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
            Button("Keep Recording") { tracker.keepRecording() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(10)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var pausedPanel: some View {
        VStack(spacing: 14) {
            HStack(spacing: 8) {
                PausedBadge(since: tracker.pausedSince ?? .now)
                Spacer()
                Text(tracker.hasAlwaysPermission ? "Resumes when you drive off" : "Tap Resume when you drive off")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            HStack(alignment: .top) {
                let distance = Format.distanceParts(tracker.activeDistance, miles: useMiles)
                StatView(title: "Distance", value: distance.value, unit: distance.unit, valueFont: .largeTitle)
                Spacer()
                StatView(
                    title: "Driving",
                    value: Format.clock((tracker.pausedSince ?? .now).timeIntervalSince(tracker.activeTimerStart ?? .now)),
                    alignment: .trailing,
                    valueFont: .largeTitle
                )
            }
            HStack(spacing: 10) {
                Button {
                    tracker.resumeTrip()
                } label: {
                    Label("Resume", systemImage: "play.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                endTripButton
            }
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    private var recordingNote: LocalizedStringKey {
        if tracker.stopCheckDeadline != nil { return "Not moving" }
        if tracker.isManualTrip { return "Manual trip" }
        if tracker.isHeldInTraffic { return "Stopped in traffic · still recording" }
        if tracker.isContinuedTrip { return "Continuing last trip" }
        return "Ends when you park"
    }

    private var idlePanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            DetectionStatusRow()
            if let last = lastTrips.first {
                Divider()
                HStack(spacing: 12) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Last trip").font(.caption).foregroundStyle(.secondary)
                        Text(last.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(Format.distance(last.distance, miles: useMiles)).font(.subheadline.weight(.semibold)).monospacedDigit()
                        Text(last.startDate.formatted(.relative(presentation: .named)))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if let trip = tracker.continuableTrip {
                Button {
                    tracker.continueTrip(trip)
                } label: {
                    Label("Continue Last Trip", systemImage: "arrow.uturn.forward")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
                .disabled(!tracker.canStartManualTrip)
                .transition(.blurReplace)
            }
            Button {
                tracker.startManualTrip()
            } label: {
                Label("Start Trip Now", systemImage: "record.circle")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!tracker.canStartManualTrip)
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }
}

/// "Paused · 12:34" label; the time counts up.
private struct PausedBadge: View {
    let since: Date

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "pause.fill")
                .font(.system(size: 9))
            Text("Paused")
                .font(.footnote.weight(.bold))
                .textCase(.uppercase)
            Text(timerInterval: since...Date.distantFuture, countsDown: false)
                .font(.footnote.weight(.semibold))
                .monospacedDigit()
        }
        .foregroundStyle(.orange)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.orange.opacity(0.14), in: Capsule())
    }
}

/// "● Recording" label with a softly pulsing dot.
private struct RecordingBadge: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "circle.fill")
                .font(.system(size: 9))
                .symbolEffect(.pulse)
            Text("Recording")
                .font(.footnote.weight(.bold))
                .textCase(.uppercase)
        }
        .foregroundStyle(.red)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.red.opacity(0.14), in: Capsule())
    }
}

/// What automatic detection is doing right now, shown at the top of the idle card.
private struct DetectionStatusRow: View {
    @Environment(TripTracker.self) private var tracker
    @AppStorage(Prefs.autoDetectKey) private var autoDetect = true
    @AppStorage(Prefs.minTripDistanceKey) private var minTripDistance = Prefs.defaultMinTripDistance
    @AppStorage(Prefs.useMilesKey) private var useMiles = false

    private var isProbing: Bool { tracker.mode == .probing }

    private var symbol: String {
        switch tracker.mode {
        case .off: "pause.fill"
        case .lowBattery: "battery.0percent"
        case .probing: "location.magnifyingglass"
        case .idle, .recording, .paused: "car.side.fill"
        }
    }

    private var color: Color {
        switch tracker.mode {
        case .off: .gray
        case .lowBattery: .red
        case .probing: .orange
        case .idle, .recording, .paused: .green
        }
    }

    private var title: LocalizedStringKey {
        switch tracker.mode {
        case .off: "Auto-detect is off"
        case .lowBattery: "Paused: battery low"
        case .probing: "Checking if you're driving…"
        case .idle, .recording, .paused: "Watching for drives"
        }
    }

    private var subtitle: String {
        switch tracker.mode {
        case .off:
            tracker.isAuthorized ? String(localized: "Only manual trips are recorded") : String(localized: "Location access needed")
        case .lowBattery:
            String(localized: "GPS is off until you charge your phone")
        case .probing:
            tracker.statusDetail
        case .idle, .recording, .paused:
            tracker.hasAlwaysPermission
                ? String(localized: "Drives over \(Format.distance(minTripDistance, miles: useMiles)) save automatically")
                : String(localized: "Only while Routak is open")
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(color)
                .symbolEffect(.pulse, isActive: isProbing)
                .frame(width: 36, height: 36)
                .contentTransition(.symbolEffect(.replace))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if tracker.mode == .off, tracker.isAuthorized {
                Button("Turn On") {
                    autoDetect = true
                    tracker.settingsChanged()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .animation(.snappy, value: tracker.mode)
    }
}

struct PermissionCard: View {
    @Environment(TripTracker.self) private var tracker

    private var message: LocalizedStringKey {
        if !tracker.isAuthorized {
            return "Allow location access so Routak can record your drives."
        }
        if !tracker.hasAlwaysPermission {
            return "Set location to “Always” so drives are detected in the background."
        }
        return "Turn on Precise Location for accurate routes."
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "location.circle.fill")
                .font(.title)
                .foregroundStyle(.orange)
            Text(message)
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(tracker.authorization == .notDetermined ? "Allow" : "Fix") {
                tracker.requestPermission()
            }
            .buttonStyle(.bordered)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}
