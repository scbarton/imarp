import UIKit

/// The iPad's own screen: toolbar + interactive canvas.
class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = MainViewController()
        window.makeKeyAndVisible()
        self.window = window
        DebugLog.write("ipad", "scene connected")
    }

    // Lifecycle, for the log: going to the background and back (and the
    // external display coming and going) is when the screens can part ways.
    func sceneDidDisconnect(_ scene: UIScene) { DebugLog.write("ipad", "scene disconnected") }
    func sceneDidBecomeActive(_ scene: UIScene) { DebugLog.write("ipad", "scene active") }
    func sceneWillResignActive(_ scene: UIScene) { DebugLog.write("ipad", "scene resigning active") }
    func sceneDidEnterBackground(_ scene: UIScene) { DebugLog.write("ipad", "scene in background") }
    func sceneWillEnterForeground(_ scene: UIScene) { DebugLog.write("ipad", "scene entering foreground") }
}
