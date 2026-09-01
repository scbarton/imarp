import UIKit

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        // The external-display branch only fires on iOS 17–26. On iOS 27+ the
        // scene accessory supplies its own configuration (with its delegate
        // class set directly), so this method isn't consulted for that scene.
        switch connectingSceneSession.role {
        case .windowExternalDisplayNonInteractive:
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

/// Claiming the external display — see `MainViewController`'s
/// `registerExternalDisplayAccessory()`, which is where it actually happens.
///
/// Worth recording, because the Info.plist looks like it should be enough and
/// isn't: as of iOS 27 an app is offered a `.windowExternalDisplayNonInteractive`
/// scene *only* if it registers a `UISceneAccessory`. Declaring the scene in the
/// Info.plist and checking the role in `configurationForConnecting` is the
/// pre-27 pattern, kept below solely for iOS 17–26; on 27 the scene simply never
/// connects, and asking for the role explicitly via
/// `UISceneSessionActivationRequest` fails with "the requested role … is not
/// supported".
///
/// Two dead ends, so they don't get retried: `UIScreen.didConnectNotification`
/// can't work while the display is mirroring (there is no second `UIScreen` —
/// `UIScreen.screens.count` stays 1), and `UIRequiresFullScreen` is unrelated.
enum ExternalDisplay {
    /// True once the system has actually given us an external display scene.
    static var isActive: Bool {
        UIApplication.shared.connectedScenes.contains {
            $0.session.role == .windowExternalDisplayNonInteractive
        }
    }

}
