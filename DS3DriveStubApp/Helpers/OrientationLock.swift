#if os(iOS)
import UIKit
import BackgroundTasks

/// App delegate that locks iPhone to portrait orientation while allowing all orientations on iPad.
/// Also registers the BGTaskScheduler handler for background app refresh.
/// Used via `@UIApplicationDelegateAdaptor(AppDelegate.self)` in the SwiftUI App struct.
class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: BackgroundRefreshManager.taskIdentifier,
            using: nil
        ) { task in
            guard let refreshTask = task as? BGAppRefreshTask else { return }
            Task {
                await BackgroundRefreshManager.signalAllDrives()
                refreshTask.setTaskCompleted(success: true)
                BackgroundRefreshManager.scheduleNextRefresh()
            }
        }
        return true
    }

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
