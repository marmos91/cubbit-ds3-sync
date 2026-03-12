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
            guard
                let encodedTransferSpeedData = try? JSONEncoder().encode(transferSpeed),
                let encodedTransferSpeedString = String(data: encodedTransferSpeedData, encoding: .utf8)
            else { return }

            DistributedNotificationCenter
                .default()
                .post(
                    Notification(name: .driveTransferStats, object: encodedTransferSpeedString)
                )
        }
    }

    func sendConflictNotification(filename: String, conflictKey: String, driveId: UUID) {
        queue.async {
            let info = ConflictInfo(
                driveId: driveId,
                originalFilename: filename,
                conflictKey: conflictKey
            )

            guard let data = try? JSONEncoder().encode(info),
                  let string = String(data: data, encoding: .utf8) else {
                self.logger.error("Failed to encode conflict notification")
                return
            }

            DistributedNotificationCenter
                .default()
                .post(Notification(name: .conflictDetected, object: string))

            self.logger.info("Conflict notification sent for \(filename, privacy: .public)")
        }
    }
}
