import UIKit

@main
class AppDelegate: UIResponder, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        switch connectingSceneSession.role {
        case .windowExternalDisplay:
            return UISceneConfiguration(
                name: "External Display Configuration",
                sessionRole: connectingSceneSession.role
            )
        default:
            return UISceneConfiguration(
                name: "Default Configuration",
                sessionRole: connectingSceneSession.role
            )
        }
    }
}
