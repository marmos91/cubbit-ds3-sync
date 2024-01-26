import Foundation
import SwiftUI
import FileProvider
import os.log

enum DS3DriveManagerError: Error {
    case driveNotFound
    case cannotLoadDrives
}

// TODO: Refactor this
@Observable class DS3DriveManager {
    @ObservationIgnored
    private let logger = Logger(subsystem: "io.cubbit.CubbitDS3Sync", category: "DS3DriveManager")
    
    var drives: [DS3Drive] = DS3DriveManager.loadFromDiskOrCreateNew()
    
    @ObservationIgnored
    let appStatusManager: AppStatusManager
    
    init(appStatusManager: AppStatusManager) {
        self.appStatusManager = appStatusManager
        
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
    
    func setupObserver() {
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(DS3DriveManager.driveChanged),
            name: .driveChanged,
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
    }
    
    @objc @MainActor
    func driveChanged(_ notification: Notification) {
        guard
            let stringDrive = notification.object as? String,
            let updateDrive = try? JSONDecoder().decode(DS3Drive.self, from: Data(stringDrive.utf8))
        else { return }
        
        do {
            try self.update(drive: updateDrive)
        } catch {
            self.logger.error("Could not update drive \(updateDrive.id.uuidString): \(error.localizedDescription)")
        }
        
        if self.drivesAreSyncing() {
            self.appStatusManager.status = .syncing
        } else {
            self.appStatusManager.status = .idle
        }
    }
    
    func driveWithID(_ id: UUID) -> DS3Drive? {
        return self.drives.first(where: {$0.id == id })
    }
    
    func drivesAreSyncing() -> Bool {
        return self.drives.contains(where: {$0.status == .sync})
    }
    
    func cleanFileProvider() async throws {
        try await NSFileProviderManager.removeAllDomains()
            
        self.logger.info("All domains removed")
    }
    
    func openFinder(forDriveId driveId: UUID) async throws {
        if let drive = self.driveWithID(driveId) {
            let domain = NSFileProviderDomain(
                identifier: NSFileProviderDomainIdentifier(
                    rawValue: drive.id.uuidString
                ),
                displayName: drive.name
            )
            
            let url = try await NSFileProviderManager(for: domain)?.getUserVisibleURL(for: .rootContainer)
            
            guard let url = url else { return }
                
            self.logger.debug("Opening finder at url \(url.path())")
            
            let _ = url.startAccessingSecurityScopedResource()
            NSWorkspace.shared.activateFileViewerSelecting([url])
            url.stopAccessingSecurityScopedResource()
        }
    }
    
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
    
    func domainsToBeDeleted() async throws -> [NSFileProviderDomain] {
        let existingDomains = try await self.extensionExistingDomains()
        
        var domainsToBeDeleted: [NSFileProviderDomain] = []
        
        for existingDomain in existingDomains {
            if !self.drives.contains(where: {$0.id.uuidString == existingDomain.identifier.rawValue} ) {
                domainsToBeDeleted.append(existingDomain)
            }
        }
        
        return domainsToBeDeleted
    }
    
    func syncFileProvider() async throws {
        for domain in try await self.domainsToBeDeleted() {
            self.logger.debug("Removing existing domain \(domain.displayName)")
            try await NSFileProviderManager.remove(domain)
        }
        
        for drive in self.drives {
            let domain = self.domain(forDrive: drive)
            
            self.logger.info("Adding domain \(domain.displayName)")
            
            try await NSFileProviderManager.add(domain)
                
            self.logger.info("Domain \(domain.displayName) added")
                
            try await NSFileProviderManager(for: domain)?.signalEnumerator(for: .rootContainer)
                
            self.logger.info("Root enumerator signaled for domain \(domain.displayName)")
        }
    }
    
    func consoleURL(driveId: UUID) -> String? {
        if let drive = self.driveWithID(driveId) {
            var url =  "\(ConsoleURLs.projectsURL)/\(drive.syncAnchor.project.id)/buckets/\(drive.syncAnchor.bucket.name)"
            
            if drive.syncAnchor.prefix != nil {
                url += "/\(drive.syncAnchor.prefix!)"
            }
            
            return url
        }
        
        return nil
    }
    
    func driveSyncAnchorString(driveId: UUID) -> String? {
        if let drive = self.driveWithID(driveId) {
            var name = drive.syncAnchor.project.name
            
            if drive.syncAnchor.prefix != nil {
                name += "/\(drive.syncAnchor.prefix!)"
            }
            
            return name
        }
        
        return nil
    }
    
    func reEnumerate(driveId: UUID) async throws {
        if let drive = self.driveWithID(driveId) {
            let domain = self.domain(forDrive: drive)
            
            self.logger.info("Reenumerating domain \(domain.displayName)")
            
            try await NSFileProviderManager(for: domain)?.reimportItems(below: .rootContainer)
                
            self.logger.info("Enumerator signaled for domain \(domain.displayName)")
        }
    }
    
    func disconnect(driveWithId id: UUID) async throws {
        if let index = self.drives.firstIndex(where: {$0.id == id}) {
            self.logger.info("Disconnecting drive with id \(id)")
            
            let removedDrive = self.drives.remove(at: index)
            
            try await NSFileProviderManager.remove(self.domain(forDrive: removedDrive))

            return try self.persist()
        }
    }
    
    func domain(forDrive drive: DS3Drive) -> NSFileProviderDomain {
        return NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier(
                rawValue: drive.id.uuidString
            ),
            displayName: drive.name
        )
    }
    
    func add(drive: DS3Drive) async throws {
        self.drives.append(drive)
        try self.persist()
        try await self.syncFileProvider()
    }
    
    @MainActor
    func update(drive: DS3Drive) throws {
        if let index = self.drives.firstIndex(where: {$0.id == drive.id}) {
            self.drives[index] = drive
            return try self.persist()
        }
         
        throw DS3DriveManagerError.driveNotFound
    }
    
    func persist() throws {
        try SharedData.shared.persistDS3Drives(ds3Drives: self.drives)
    }
    
    static func loadFromDiskOrCreateNew() -> [DS3Drive] {
        do {
            return try SharedData.shared.loadDS3DrivesFromPersistence()
        } catch {
            print("Could not load drives from disk: \(error.localizedDescription)")
            return []
        }
    }
}
