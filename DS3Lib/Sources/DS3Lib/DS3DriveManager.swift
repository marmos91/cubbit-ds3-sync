import Foundation
import Observation
@preconcurrency import FileProvider
import os.log

/// Errors that can occur during drive management operations
public enum DS3DriveManagerError: Error {
    case driveNotFound
    case cannotLoadDrives
}

/// Class that manages DS3Drives. It loads them from disk and keeps them in memory for the whole app lifecycle.
/// Handles NSFileProviderDomain registrations and syncs drive state with the File Provider system.
@Observable public final class DS3DriveManager: @unchecked Sendable {
    @ObservationIgnored
    private let logger = Logger(subsystem: LogSubsystem.app, category: LogCategory.sync.rawValue)

    @ObservationIgnored
    private let ipcService: any IPCService

    @ObservationIgnored
    private var statusListenerTask: Task<Void, Never>?

    /// The list of registered drives
    public var drives: [DS3Drive] = DS3DriveManager.loadFromDiskOrCreateNew()

    /// The set of currently syncing drive IDs
    public var syncingDrives: Set<UUID> = []

    /// Per-drive last-known status for aggregation
    @ObservationIgnored
    private var driveStatuses: [UUID: DS3DriveStatus] = [:]

    /// Per-drive timers to debounce idle transitions and prevent the menu bar icon from flashing.
    @ObservationIgnored
    private var idleDebounceTimers: [UUID: Timer] = [:]

    public init(appStatusManager: AppStatusManager, ipcService: (any IPCService)? = nil) {
        self.ipcService = ipcService ?? makeDefaultIPCService()
        self.startStatusListener()

        Task {
            do {
                try await self.syncFileProvider()
            } catch {
                self.logger.error("Failed to sync file provider domains on startup: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    deinit {
        for timer in idleDebounceTimers.values { timer.invalidate() }
        statusListenerTask?.cancel()
    }

    /// Starts listening for drive status changes via IPCService AsyncStream
    private func startStatusListener() {
        self.statusListenerTask = Task { [weak self] in
            await self?.ipcService.startListening()
            guard let self else { return }
            for await change in self.ipcService.statusUpdates {
                await self.handleDriveStatusChange(change)
            }
        }
    }

    /// Handles a drive status change from the IPCService stream.
    /// Idle transitions are debounced by 2s per drive to prevent the menu bar
    /// icon from flashing between syncing and idle during parallel file operations.
    @MainActor
    private func handleDriveStatusChange(_ change: DS3DriveStatusChange) {
        let driveId = change.driveId

        idleDebounceTimers[driveId]?.invalidate()
        idleDebounceTimers[driveId] = nil

        driveStatuses[driveId] = change.status

        switch change.status {
        case .sync, .indexing:
            syncingDrives.insert(driveId)
            AppStatusManager.default().setStatus(change.status == .sync ? .syncing : .indexing)

        case .paused:
            syncingDrives.remove(driveId)
            recomputeAppStatus()

        case .error:
            syncingDrives.remove(driveId)
            AppStatusManager.default().setStatus(.error)

        case .idle:
            idleDebounceTimers[driveId] = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.syncingDrives.remove(driveId)
                    self.idleDebounceTimers.removeValue(forKey: driveId)
                    self.recomputeAppStatus()
                }
            }
        }
    }

    /// Called by the UI when the user manually pauses or resumes a drive.
    /// Updates the internal tracking so `AppStatusManager` reflects the change immediately.
    @MainActor
    public func notifyDrivePausedFromUI(driveId: UUID, paused: Bool) {
        idleDebounceTimers[driveId]?.invalidate()
        idleDebounceTimers[driveId] = nil

        driveStatuses[driveId] = paused ? .paused : .idle
        if paused {
            syncingDrives.remove(driveId)
        }
        recomputeAppStatus()
    }

    /// Recomputes the global app status from per-drive statuses.
    /// If all drives are paused → .paused. If any syncing → .syncing. Otherwise → .idle.
    @MainActor
    private func recomputeAppStatus() {
        guard syncingDrives.isEmpty else { return }

        let allPaused = !drives.isEmpty && drives.allSatisfy { driveStatuses[$0.id] == .paused }

        AppStatusManager.default().setStatus(allPaused ? .paused : .idle)
    }
    
    /// Returns a stored DS3Drive with the given id, if any
    /// - Parameter id: the id of the drive to retrieve
    /// - Returns: the DS3Drive, if any
    public func driveWithID(_ id: UUID) -> DS3Drive? {
        self.drives.first(where: { $0.id == id })
    }
    
    /// Removes all domains from the file provider
    public func cleanFileProvider() async throws {
        try await NSFileProviderManager.removeAllDomains()
        self.logger.debug("All domains removed")
    }
    
    /// Lists existing domains in the file provider
    /// - Returns: the currently registered domains
    public func extensionExistingDomains() async throws -> [NSFileProviderDomain] {
        do {
            return try await NSFileProviderManager.domains()
        } catch {
            self.logger.error("An error occurred: \(error.localizedDescription)")
            throw DS3DriveManagerError.driveNotFound
        }
    }
    
    /// Lists the domains that need to be deleted from the file provider
    /// - Returns: the file provider domains that need to be deleted
    public func domainsToBeDeleted() async throws -> [NSFileProviderDomain] {
        let existingDomains = try await self.extensionExistingDomains()
        let driveIds = Set(self.drives.map { $0.id.uuidString })

        return existingDomains.filter { !driveIds.contains($0.identifier.rawValue) }
    }
    
    /// Syncs the file provider extensions with the status of the currently registered drives.
    /// Reconciles existing domains: removes stale ones and only adds drives not yet registered.
    public func syncFileProvider() async throws {
        let existingDomains = try await self.extensionExistingDomains()
        let existingIds = Set(existingDomains.map { $0.identifier.rawValue })
        let driveIds = Set(self.drives.map { $0.id.uuidString })

        // Remove stale domains (registered but no longer in drives list)
        for domain in existingDomains where !driveIds.contains(domain.identifier.rawValue) {
            self.logger.debug("Removing stale domain \(domain.displayName)")
            try await NSFileProviderManager.remove(domain)
        }

        // Add only new drives (not already registered)
        for drive in self.drives where !existingIds.contains(drive.id.uuidString) {
            let domain = self.fileProviderDomain(forDrive: drive)
            self.logger.info("Adding domain \(domain.displayName)")
            try await NSFileProviderManager.add(domain)
            try await NSFileProviderManager(for: domain)?.signalEnumerator(for: .rootContainer)
        }
    }
    
    /// Removes a drive from the manager. It also removes the corresponding file provider domain.
    /// - Parameter id: the drive id to remove
    public func disconnect(driveWithId id: UUID) async throws {
        if let index = self.drives.firstIndex(where: { $0.id == id }) {
            self.logger.info("Disconnecting drive with id \(id)")
            
            let removedDrive = self.drives.remove(at: index)
            try await NSFileProviderManager.remove(self.fileProviderDomain(forDrive: removedDrive))
            try self.persist()
        }
    }
    
    /// Returns the drive's file provider domain
    /// - Returns: the drive's file provider domain
    public func fileProviderDomain(forDrive drive: DS3Drive) -> NSFileProviderDomain {
        NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier(rawValue: drive.id.uuidString),
            displayName: drive.name
        )
    }
    
    /// Adds a new drive to the manager
    /// - Parameter drive: the DS3Drive to add
    @MainActor
    public func add(drive: DS3Drive) async throws {
        self.drives.append(drive)
        try self.persist()
        try await self.syncFileProvider()
    }
    
    /// Updates a drive in the manager
    /// - Parameter drive: the updated drive
    @MainActor
    public func update(drive: DS3Drive) async throws {
        guard let index = self.drives.firstIndex(where: { $0.id == drive.id }) else {
            throw DS3DriveManagerError.driveNotFound
        }

        self.drives[index] = drive
        try self.persist()
        try await self.syncFileProvider()
    }
    
    /// Persist the drives to disk
    public func persist() throws {
        try SharedData.default().persistDS3Drives(ds3Drives: self.drives)
    }
    
    /// Loads the drives from disk or creates a new empty array
    /// - Returns: a list of DS3Drives, if it can load them from disk, otherwise a new empty array
    public static func loadFromDiskOrCreateNew() -> [DS3Drive] {
        do {
            return try SharedData.default().loadDS3DrivesFromPersistence()
        } catch {
            Logger(subsystem: LogSubsystem.app, category: LogCategory.sync.rawValue).error("Could not load drives from disk: \(error.localizedDescription)")
            return []
        }
    }
}
