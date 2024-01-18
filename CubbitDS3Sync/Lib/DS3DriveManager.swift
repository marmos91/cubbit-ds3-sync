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
    var logger = Logger(subsystem: "io.cubbit.CubbitDS3Sync", category: "DS3DriveManager")
    
    init() {
        self.drives = DS3DriveManager.loadFromDiskOrCreateNew()
        self.syncFileProvider()
    }
    
    func cleanFileProvider(callback: @escaping () -> Void = {}) {
        NSFileProviderManager.removeAllDomains { error in
            if error != nil {
                self.logger.error("An error occurred: \(error?.localizedDescription ?? "Unknown error")")
            }
            
            self.logger.info("All domains removed")
            
            callback()
        }
    }
    
    func openFinder(forDrive drive: DS3Drive) {
        let domain = NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier(
                rawValue: drive.id.uuidString
            ),
            displayName: drive.name
        )
        
        NSFileProviderManager(for: domain)?.getUserVisibleURL(for: .rootContainer) { url, error in
            guard error != nil else { return }
            guard let url = url else { return }
            
            if url.startAccessingSecurityScopedResource() {
                NSWorkspace.shared.activateFileViewerSelecting([url])
                url.stopAccessingSecurityScopedResource()
            }
        }
    }
    
    func syncFileProvider() {
        // TODO: Improve this
        self.cleanFileProvider{
            self.drives.forEach { drive in
                let domain = NSFileProviderDomain(
                    identifier: NSFileProviderDomainIdentifier(
                        rawValue: drive.id.uuidString
                    ),
                    displayName: drive.name
                )
                
                self.logger.info("Adding domain \(domain.displayName)")
                
                NSFileProviderManager.add(domain) { error in
                    if error != nil {
                        self.logger.error("An error occurred: \(error?.localizedDescription ?? "Unknown error")")
                    }
                    
                    self.logger.info("Domain \(domain.displayName) added")
                    
                    NSFileProviderManager(for: domain)?.signalEnumerator(for: .rootContainer) { error in
                        if error != nil {
                            self.logger.error("An error occurred: \(error?.localizedDescription ?? "Unknown error")")
                        }
                        
                        self.logger.info("Enumerator signaled for domain \(domain.displayName)")
                    }
                }
            }
        }
    }
    
    func reEnumerate(drive: DS3Drive) {
        let domain = NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier(
                rawValue: drive.id.uuidString
            ),
            displayName: drive.name
        )
        
        self.logger.info("Reenumerating domain \(domain.displayName)")
        
        NSFileProviderManager(for: domain)?.reimportItems(below: .rootContainer) { error in
            if error != nil {
                self.logger.error("An error occurred: \(error?.localizedDescription ?? "Unknown error")")
            }
            
            self.logger.info("Enumerator signaled for domain \(domain.displayName)")
        }
    }
    
    func pause(driveWithId id: UUID) throws {
        if let index = self.drives.firstIndex(where: {$0.id == id}) {
            self.logger.debug("Pausing drive with id \(id)")
            
            self.drives[index].status = .pause
            try self.persist()
        } else {
            throw DS3DriveManagerError.driveNotFound
        }
    }
    
    func resume(driveWithId id: UUID) throws {
        if let index = self.drives.firstIndex(where: {$0.id == id}) {
            self.logger.debug("Resuming drive with id \(id)")
            
            self.drives[index].status = .idle
            try self.persist()
        } else {
            throw DS3DriveManagerError.driveNotFound
        }
    }
    
    func disconnect(driveWithId id: UUID){
        if let index = self.drives.firstIndex(where: {$0.id == id}) {
            self.logger.info("Disconnecting drive with id \(id)")
            
            let removedDrive = self.drives.remove(at: index)
            
            NSFileProviderManager.remove(self.domain(forDrive: removedDrive)) { error in
                if error != nil {
                    self.logger.error("An error occurred: \(error?.localizedDescription ?? "Unknown error")")
                }
                
                do {
                    try self.persist()
                } catch {
                    self.logger.error("An error occurred: \(error)")
                }
            }
        } else {
            self.logger.error("Drive with id \(id) not found")
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
    
    func add(drive: DS3Drive) {
        do {
            self.drives.append(drive)
            try self.persist()
            self.syncFileProvider()
        } catch {
            self.logger.error("An error occurred while adding drive with id \(drive.id): \(error)")
        }
    }
    
    func update(drive: DS3Drive) {
        do {
            if let index = self.drives.firstIndex(where: {$0.id == drive.id}) {
                self.drives[index] = drive
                try self.persist()
            } else {
                throw DS3DriveManagerError.driveNotFound
            }
        }
        catch {
            self.logger.error("An error occurred while updating drive with id \(drive.id): \(error)")
        }
    }
    
    func persist() throws{
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
