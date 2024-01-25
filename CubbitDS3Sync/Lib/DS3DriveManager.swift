import Foundation
import SwiftUI
import FileProvider
import os.log

enum DS3DriveManagerError: Error {
    case driveNotFound
    case cannotLoadDrives
}

@Observable class DS3DriveManager {
    var drives: [DS3Drive]
    private let logger = Logger(subsystem: "io.cubbit.CubbitDS3Sync", category: "DS3DriveManager")
    
    init() {
        self.drives = DS3DriveManager.loadFromDiskOrCreateNew()
        
        Task {
            // TODO: remove this call as the enumerateChanges method is correctly implemented!
            try await self.cleanFileProvider()
            
            try await self.syncFileProvider()
        }
    }
    
    func cleanFileProvider() async throws {
        try await NSFileProviderManager.removeAllDomains()
            
        self.logger.info("All domains removed")
    }
    
    func openFinder(forDrive drive: DS3Drive) async throws {
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
    
    func reEnumerate(drive: DS3Drive) async throws {
        let domain = self.domain(forDrive: drive)
        
        self.logger.info("Reenumerating domain \(domain.displayName)")
        
        try await NSFileProviderManager(for: domain)?.reimportItems(below: .rootContainer)
            
        self.logger.info("Enumerator signaled for domain \(domain.displayName)")
    }
    
    func pause(driveWithId id: UUID) throws {
        if let index = self.drives.firstIndex(where: {$0.id == id}) {
            self.logger.debug("Pausing drive with id \(id)")
            
            self.drives[index].status = .pause
            return try self.persist()
        }
        
        throw DS3DriveManagerError.driveNotFound
    }
    
    func resume(driveWithId id: UUID) throws {
        if let index = self.drives.firstIndex(where: {$0.id == id}) {
            self.logger.debug("Resuming drive with id \(id)")
            
            self.drives[index].status = .idle
            return try self.persist()
        }
            
        throw DS3DriveManagerError.driveNotFound
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
            return []
        }
    }
}
