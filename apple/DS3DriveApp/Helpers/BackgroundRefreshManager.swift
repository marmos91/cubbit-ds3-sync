#if os(iOS)
    import BackgroundTasks
    import DS3Lib
    @preconcurrency import FileProvider
    import Foundation
    import os.log

    /// Helper for Background App Refresh scheduling and drive signaling.
    /// Schedules a periodic ~30-min BGAppRefreshTask and signals all active
    /// File Provider drives to check for remote changes.
    enum BackgroundRefreshManager {
        static let taskIdentifier = "io.cubbit.DS3Drive.refreshDrives"
        private static let logger = Logger(subsystem: "io.cubbit.DS3Drive", category: "background")

        /// Submits a BGAppRefreshTaskRequest to run in approximately 30 minutes.
        /// iOS controls the actual timing based on app usage patterns.
        static func scheduleNextRefresh() {
            let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
            request.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)
            do {
                try BGTaskScheduler.shared.submit(request)
                logger.info("Scheduled background refresh for ~30 min")
            } catch {
                logger.error("Failed to schedule background refresh: \(error.localizedDescription, privacy: .public)")
            }
        }

        /// Signals all active drives to check for remote changes via the File Provider system.
        /// Loads the current drive list from disk and calls signalEnumerator for each.
        /// Returns `true` if all drives were signaled successfully.
        @discardableResult
        static func signalAllDrives() async -> Bool {
            let drives = DS3DriveManager.loadFromDiskOrCreateNew()
            var allSucceeded = true
            for drive in drives {
                let domain = NSFileProviderDomain(
                    identifier: NSFileProviderDomainIdentifier(rawValue: drive.id.uuidString),
                    displayName: drive.name
                )
                do {
                    try await NSFileProviderManager(for: domain)?.signalEnumerator(for: .workingSet)
                    logger.debug("Signaled enumerator for drive \(drive.name, privacy: .public)")
                } catch {
                    logger
                        .error(
                            "Failed to signal enumerator for \(drive.name, privacy: .public): \(error.localizedDescription, privacy: .public)"
                        )
                    allSucceeded = false
                }
            }
            return allSucceeded
        }
    }
#endif
