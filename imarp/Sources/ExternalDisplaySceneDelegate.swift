import UIKit

/// The connected external display: canvas only, no chrome.
class ExternalDisplaySceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = ExternalDisplayViewController()
        window.makeKeyAndVisible()
        self.window = window
        DebugLog.write("external", "scene connected, screen \(windowScene.screen.bounds.size) @\(windowScene.screen.scale)x")
    }

    // Lifecycle, for the log: going to the background and back (and the
    // external display coming and going) is when the screens can part ways.
    func sceneDidDisconnect(_ scene: UIScene) { DebugLog.write("external", "scene disconnected") }
    func sceneDidBecomeActive(_ scene: UIScene) { DebugLog.write("external", "scene active") }
    func sceneWillResignActive(_ scene: UIScene) { DebugLog.write("external", "scene resigning active") }
    func sceneDidEnterBackground(_ scene: UIScene) { DebugLog.write("external", "scene in background") }
    func sceneWillEnterForeground(_ scene: UIScene) { DebugLog.write("external", "scene entering foreground") }
}
