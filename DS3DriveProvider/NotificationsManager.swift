import Foundation
import os.log
import DS3Lib

final class NotificationManager: Sendable {
    private let logger: Logger = Logger(subsystem: LogSubsystem.provider, category: LogCategory.extension.rawValue)

    private let drive: DS3Drive
    private let queue = DispatchQueue(label: "io.cubbit.DS3Drive.NotificationManager")

    // Manually synchronized via `queue`
    nonisolated(unsafe) private var _driveStatus: DS3DriveStatus
    nonisolated(unsafe) private var _debounceWorkItem: DispatchWorkItem?
    nonisolated(unsafe) private var _lastTransferSpeedTime: DispatchTime = .now()
    nonisolated(unsafe) private var _pendingTransferStats: DriveTransferStats?
    nonisolated(unsafe) private var _transferThrottleWorkItem: DispatchWorkItem?

    init(drive: DS3Drive) {
        self.drive = drive
        self._driveStatus = .idle
    }

    /// Sends a notification to the app with the current status of the drive debounced. If you want to send the notification immediately, use `sendDriveChangedNotification(status: DS3DriveStatus)`
    /// - Parameter status: status to send
    func sendDriveChangedNotificationWithDebounce(status: DS3DriveStatus) {
        queue.async {
            self._debounceWorkItem?.cancel()

            let workItem = DispatchWorkItem { [weak self] in
                self?.sendDriveChangedNotification(status: status)
            }

            self._debounceWorkItem = workItem

            self.queue.asyncAfter(
                deadline: .now() + DefaultSettings.Extension.statusChangeDebounceInterval,
                execute: workItem
            )
        }
    }

    /// Sends a notification to the app with the current status of the drive. If you want to debounce the notification, use `sendDriveChangedNotificationWithDebounce(status: DS3DriveStatus)`
    /// - Parameter status: the status to send
    func sendDriveChangedNotification(status: DS3DriveStatus) {
        queue.async {
            // Cancel any pending debounced status change so it doesn't override
            // this immediate notification (e.g. a stale .idle firing during an active sync)
            self._debounceWorkItem?.cancel()
            self._debounceWorkItem = nil

            guard status != self._driveStatus else { return }

            self._driveStatus = status

            let driveStatusChange = DS3DriveStatusChange(
                driveId: self.drive.id,
                status: self._driveStatus
            )

            guard
                let encodedDriveStatusData = try? JSONEncoder().encode(driveStatusChange),
                let encodedDriveStatusString = String(data: encodedDriveStatusData, encoding: .utf8)
            else { return }

            DistributedNotificationCenter
                .default()
                .post(
                    Notification(name: .driveStatusChanged, object: encodedDriveStatusString)
                )
        }
    }

    func sendTransferSpeedNotification(_ transferSpeed: DriveTransferStats) {
        queue.async {
            let throttle = DefaultSettings.Extension.transferSpeedThrottleInterval
            let now = DispatchTime.now()

            self._pendingTransferStats = transferSpeed

            let elapsed = Double(now.uptimeNanoseconds - self._lastTransferSpeedTime.uptimeNanoseconds) / 1_000_000_000
            if elapsed >= throttle {
                self._postTransferStats(transferSpeed)
                self._lastTransferSpeedTime = now
                self._transferThrottleWorkItem?.cancel()
                self._transferThrottleWorkItem = nil
            } else if self._transferThrottleWorkItem == nil {
                // Schedule a trailing send so the last update always gets through
                let remaining = throttle - elapsed
                let workItem = DispatchWorkItem { [weak self] in
                    guard let self, let pending = self._pendingTransferStats else { return }
                    self._postTransferStats(pending)
                    self._lastTransferSpeedTime = .now()
                    self._pendingTransferStats = nil
                    self._transferThrottleWorkItem = nil
                }
                self._transferThrottleWorkItem = workItem
                self.queue.asyncAfter(deadline: .now() + remaining, execute: workItem)
            }
        }
    }

    private func _postTransferStats(_ stats: DriveTransferStats) {
        guard
            let data = try? JSONEncoder().encode(stats),
            let string = String(data: data, encoding: .utf8)
        else { return }

        DistributedNotificationCenter
            .default()
            .post(Notification(name: .driveTransferStats, object: string))
    }

    /// Sends an auth failure notification to the main app via DistributedNotificationCenter.
    /// Called when the extension's token refresh or API key self-healing fails.
    /// - Parameters:
    ///   - domainId: The File Provider domain identifier
    ///   - reason: A machine-readable reason string (e.g. "tokenRefreshFailed", "apiKeySelfHealingFailed")
    func sendAuthFailureNotification(domainId: String, reason: String) {
        queue.async {
            DistributedNotificationCenter.default().postNotificationName(
                NSNotification.Name(DefaultSettings.Notifications.authFailure),
                object: domainId,
                userInfo: ["reason": reason],
                deliverImmediately: true
            )
            self.logger.warning("Auth failure notification sent: \(reason, privacy: .public)")
        }
    }

    func sendConflictNotification(filename: String, conflictKey: String) {
        queue.async {
            let info = ConflictInfo(
                driveId: self.drive.id,
                originalFilename: filename,
                conflictKey: conflictKey
            )

            guard let data = try? JSONEncoder().encode(info),
                  let string = String(data: data, encoding: .utf8) else {
                self.logger.error("Failed to encode conflict notification for \(filename, privacy: .public)")
                return
            }

            DistributedNotificationCenter
                .default()
                .post(Notification(name: .conflictDetected, object: string))

            self.logger.info("Conflict notification sent for \(filename, privacy: .public)")
        }
    }
}
