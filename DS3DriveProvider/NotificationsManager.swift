import Foundation
import os.log
import DS3Lib

final class NotificationManager: Sendable {
    private let logger: Logger = Logger(subsystem: LogSubsystem.provider, category: LogCategory.extension.rawValue)

    private let drive: DS3Drive
    private let ipcService: any IPCService
    private let queue = DispatchQueue(label: "io.cubbit.DS3Drive.NotificationManager")

    // Manually synchronized via `queue`
    nonisolated(unsafe) private var _driveStatus: DS3DriveStatus
    nonisolated(unsafe) private var _debounceWorkItem: DispatchWorkItem?
    nonisolated(unsafe) private var _lastTransferSpeedTime: DispatchTime = .init(uptimeNanoseconds: 0)
    nonisolated(unsafe) private var _pendingTransferStats: DriveTransferStats?
    nonisolated(unsafe) private var _transferThrottleWorkItem: DispatchWorkItem?

    /// Tracks the number of in-flight file operations (fetch, create, modify, delete).
    /// Each immediate `.sync` increments; each debounced `.idle`/`.error` decrements.
    /// Idle transitions are suppressed while > 0, preventing rapid sync↔idle flashing.
    nonisolated(unsafe) private var _activeOperations: Int = 0

    init(drive: DS3Drive, ipcService: (any IPCService)? = nil) {
        self.drive = drive
        self._driveStatus = .idle
        self.ipcService = ipcService ?? makeDefaultIPCService()
    }

    /// Sends a notification to the app with the current status of the drive debounced. If you want to send the notification immediately, use `sendDriveChangedNotification(status: DS3DriveStatus)`
    /// - Parameters:
    ///   - status: status to send
    ///   - isFileOperation: whether this call is the completion of a file operation (fetch/create/modify/delete)
    ///     that was previously tracked with an immediate `.sync`. Only file-operation completions should
    ///     decrement the active operations counter. Enumerator status updates should pass `false`.
    func sendDriveChangedNotificationWithDebounce(status: DS3DriveStatus, isFileOperation: Bool = true) {
        queue.async {
            if isFileOperation && self._activeOperations > 0 && (status == .idle || status == .error) {
                self._activeOperations -= 1
            }

            // While file operations are still active, suppress idle/error debounce
            // so the status stays on .sync until all operations finish.
            if isFileOperation && self._activeOperations > 0 {
                self._debounceWorkItem?.cancel()
                self._debounceWorkItem = nil
                return
            }

            self._debounceWorkItem?.cancel()

            let workItem = DispatchWorkItem { [weak self] in
                self?._sendStatusNotification(status: status)
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
            self._debounceWorkItem?.cancel()
            self._debounceWorkItem = nil

            if status == .sync {
                self._activeOperations += 1
            }

            if status == .idle && self._activeOperations > 0 {
                return
            }

            self._sendStatusNotification(status: status)
        }
    }

    /// Posts the status change notification if the status actually changed.
    private func _sendStatusNotification(status: DS3DriveStatus) {
        guard status != self._driveStatus else { return }

        self._driveStatus = status

        let driveStatusChange = DS3DriveStatusChange(
            driveId: self.drive.id,
            status: self._driveStatus
        )

        Task { [ipcService] in
            await ipcService.postStatusChange(driveStatusChange)
        }
    }

    func sendTransferSpeedNotification(_ transferSpeed: DriveTransferStats) {
        queue.async {
            let throttle = DefaultSettings.Extension.transferSpeedThrottleInterval
            let now = DispatchTime.now()

            self._pendingTransferStats = transferSpeed

            let elapsedNanos = now.uptimeNanoseconds - self._lastTransferSpeedTime.uptimeNanoseconds
            let elapsed = Double(elapsedNanos) / 1_000_000_000

            if elapsed >= throttle {
                self._postTransferStats(transferSpeed)
                self._lastTransferSpeedTime = now
                self._transferThrottleWorkItem?.cancel()
                self._transferThrottleWorkItem = nil
                return
            }

            if self._transferThrottleWorkItem != nil {
                return
            }

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

    private func _postTransferStats(_ stats: DriveTransferStats) {
        Task { [ipcService] in
            await ipcService.postTransferStats(stats)
        }
    }

    /// Sends an auth failure notification to the main app via IPCService.
    /// Called when the extension's token refresh or API key self-healing fails.
    /// - Parameters:
    ///   - domainId: The File Provider domain identifier
    ///   - reason: A machine-readable reason string (e.g. "tokenRefreshFailed", "apiKeySelfHealingFailed")
    func sendAuthFailureNotification(domainId: String, reason: String) {
        queue.async {
            Task { [ipcService = self.ipcService] in
                await ipcService.postAuthFailure(domainId: domainId, reason: reason)
            }
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

            Task { [ipcService = self.ipcService] in
                await ipcService.postConflict(info)
            }

            self.logger.info("Conflict notification sent for \(filename, privacy: .public)")
        }
    }
}
