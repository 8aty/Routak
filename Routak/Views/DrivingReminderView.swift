import SwiftUI
import UIKit

/// Covers the app while the car is moving, so a driver isn't tempted to look at it.
/// Kept to a few big words and one button; a passenger can tap past it.
struct DrivingReminderView: View {
    var onPassenger: () -> Void

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.background)
                .ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer()
                Image(systemName: "road.lanes")
                    .font(.system(size: 64, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                Text("Eyes on the road")
                    .font(.largeTitle.bold())
                    .multilineTextAlignment(.center)
                Text("Routak records this trip by itself.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Spacer()
                Button(action: onPassenger) {
                    Text("I'm a passenger")
                        .font(.title3.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 24)
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .transition(.opacity)
    }
}

/// Shows the reminder in its own window above everything else, including sheets and the keyboard.
@MainActor
final class DrivingReminderWindow {
    static let shared = DrivingReminderWindow()
    private var window: UIWindow?

    var isShown: Bool { window != nil }

    func show(onPassenger: @escaping () -> Void) {
        guard window == nil else { return }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else { return }
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        let host = UIHostingController(rootView: DrivingReminderView(onPassenger: onPassenger))
        host.view.backgroundColor = .clear
        window.rootViewController = host
        window.alpha = 0
        window.makeKeyAndVisible()
        UIView.animate(withDuration: 0.25) { window.alpha = 1 }
        self.window = window
    }

    func hide() {
        guard let window else { return }
        self.window = nil
        UIView.animate(withDuration: 0.2) {
            window.alpha = 0
        } completion: { _ in
            window.isHidden = true
            window.windowScene?.windows.first { $0 !== window && !$0.isHidden }?.makeKey()
        }
    }
}
