import Foundation
import SwiftUI
import FileProvider
import os.log

enum DS3DriveManagerError: Error {
    case driveNotFound
    case cannotLoadDrives
}

/// Class that manages DS3Drives. It loads them from disk and keeps them in memory for the whole app lifecycle.
@Observable class DS3DriveManager {
    @ObservationIgnored
    private let logger = Logger(subsystem: "io.cubbit.CubbitDS3Sync", category: "DS3DriveManager")
    
    var drives: [DS3Drive] = DS3DriveManager.loadFromDiskOrCreateNew()
    var syncyingDrives: Set<UUID> = []
    
    init(appStatusManager: AppStatusManager) {
        self.setupObserver()
        
        Task {
            // TODO: remove this call as the enumerateChanges method is correctly implemented!
            try await self.cleanFileProvider()
            try await self.syncFileProvider()
        }
    }
    
    deinit {
        DistributedNotificationCenter
            .default()
            .removeObserver(self)
    }
    
    /// Sets up the observer for the drive to listen for notifications from the extension
    private func setupObserver() {
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(DS3DriveManager.driveStatusChanged),
            name: .driveStatusChanged,
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
    }
    
    /// Gets fired when the drive status changes.
    /// - Parameter notification: the notification received from the extension
    @objc @MainActor
    private func driveStatusChanged(_ notification: Notification) {
        guard
            let stringDrive = notification.object as? String,
            let updateDriveStatusNotification = try? JSONDecoder().decode(DS3DriveStatusChange.self, from: Data(stringDrive.utf8))
        else { return }
        
        switch updateDriveStatusNotification.status {
        case .sync, .indexing:
            self.syncyingDrives.insert(updateDriveStatusNotification.driveId)
        default:
            self.syncyingDrives.remove(updateDriveStatusNotification.driveId)
        }
        
        if !self.syncyingDrives.isEmpty {
            AppStatusManager.default().status = .syncing
        } else {
            AppStatusManager.default().status = .idle
        }
    }
    
    /// Returns a stored DS3Drive with the given id, if any
    /// - Parameter id: the id of the drive to retrieve
    /// - Returns: the DS3Drive, if any
    func driveWithID(_ id: UUID) -> DS3Drive? {
        return self.drives.first(where: {$0.id == id })
    }
    
    /// Removes all domains from the file provider
    func cleanFileProvider() async throws {
        try await NSFileProviderManager.removeAllDomains()
        self.logger.debug("All domains removed")
    }
    
    /// Lists existing domains in the file provider
    /// - Returns: the currently registered domains
    func extensionExistingDomains() async throws -> [NSFileProviderDomain] {
        return try await withCheckedThrowingContinuation { continuation in
            NSFileProviderManager.getDomainsWithCompletionHandler { domains, error in
                if error != nil {
                    self.logger.error("An error occurred: \(error?.localizedDescription ?? "Unknown error")")
                    return continuation.resume(throwing: DS3DriveManagerError.driveNotFound)
                }
                
                continuation.resume(returning: domains)
            }
        }
    }
    
    /// Lists the domains that need to be deleted from the file provider
    /// - Returns: the file provider domains that need to be deleted
    func domainsToBeDeleted() async throws -> [NSFileProviderDomain] {
        var domainsToBeDeleted: [NSFileProviderDomain] = []
        
        for existingDomain in try await self.extensionExistingDomains() {
            if !self.drives.contains(
                where: {
                    $0.id.uuidString == existingDomain.identifier.rawValue
                }
            ) {
                domainsToBeDeleted.append(existingDomain)
            }
        }
        
        return domainsToBeDeleted
    }
    
    /// Syncs the file provider extensions with the status of the currently registered drives
    func syncFileProvider() async throws {
        for domain in try await self.domainsToBeDeleted() {
            self.logger.debug("Removing existing domain \(domain.displayName)")
            try await NSFileProviderManager.remove(domain)
        }
        
        for drive in self.drives {
            let domain = self.fileProviderDomain(forDrive: drive)

            self.logger.info("Adding domain \(domain.displayName)")
            try await NSFileProviderManager.add(domain)
            self.logger.info("Domain \(domain.displayName) added")
                
            try await NSFileProviderManager(for: domain)?.signalEnumerator(for: .rootContainer)
            self.logger.info("Root enumerator signaled for domain \(domain.displayName)")
        }
    }
    
    /// Removes a drive from the manager. It also removes the corresponding file provider domain.
    /// - Parameter id: the drive id to remove
    func disconnect(driveWithId id: UUID) async throws {
        if let index = self.drives.firstIndex(where: {$0.id == id}) {
            self.logger.info("Disconnecting drive with id \(id)")
            
            let removedDrive = self.drives.remove(at: index)
            try await NSFileProviderManager.remove(self.fileProviderDomain(forDrive: removedDrive))
            return try self.persist()
        }
    }
    
    /// Returns the drive's file provider domain
    /// - Returns: the drive's file provider domain
    func fileProviderDomain(forDrive drive: DS3Drive) -> NSFileProviderDomain {
        return NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier(
                rawValue: drive.id.uuidString
            ),
            displayName: drive.name
        )
    }
    
    /// Adds a new drive to the manager
    /// - Parameter drive: the DS3Drive to add
    @MainActor
    func add(drive: DS3Drive) async throws {
        self.drives.append(drive)
        try self.persist()
        try await self.syncFileProvider()
    }
    
    /// Updates a drive in the manager
    /// - Parameter drive: the updated drive
    @MainActor
    func update(drive: DS3Drive) async throws {
        if let index = self.drives.firstIndex(where: {$0.id == drive.id}) {
            self.drives[index] = drive
            try self.persist()
            return try await self.syncFileProvider()
        }
         
        throw DS3DriveManagerError.driveNotFound
    }
    
    /// Persist the drives to disk
    func persist() throws {
        try SharedData.shared.persistDS3Drives(ds3Drives: self.drives)
    }
    
    /// Loads the drives from disk or creates a new empty array
    /// - Returns: a list of DS3Drives, if it can load them from disk, otherwise a new empty array
    static func loadFromDiskOrCreateNew() -> [DS3Drive] {
        do {
            return try SharedData.shared.loadDS3DrivesFromPersistence()
        } catch {
            print("Could not load drives from disk: \(error.localizedDescription)")
            return []
        }
    }
}
