#if os(iOS)
    import DS3Lib
    import Foundation
    import Network

    /// Decides whether thumbnail downloads are allowed given current network conditions.
    /// Cellular is blocked by default; user can opt in via Settings.
    final class ThumbnailNetworkPolicy: @unchecked Sendable {
        static let shared = ThumbnailNetworkPolicy()

        private let monitor = NWPathMonitor()
        private let monitorQueue = DispatchQueue(label: "io.cubbit.DS3Drive.thumbnailNetworkMonitor")
        private var currentPath: NWPath?

        var cellularOptIn: Bool {
            get {
                UserDefaults(suiteName: DefaultSettings.appGroup)?
                    .bool(forKey: DefaultSettings.UserDefaultsKeys.thumbnailCellularOptIn) ?? false
            }
            set {
                UserDefaults(suiteName: DefaultSettings.appGroup)?
                    .set(newValue, forKey: DefaultSettings.UserDefaultsKeys.thumbnailCellularOptIn)
            }
        }

        private init() {
            monitor.pathUpdateHandler = { [weak self] path in
                self?.currentPath = path
            }
            monitor.start(queue: monitorQueue)
        }

        /// Returns true when thumbnail downloads should proceed.
        /// Wi-Fi: always allowed. Cellular: only when user has opted in.
        func isAllowed() -> Bool {
            guard let path = currentPath, path.status == .satisfied else {
                return true // No path yet — fail open (don't block drain on startup)
            }
            if path.isExpensive {
                return cellularOptIn
            }
            return true
        }
    }
#endif
