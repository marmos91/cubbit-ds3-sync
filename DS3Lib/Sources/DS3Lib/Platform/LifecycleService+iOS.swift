#if os(iOS)
import Foundation

final class IOSLifecycleService: LifecycleService {
    var isAutoLaunchEnabled: Bool {
        // iOS manages background refresh through Settings > General > Background App Refresh
        // We cannot query the exact state programmatically in the extension context
        true
    }

    func setAutoLaunch(_ enabled: Bool) throws {
        // BGAppRefreshTask registration happens at app launch.
        // User controls via Settings > General > Background App Refresh.
        // This is a no-op since we cannot programmatically toggle it.
    }
}
#endif
