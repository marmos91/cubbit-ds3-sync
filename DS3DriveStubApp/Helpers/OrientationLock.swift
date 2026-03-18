#if os(iOS)
import UIKit

/// App delegate that locks iPhone to portrait orientation while allowing all orientations on iPad.
/// Used via `@UIApplicationDelegateAdaptor(AppDelegate.self)` in the SwiftUI App struct.
class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        if UIDevice.current.userInterfaceIdiom == .phone {
            return .portrait
        } else {
            return .all
        }
    }
}
#endif
