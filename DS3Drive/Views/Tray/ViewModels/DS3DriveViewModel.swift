import DS3Lib
import FileProvider
import Foundation
import os.log
import SwiftData
import SwiftUI

/// Manages a drive
@Observable class DS3DriveViewModel {
    private let logger = Logger(subsystem: LogSubsystem.app, category: LogCategory.app.rawValue)

    var drive: DS3Drive
    var driveStatus: DS3DriveStatus = .idle
    var driveStats: DS3DriveStats = .init(lastUpdate: Date())

    var totalTransferredSize: Int64 = 0
    var totalTransferDuration: TimeInterval = 0
    var transferStatsResetTimer: Timer?

    /// Debounces idle transitions to prevent the tray icon from flashing
    /// between sync and idle during parallel file operations.
    private var idleDebounceTimer: Timer?

    /// Tracks the last reported cumulative size per filename to compute deltas
    private var lastReportedSize: [String: Int64] = [:]

    /// Tracks the last reported cumulative duration per filename to compute delta time
    private var lastReportedDuration: [String: TimeInterval] = [:]

    /// Per-file instantaneous speed (EMA-smoothed) to compute aggregate bandwidth, keyed by direction.
    private var perFileUploadSpeed: [String: Double] = [:]
    private var perFileDownloadSpeed: [String: Double] = [:]
    private let speedSmoothingAlpha: Double = 0.3

    /// Last update timestamp per file key, used to expire stale speed entries.
    private var lastFileUpdate: [String: Date] = [:]
    private let fileTransferTimeout: TimeInterval = 3.0

    /// Tracks recently transferred files for this drive
    var recentFilesTracker = RecentFilesTracker()

    /// Recent files for this drive, sorted by status priority.
    /// Stored property so @Observable can trigger SwiftUI view updates.
    var recentFiles: [RecentFileEntry] = []

    /// Refreshes the `recentFiles` stored property from the tracker.
    func refreshRecentFiles() {
        recentFiles = recentFilesTracker.entries(forDrive: drive.id)
    }

    init(drive: DS3Drive) {
        self.drive = drive

        // Restore paused state from persistence so it survives app restart
        if (try? SharedData.default().isDrivePaused(drive.id)) == true {
            self.driveStatus = .paused
        }

        self.setupObserver()
    }

    deinit {
        transferStatsResetTimer?.invalidate()
        idleDebounceTimer?.invalidate()
        DistributedNotificationCenter
            .default()
            .removeObserver(self)
    }

    /// Sets up the observer for the drive to listen for notifications from the extension
    private func setupObserver() {
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(DS3DriveViewModel.driveStatusChanged),
            name: .driveStatusChanged,
            object: nil,
            suspensionBehavior: .deliverImmediately
        )

        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(DS3DriveViewModel.transferSpeedReceived),
            name: .driveTransferStats,
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
    }

    /// Updates drive stats when it receives a notification from the extension
    /// - Parameter notification: the notification
    @objc @MainActor
    private func transferSpeedReceived(_ notification: Notification) {
        guard
            let stringDriveStats = notification.object as? String,
            let driveTransferStats = try? JSONDecoder().decode(
                DriveTransferStats.self,
                from: Data(stringDriveStats.utf8)
            ),
            driveTransferStats.driveId == self.drive.id // Only update if the notification is for this drive
        else { return }

        self.transferStatsResetTimer?.invalidate()
        self.processTransferStats(driveTransferStats)

        self.transferStatsResetTimer = Timer.scheduledTimer(
            withTimeInterval: DefaultSettings.Tray.driveStatsReset,
            repeats: false
        ) { [weak self] _ in
            guard let self else { return }
            self.lastReportedSize.removeAll()
            self.lastReportedDuration.removeAll()
            self.lastFileUpdate.removeAll()
            self.perFileUploadSpeed.removeAll()
            self.perFileDownloadSpeed.removeAll()
            self.totalTransferredSize = 0
            self.totalTransferDuration = 0
            self.driveStats.uploadSpeedBs = nil
            self.driveStats.downloadSpeedBs = nil
            self.driveStats.lastUpdate = Date()

            // Safety net: mark any remaining syncing entries as completed.
            // The sync→idle transition may have fired while files were still
            // transferring, leaving them stuck as .syncing in the tray.
            for entry in self.recentFilesTracker.entries(forDrive: self.drive.id) where entry.status == .syncing {
                self.recentFilesTracker.update(filename: entry.filename, driveId: self.drive.id, status: .completed)
            }
            self.refreshRecentFiles()
        }
    }

    /// Processes a single transfer stats update: computes per-file EMA speed by direction
    /// and updates aggregate stats.
    @MainActor
    private func processTransferStats(_ driveTransferStats: DriveTransferStats) {
        let fileKey = driveTransferStats.filename ?? "_default_"
        let previousSize = self.lastReportedSize[fileKey] ?? 0
        let previousDuration = self.lastReportedDuration[fileKey] ?? 0
        let deltaBytes = max(0, driveTransferStats.size - previousSize)
        let deltaDuration = driveTransferStats.duration - previousDuration
        self.lastReportedSize[fileKey] = driveTransferStats.size
        self.lastReportedDuration[fileKey] = driveTransferStats.duration
        self.lastFileUpdate[fileKey] = Date()

        self.totalTransferredSize += deltaBytes
        self.totalTransferDuration += deltaDuration

        let isUpload = driveTransferStats.direction == .upload
        if deltaDuration > 0 {
            let instantaneous = Double(deltaBytes) / deltaDuration
            if isUpload {
                let previous = self.perFileUploadSpeed[fileKey]
                self.perFileUploadSpeed[fileKey] = previous.map {
                    self.speedSmoothingAlpha * instantaneous + (1 - self.speedSmoothingAlpha) * $0
                } ?? instantaneous
            } else {
                let previous = self.perFileDownloadSpeed[fileKey]
                self.perFileDownloadSpeed[fileKey] = previous.map {
                    self.speedSmoothingAlpha * instantaneous + (1 - self.speedSmoothingAlpha) * $0
                } ?? instantaneous
            }
        }

        // Remove completed file so it doesn't inflate the total
        if let totalSize = driveTransferStats.totalSize, driveTransferStats.size >= totalSize {
            self.removeFileSpeedTracking(fileKey, isUpload: isUpload)
        }

        // Expire stale entries (files that stopped sending updates)
        self.expireInactiveFileTransfers()

        self.driveStats.uploadSpeedBs = self.perFileUploadSpeed.isEmpty
            ? nil : self.perFileUploadSpeed.values.reduce(0, +)
        self.driveStats.downloadSpeedBs = self.perFileDownloadSpeed.isEmpty
            ? nil : self.perFileDownloadSpeed.values.reduce(0, +)

        // Track in recent files
        let fileSpeed = isUpload ? self.perFileUploadSpeed[fileKey] : self.perFileDownloadSpeed[fileKey]
        if let filename = driveTransferStats.filename, !filename.isEmpty {
            let entry = RecentFileEntry(
                driveId: driveTransferStats.driveId,
                filename: filename,
                size: driveTransferStats.size,
                status: .syncing,
                timestamp: Date(),
                transferredBytes: driveTransferStats.size,
                totalBytes: driveTransferStats.totalSize,
                speed: fileSpeed
            )
            self.recentFilesTracker.add(entry)
            self.refreshRecentFiles()
        }
    }

    /// Removes a file's speed tracking data.
    private func removeFileSpeedTracking(_ fileKey: String, isUpload: Bool) {
        if isUpload {
            self.perFileUploadSpeed.removeValue(forKey: fileKey)
        } else {
            self.perFileDownloadSpeed.removeValue(forKey: fileKey)
        }
        self.lastReportedSize.removeValue(forKey: fileKey)
        self.lastReportedDuration.removeValue(forKey: fileKey)
        self.lastFileUpdate.removeValue(forKey: fileKey)
    }

    /// Removes speed tracking for files that haven't reported progress recently.
    /// This handles files whose completion notifications were throttled or dropped.
    private func expireInactiveFileTransfers() {
        let cutoff = Date().addingTimeInterval(-self.fileTransferTimeout)
        let staleKeys = self.lastFileUpdate.filter { $0.value < cutoff }.map(\.key)
        for key in staleKeys {
            self.perFileUploadSpeed.removeValue(forKey: key)
            self.perFileDownloadSpeed.removeValue(forKey: key)
            self.lastReportedSize.removeValue(forKey: key)
            self.lastReportedDuration.removeValue(forKey: key)
            self.lastFileUpdate.removeValue(forKey: key)
        }
    }

    /// Updates drive status when it receives a notification from the extension.
    /// Idle transitions are debounced by 2s to prevent the tray icon from
    /// flashing between sync and idle during parallel file operations.
    /// - Parameter notification: the notification
    @objc @MainActor
    private func driveStatusChanged(_ notification: Notification) {
        guard
            let stringDrive = notification.object as? String,
            let updateDriveStatusNotification = try? JSONDecoder().decode(
                DS3DriveStatusChange.self,
                from: Data(stringDrive.utf8)
            ),
            updateDriveStatusNotification.driveId == self.drive.id // Only update if the notification is for this drive
        else { return }

        let newStatus = updateDriveStatusNotification.status

        // While paused, ignore extension status updates (they'd be stale .idle/.error
        // from failed operations). Only allow the .paused status itself through.
        if self.driveStatus == .paused, newStatus != .paused {
            return
        }

        // Always cancel any pending idle transition
        self.idleDebounceTimer?.invalidate()
        self.idleDebounceTimer = nil

        if newStatus == .idle {
            // Debounce idle: wait 2s before applying so a new .sync arriving
            // in the window cancels this transition, preventing icon flashing.
            self.idleDebounceTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
                guard let self else { return }
                let previousStatus = self.driveStatus
                self.driveStatus = .idle

                // When transitioning from sync to idle, mark all syncing entries as completed
                if previousStatus == .sync {
                    let entries = self.recentFilesTracker.entries(forDrive: self.drive.id)
                    for entry in entries where entry.status == .syncing {
                        self.recentFilesTracker.update(
                            filename: entry.filename,
                            driveId: self.drive.id,
                            status: .completed
                        )
                    }
                    self.refreshRecentFiles()
                }
            }
        } else {
            // Apply non-idle statuses (sync, indexing, error, paused) immediately
            self.driveStatus = newStatus
        }
    }

    /// Formats the drive's sync anchor. If the prefix is defined, it will be added to the project name
    /// - Returns: the drive's sync anchor string
    func syncAnchorString() -> String {
        var name = drive.syncAnchor.project.name

        if let prefix = drive.syncAnchor.prefix {
            name += "/\(prefix)"
        }

        return name
    }

    /// Returns the Cubbit's Web Console URL
    /// - Returns: the console url
    func consoleURL() -> URL? {
        var url = "\(ConsoleURLs.projectsURL)/\(drive.syncAnchor.project.id)/buckets/\(drive.syncAnchor.bucket.name)"

        if let prefix = drive.syncAnchor.prefix {
            url += "/\(prefix)"
        }

        return URL(string: url)
    }

    /// Opens finder at the drive root
    func openFinder() async throws {
        let domain = self.fileProviderDomain()

        guard let url = try? await NSFileProviderManager(for: domain)?.getUserVisibleURL(for: .rootContainer)
        else { return }

        self.logger.debug("Opening finder at url \(url.path())")

        _ = url.startAccessingSecurityScopedResource()
        NSWorkspace.shared.activateFileViewerSelecting([url])
        url.stopAccessingSecurityScopedResource()
    }

    /// Reenumerates the drive
    func reEnumerate() async throws {
        let domain = self.fileProviderDomain()

        self.logger.info("Reenumerating domain \(domain.displayName)")

        try await NSFileProviderManager(for: domain)?.reimportItems(below: .rootContainer)

        self.logger.info("Enumerator signaled for domain \(domain.displayName)")
    }

    /// Resets the sync state for this drive by removing the domain, clearing metadata, and re-adding.
    /// Forces a full re-enumeration from scratch with a clean database.
    func resetSync() async throws {
        let domain = self.fileProviderDomain()

        self.logger.info("Resetting sync for domain \(domain.displayName)")

        // 1. Remove the domain (kills the extension process)
        try await NSFileProviderManager.remove(domain)

        // 2. Clear MetadataStore data for this drive
        do {
            let container = try MetadataStore.createContainer()
            let store = MetadataStore(modelContainer: container)
            try await store.deleteItemsForDrive(driveId: drive.id)
            try await store.deleteSyncAnchor(driveId: drive.id)
            self.logger.info("MetadataStore cleared for drive \(self.drive.id)")
        } catch {
            self.logger.warning("Failed to clear MetadataStore: \(error.localizedDescription, privacy: .public)")
        }

        // 3. Re-add the domain (restarts extension with fresh state)
        try await NSFileProviderManager.add(domain)
        try await NSFileProviderManager(for: domain)?.signalEnumerator(for: .rootContainer)

        self.driveStatus = .idle
        self.logger.info("Sync reset complete for domain \(domain.displayName)")
    }

    /// Returns the drive's file provider domain
    /// - Returns: the drive's file provider domain
    func fileProviderDomain() -> NSFileProviderDomain {
        NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier(rawValue: self.drive.id.uuidString),
            displayName: self.drive.name
        )
    }
}
