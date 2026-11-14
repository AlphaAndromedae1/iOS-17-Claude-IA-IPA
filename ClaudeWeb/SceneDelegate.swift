import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }

        let window = ShakeWindow(windowScene: windowScene)
        window.tintColor = .accent
        window.backgroundColor = .appBackground
        window.rootViewController = WebViewController()
        window.makeKeyAndVisible()
        self.window = window
    }
}

extension Notification.Name {
    static let deviceDidShake = Notification.Name("DeviceDidShake")
}

/// Shakes travel up the responder chain and end at the window whether or not the
/// page has focus, so this is the one place that reliably sees every shake.
final class ShakeWindow: UIWindow {
    override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        if motion == .motionShake {
            NotificationCenter.default.post(name: .deviceDidShake, object: self)
        }
        super.motionEnded(motion, with: event)
    }
}
