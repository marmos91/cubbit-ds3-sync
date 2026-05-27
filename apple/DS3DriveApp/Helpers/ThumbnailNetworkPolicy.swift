#if os(iOS)
    import DS3Lib
    import Foundation
    import Network
    import os.lock

    /// Decides whether thumbnail downloads are allowed given current network conditions.
    /// Cellular is blocked by default; user can opt in via Settings.
    final class ThumbnailNetworkPolicy: @unchecked Sendable {
        static let shared = ThumbnailNetworkPolicy()

        private let monitor = NWPathMonitor()
        private let monitorQueue = DispatchQueue(label: "io.cubbit.DS3Drive.thumbnailNetworkMonitor")
        /// `currentPath` is mutated from the NWPathMonitor callback queue and
        /// read from arbitrary threads via `isAllowed()`. The lock keeps the
        /// read/write atomic under `@unchecked Sendable`.
        private let pathLock = OSAllocatedUnfairLock<NWPath?>(initialState: nil)

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
                self?.pathLock.withLock { $0 = path }
            }
            monitor.start(queue: monitorQueue)
        }

        /// Returns true when thumbnail downloads should proceed.
        /// Wi-Fi: always allowed. Cellular: only when user has opted in.
        /// Unknown path (monitor not yet delivered first update): allow only
        /// if the user has opted in to cellular — fail closed so a backfill
        /// kicked off before the first NWPath update can never hit cellular
        /// for a user who never agreed to it.
        func isAllowed() -> Bool {
            let snapshot = pathLock.withLock { $0 }
            guard let path = snapshot, path.status == .satisfied else {
                return cellularOptIn
            }
            if path.isExpensive {
                return cellularOptIn
            }
            return true
        }
    }
#endif
