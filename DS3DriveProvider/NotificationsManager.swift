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
    ///
    /// Serialization is provided by the surrounding `actor`, so no separate
    /// lock is required — this is the `counterLock` referenced by Gap 15.
    private var activeOperations: Int = 0

    /// Tracks whether any operation in the current batch completed with an error.
    /// When `activeOperations` reaches 0, the final status is `.error` instead of `.idle`
    /// if this flag is set. Reset when a new batch starts (activeOperations goes from 0 to 1).
    private var batchHadError: Bool = false

    /// Last time `activeOperations` changed. Used by `resetCounterIfQuiescent`
    /// to detect a leak: if the counter has been > 0 for > 30s without any
    /// activity, the watchdog clamps it back to 0 and logs a warning.
    private var lastCounterMutationTime: ContinuousClock.Instant = .now

    /// Repeating watchdog task spawned at init. Cancelled in `shutdown` (best
    /// effort — actor isolation guarantees the task observes the latest state).
    private var counterWatchdogTask: Task<Void, Never>?

    init(drive: DS3Drive, ipcService: (any IPCService)? = nil) {
        self.drive = drive
        self.driveStatus = .idle
        self.ipcService = ipcService ?? makeDefaultIPCService()
        Task { [weak self] in await self?.startCounterWatchdog() }
    }

    /// Sends a notification to the app with the current status of the drive debounced. If you want to send the
    /// notification immediately, use `sendDriveChangedNotification(status: DS3DriveStatus)`
    /// - Parameters:
    ///   - status: status to send
    ///   - isFileOperation: whether this call is the completion of a file operation (fetch/create/modify/delete)
    ///     that was previously tracked with an immediate `.sync`. Only file-operation completions should
    ///     decrement the active operations counter. Enumerator status updates should pass `false`.
    func sendDriveChangedNotificationWithDebounce(status: DS3DriveStatus, isFileOperation: Bool = true) {
        // Track errors so we can report the correct final status when the batch finishes
        if isFileOperation, status == .error {
            batchHadError = true
        }

        if isFileOperation, status == .idle || status == .error {
            // Clamp-to-zero invariant: if a decrement would push the counter
            // below zero, the upstream notifications got out of balance
            // (Gap 15). Log it and clamp instead of crashing or wrapping.
            if activeOperations > 0 {
                activeOperations -= 1
                lastCounterMutationTime = .now
            } else {
                logger
                    .warning(
                        "NotificationManager counter leak detected: decrement attempted at 0 (status=\(status.rawValue, privacy: .public))"
                    )
            }
        }

        // While file operations are still active, suppress idle/error from ANY source
        // (including enumerator) so the status stays on .sync until all operations finish.
        if activeOperations > 0, status == .idle || status == .error {
            debounceTask?.cancel()
            debounceTask = nil
            return
        }

        // When all operations complete and any had an error, report .error
        // even if the last operation itself succeeded with .idle.
        let effectiveStatus: DS3DriveStatus = if activeOperations == 0, status == .idle, batchHadError {
            .error
        } else {
            status
        }

        // Reset batch error tracking when all operations are done
        if activeOperations == 0 {
            batchHadError = false
        }

        debounceTask?.cancel()

        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(DefaultSettings.Extension.statusChangeDebounceInterval))
            guard !Task.isCancelled else { return }
            await self?.postStatusNotification(status: effectiveStatus)
        }
    }

    /// Sends a notification to the app with the current status of the drive. If you want to debounce the notification,
    /// use `sendDriveChangedNotificationWithDebounce(status: DS3DriveStatus)`
    /// - Parameter status: the status to send
    func sendDriveChangedNotification(status: DS3DriveStatus) {
        debounceTask?.cancel()
        debounceTask = nil

        if status == .sync {
            // Reset batch error tracking when starting a new batch (first operation)
            if activeOperations == 0 {
                batchHadError = false
            }
            activeOperations += 1
            lastCounterMutationTime = .now
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

    // MARK: - Counter Watchdog (Gap 15)

    /// Spawns a repeating task that periodically calls
    /// `resetCounterIfQuiescent` so a phantom `.indexing`/`.sync` state cannot
    /// stick after the upstream notifications stop arriving.
    private func startCounterWatchdog() {
        counterWatchdogTask?.cancel()
        counterWatchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                await self?.resetCounterIfQuiescent()
            }
        }
    }

    /// If `activeOperations` has been > 0 with no mutation for at least 30
    /// seconds, force the counter back to 0 and emit an `.idle` notification
    /// so the tray recovers from a counter leak.
    func resetCounterIfQuiescent() {
        guard activeOperations > 0 else { return }

        let elapsed = ContinuousClock.now - lastCounterMutationTime
        let elapsedSeconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        guard elapsedSeconds >= 30 else { return }

        logger
            .warning(
                "NotificationManager counter watchdog: clamping leaked counter from \(self.activeOperations, privacy: .public) to 0 after \(elapsedSeconds, privacy: .public)s of inactivity"
            )

        activeOperations = 0
        batchHadError = false
        lastCounterMutationTime = .now
        postStatusNotification(status: .idle)
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
