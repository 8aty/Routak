import SwiftData
import SwiftUI
import UserNotifications

@main
struct RoutakApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(TripTracker.shared)
        }
        .modelContainer(Persistence.container)
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        Prefs.register()
        UNUserNotificationCenter.current().delegate = self
        // Must be set up on every launch: iOS relaunches the app in the background
        // for location events (significant changes, visits, geofence exits).
        TripTracker.shared.configure(container: Persistence.container)
        // The End Trip button on the Lock Screen and the Siri/Shortcuts action run here, in the app.
        TripIntentHandlers.endTrip = {
            guard TripTracker.shared.hasOpenTrip else { return false }
            TripTracker.shared.stopTrip()
            return true
        }
        TripIntentHandlers.pauseTrip = {
            guard TripTracker.shared.canPause else { return false }
            TripTracker.shared.pauseTrip()
            return true
        }
        TripIntentHandlers.resumeTrip = {
            guard TripTracker.shared.mode == .paused else { return false }
            TripTracker.shared.resumeTrip()
            return true
        }
        return true
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    /// The buttons on "Still driving?".
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let action = response.actionIdentifier
        await MainActor.run { TripTracker.shared.handleStopCheckAction(action) }
    }
}
