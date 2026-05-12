@preconcurrency import FileProvider
import Foundation
import Observation
import os.log
import SwiftData

/// Errors that can occur during drive management operations
public enum DS3DriveManagerError: Error {
    case driveNotFound
    case cannotLoadDrives
}

/// Class that manages DS3Drives. It loads them from disk and keeps them in memory for the whole app lifecycle.
/// Handles NSFileProviderDomain registrations and syncs drive state with the File Provider system.
@Observable
public final class DS3DriveManager: @unchecked Sendable {
    @ObservationIgnored private let logger = Logger(subsystem: LogSubsystem.app, category: LogCategory.sync.rawValue)

    @ObservationIgnored private let ipcService: any IPCService

    @ObservationIgnored private var statusListenerTask: Task<Void, Never>?

    /// The list of registered drives
    public var drives: [DS3Drive] = DS3DriveManager.loadFromDiskOrCreateNew()

    /// The set of currently syncing drive IDs
    public var syncingDrives: Set<UUID> = []

    /// Per-drive last-known status for aggregation. Observed by SwiftUI through
    /// `aggregateStatus` so the menu bar icon and tray footer recompute when
    /// any drive transitions. `private(set)` so external observers can read
    /// but only the manager itself mutates the map.
    public private(set) var driveStatuses: [UUID: DS3DriveStatus] = [:]

    /// Single source of truth for the tray aggregate state (Gaps 15 + 27).
    ///
    /// Derived purely from `driveStatuses` via `AggregateStatus.from(statuses:)`
    /// so the tray header, footer, drive rows, and menu bar icon can never
    /// disagree with the per-drive rows. Replaces the previous
    /// `AppStatusManager` counter-driven model that was prone to leaks.
    ///
    /// `AggregateStatusTests` exhaustively covers the reducer.
    public var aggregateStatus: AggregateStatus {
        let statuses = drives.compactMap { driveStatuses[$0.id] }
        // Drives that have never reported a status yet are assumed idle so
        // they don't bias the aggregate toward an error / pause state before
        // the extension has had a chance to run. This keeps a freshly-added
        // drive visually "healthy" until it genuinely sends us something.
        let padded = statuses + Array(repeating: DS3DriveStatus.idle, count: drives.count - statuses.count)
        return AggregateStatus.from(statuses: padded)
    }

    /// Legacy bridge for existing call sites that consume `AppStatus`
    /// (menu bar icon, footer, etc.). New code should prefer `aggregateStatus`
    /// directly so it can distinguish `.mixed` and `.noDrives`.
    public var aggregateAppStatus: AppStatus {
        aggregateStatus.appStatus
    }

    public init(appStatusManager: AppStatusManager, ipcService: (any IPCService)? = nil) {
        self.ipcService = ipcService ?? makeDefaultIPCService()
        self.startStatusListener()

        Task {
            do {
                // Startup: only register domains for drives that are in the list.
                // Never remove existing domains here — drives.json may be temporarily
                // missing (e.g. test teardown hit the shared container) and removing
                // all domains would silently destroy the user's drive setup.
                // Stale domain removal happens only via explicit disconnect().
                try await self.registerMissingDomains()
            } catch {
                self.logger
                    .error(
                        "Failed to register file provider domains on startup: \(error.localizedDescription, privacy: .public)"
                    )
            }
        }
    }

    deinit {
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
    /// Status is passed through immediately; AppStatusManager handles anti-flicker.
    @MainActor
    private func handleDriveStatusChange(_ change: DS3DriveStatusChange) {
        let driveId = change.driveId
        driveStatuses[driveId] = change.status

        switch change.status {
        case .sync:
            syncingDrives.insert(driveId)
            AppStatusManager.default().setStatus(.syncing)

        case .error:
            syncingDrives.remove(driveId)
            AppStatusManager.default().setStatus(.error)

        case .idle:
            syncingDrives.remove(driveId)
            if syncingDrives.isEmpty {
                AppStatusManager.default().setStatus(.idle)
            }
        }
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
        let driveIds = Set(self.drives.map(\.id.uuidString))

        return existingDomains.filter { !driveIds.contains($0.identifier.rawValue) }
    }

    /// Registers file provider domains for drives that aren't yet registered.
    /// Unlike `syncFileProvider()`, this never removes existing domains — safe to call
    /// on startup when `drives` may be empty due to a transient load failure.
    private func registerMissingDomains() async throws {
        let existingDomains = try await self.extensionExistingDomains()
        let existingIds = Set(existingDomains.map(\.identifier.rawValue))

        for drive in self.drives where !existingIds.contains(drive.id.uuidString) {
            let domain = self.fileProviderDomain(forDrive: drive)
            self.logger.info("Registering domain \(domain.displayName)")
            try await NSFileProviderManager.add(domain)
            try? await NSFileProviderManager(for: domain)?.signalErrorResolved(
                NSFileProviderError(.notAuthenticated) as NSError
            )
            try await NSFileProviderManager(for: domain)?.signalEnumerator(for: .rootContainer)
        }
    }

    /// Syncs the file provider extensions with the status of the currently registered drives.
    /// Reconciles existing domains: removes stale ones and only adds drives not yet registered.
    public func syncFileProvider() async throws {
        let existingDomains = try await self.extensionExistingDomains()
        let existingIds = Set(existingDomains.map(\.identifier.rawValue))
        let driveIds = Set(self.drives.map(\.id.uuidString))

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
            try? await NSFileProviderManager(for: domain)?.signalErrorResolved(
                NSFileProviderError(.notAuthenticated) as NSError
            )
            try await NSFileProviderManager(for: domain)?.signalEnumerator(for: .rootContainer)
        }
    }

    /// Removes all drives, their File Provider domains, and cleans up metadata.
    /// Must be called **before** deleting credentials so the extension can handle
    /// cleanup requests while it still has valid API keys.
    public func disconnectAll() async throws {
        self.logger.info("Disconnecting all drives")

        // Clean metadata for each drive before removing domains
        let container = try MetadataStore.createContainer()
        let metadataStore = MetadataStore(modelContainer: container)
        for drive in self.drives {
            try await metadataStore.deleteItemsForDrive(driveId: drive.id)
            try await metadataStore.deleteSyncAnchor(driveId: drive.id)
        }

        // Remove all File Provider domains at once
        try await NSFileProviderManager.removeAllDomains()

        // Clear in-memory state and persist empty drives list
        self.drives.removeAll()
        try self.persist()

        self.logger.info("All drives disconnected and metadata cleaned")
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

    /// Repairs the invariant `every drive in drives.json has a matching DS3ApiKey
    /// in credentials.json`. If credentials.json went missing (e.g. a partial
    /// cleanup, an aborted signout, switching between builds) the File Provider
    /// extension cannot construct its `DS3Client` and enters a crash loop —
    /// every call from `fileproviderd` triggers `Extension init failed: The file
    /// "credentials.json" couldn't be opened`.
    ///
    /// For each drive whose API key is missing locally, this method asks the
    /// `DS3SDK` to load-or-create the key (re-fetching from the IAM service and
    /// reconciling with the remote list). On success, `credentials.json` is
    /// rewritten and the extension's next init succeeds. Drives whose
    /// reconciliation fails (no network, IAM rejected, project deleted) are
    /// left in the list — the user will still see the "Signed Out" UI for
    /// those domains and can re-run setup explicitly.
    ///
    /// Safe to call at every app launch: it short-circuits when the local key
    /// is already present.
    public func repairCredentials(authentication: DS3Authentication) async {
        let sharedData = SharedData.default()
        let sdk = DS3SDK(withAuthentication: authentication)
        for drive in self.drives {
            let user = drive.syncAnchor.IAMUser
            let projectName = drive.syncAnchor.project.name
            let hasLocalKey = (try? sharedData.loadDS3APIKeyFromPersistence(
                forUser: user,
                projectName: projectName
            )) != nil
            guard !hasLocalKey else { continue }
            self.logger.warning(
                "Repairing missing credentials for drive \(drive.name, privacy: .public)"
            )
            do {
                _ = try await sdk.loadOrCreateDS3APIKeys(
                    forIAMUser: user,
                    ds3ProjectName: projectName
                )
                self.logger.info(
                    "Credentials repaired for drive \(drive.name, privacy: .public)"
                )
            } catch {
                let errorMessage = error.localizedDescription
                self.logger.error(
                    "Credential repair failed for drive \(drive.name, privacy: .public): \(errorMessage, privacy: .public)"
                )
            }
        }
    }

    /// Loads the drives from disk or creates a new empty array
    /// - Returns: a list of DS3Drives, if it can load them from disk, otherwise a new empty array
    public static func loadFromDiskOrCreateNew() -> [DS3Drive] {
        do {
            return try SharedData.default().loadDS3DrivesFromPersistence()
        } catch {
            Logger(subsystem: LogSubsystem.app, category: LogCategory.sync.rawValue)
                .error("Could not load drives from disk: \(error.localizedDescription)")
            return []
        }
    }
}
