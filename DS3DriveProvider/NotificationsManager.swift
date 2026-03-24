import DS3Lib
import Foundation
import os.log

actor NotificationManager {
    private let logger: Logger = .init(subsystem: LogSubsystem.provider, category: LogCategory.extension.rawValue)

    private let drive: DS3Drive
    private let ipcService: any IPCService

    private var driveStatus: DS3DriveStatus
    private var debounceTask: Task<Void, Never>?
    private var lastTransferSpeedTime: ContinuousClock.Instant = .now - .seconds(999)
    private var pendingTransferStats: DriveTransferStats?
    private var transferThrottleTask: Task<Void, Never>?
    private var lastAuthFailureTime: ContinuousClock.Instant = .now - .seconds(999)

    /// Tracks the number of in-flight file operations (fetch, create, modify, delete).
    /// Each immediate `.sync` increments; each debounced `.idle`/`.error` decrements.
    /// Idle transitions are suppressed while > 0, preventing rapid sync-idle flashing.
    private var activeOperations: Int = 0

    init(drive: DS3Drive, ipcService: (any IPCService)? = nil) {
        self.drive = drive
        self.driveStatus = .idle
        self.ipcService = ipcService ?? makeDefaultIPCService()
    }

    /// Sends a notification to the app with the current status of the drive debounced. If you want to send the
    /// notification immediately, use `sendDriveChangedNotification(status: DS3DriveStatus)`
    /// - Parameters:
    ///   - status: status to send
    ///   - isFileOperation: whether this call is the completion of a file operation (fetch/create/modify/delete)
    ///     that was previously tracked with an immediate `.sync`. Only file-operation completions should
    ///     decrement the active operations counter. Enumerator status updates should pass `false`.
    func sendDriveChangedNotificationWithDebounce(status: DS3DriveStatus, isFileOperation: Bool = true) {
        if isFileOperation, activeOperations > 0, status == .idle || status == .error {
            activeOperations -= 1
        }

        // While file operations are still active, suppress idle/error from ANY source
        // (including enumerator) so the status stays on .sync until all operations finish.
        if activeOperations > 0, status == .idle || status == .error {
            debounceTask?.cancel()
            debounceTask = nil
            return
        }

        debounceTask?.cancel()

        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(DefaultSettings.Extension.statusChangeDebounceInterval))
            guard !Task.isCancelled else { return }
            await self?.postStatusNotification(status: status)
        }
    }

    /// Sends a notification to the app with the current status of the drive. If you want to debounce the notification,
    /// use `sendDriveChangedNotificationWithDebounce(status: DS3DriveStatus)`
    /// - Parameter status: the status to send
    func sendDriveChangedNotification(status: DS3DriveStatus) {
        debounceTask?.cancel()
        debounceTask = nil

        if status == .sync {
            activeOperations += 1
        }

        if status == .idle, activeOperations > 0 {
            return
        }

        postStatusNotification(status: status)
    }

    /// Posts the status change notification if the status actually changed.
    private func postStatusNotification(status: DS3DriveStatus) {
        guard status != driveStatus else { return }

        driveStatus = status

        let driveStatusChange = DS3DriveStatusChange(
            driveId: drive.id,
            status: status
        )

        Task { [ipcService] in
            await ipcService.postStatusChange(driveStatusChange)
        }
    }

    func sendTransferSpeedNotification(_ transferSpeed: DriveTransferStats) {
        let throttle = DefaultSettings.Extension.transferSpeedThrottleInterval
        let now = ContinuousClock.now

        pendingTransferStats = transferSpeed

        let elapsed = now - lastTransferSpeedTime
        let elapsedSeconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18

        if elapsedSeconds >= throttle {
            postTransferStats(transferSpeed)
            lastTransferSpeedTime = now
            transferThrottleTask?.cancel()
            transferThrottleTask = nil
            return
        }

        if transferThrottleTask != nil {
            return
        }

        let remaining = throttle - elapsedSeconds
        transferThrottleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(remaining))
            guard !Task.isCancelled else { return }
            guard let self else { return }
            guard let pending = await self.getPendingTransferStats() else { return }
            await self.flushTransferStats(pending)
        }
    }

    /// Helper to read pending stats from within the throttle task.
    private func getPendingTransferStats() -> DriveTransferStats? {
        pendingTransferStats
    }

    /// Helper to flush pending stats and reset throttle state.
    private func flushTransferStats(_ stats: DriveTransferStats) {
        postTransferStats(stats)
        lastTransferSpeedTime = .now
        pendingTransferStats = nil
        transferThrottleTask = nil
    }

    private func postTransferStats(_ stats: DriveTransferStats) {
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
        let now = ContinuousClock.now
        let elapsed = now - lastAuthFailureTime
        let elapsedSeconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18

        if elapsedSeconds < DefaultSettings.Extension.authFailureCooldownSeconds {
            logger
                .info(
                    "Auth failure notification suppressed (cooldown): domain=\(domainId, privacy: .public), reason=\(reason, privacy: .public)"
                )
            return
        }

        lastAuthFailureTime = now

        Task { [ipcService] in
            await ipcService.postAuthFailure(domainId: domainId, reason: reason)
        }
        logger.warning("Auth failure notification sent: \(reason, privacy: .public)")
    }

    func sendConflictNotification(filename: String, conflictKey: String) {
        let info = ConflictInfo(
            driveId: drive.id,
            originalFilename: filename,
            conflictKey: conflictKey
        )

        Task { [ipcService] in
            await ipcService.postConflict(info)
        }

        logger.info("Conflict notification sent for \(filename, privacy: .public)")
    }
}
