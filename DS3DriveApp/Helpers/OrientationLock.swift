#if os(iOS)
    import UIKit

    /// App delegate that locks iPhone to portrait orientation while allowing all orientations on iPad.
    /// Background refresh is handled by the SwiftUI `.backgroundTask` modifier in DS3DriveApp.
    /// Used via `@UIApplicationDelegateAdaptor(AppDelegate.self)` in the SwiftUI App struct.
    class AppDelegate: NSObject, UIApplicationDelegate {
        func application(
            _ application: UIApplication,
            supportedInterfaceOrientationsFor window: UIWindow?
        ) -> UIInterfaceOrientationMask {
            if UIDevice.current.userInterfaceIdiom == .phone {
                .portrait
            } else {
                .all
            }
        }
    }
#endif
