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
    var logger = Logger(subsystem: "io.cubbit.ds3sync", category: "ds3DriveManager")
    
    init() {
        self.drives = DS3DriveManager.loadFromDiskOrCreateNew()
        self.syncFileProvider()
    }
    
    func cleanFileProvider(callback: @escaping () -> Void = {}) {
        NSFileProviderManager.removeAllDomains { error in
            if error != nil {
                print(error?.localizedDescription ?? "Unknown error")
            }
            
            self.logger.info("All domains removed")
            
            callback()
        }
    }
    
    func openFinder(forDrive drive: DS3Drive) {
        if let driveURL = self.finderPath(forDrive: drive) {
            NSWorkspace.shared.activateFileViewerSelecting([driveURL])
        }
    }
    
    func finderPath(forDrive drive: DS3Drive) -> URL? {
        return realHomeDirectory()?
            .appendingPathComponent("Library")
            .appendingPathComponent("CloudStorage")
            .appendingPathComponent("CubbitDS3-\(drive.name)")
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
                        print(error?.localizedDescription ?? "Unknown error")
                    }
                    
                    self.logger.info("Domain \(domain.displayName) added")
                    
                    NSFileProviderManager(for: domain)?.signalEnumerator(for: .rootContainer) { error in
                        if error != nil {
                            print("An error occurred: \(error?.localizedDescription ?? "Unknown error") ")
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
                print("An error occurred: \(error?.localizedDescription ?? "Unknown error") ")
            }
            
            self.logger.info("Enumerator signaled for domain \(domain.displayName)")
        }
    }
    
    func pause(driveWithId id: UUID) throws {
        if let index = self.drives.firstIndex(where: {$0.id == id}) {
            print("Pausing drive with id \(id)")
            
            self.drives[index].status = .pause
            try self.persist()
        } else {
            throw DS3DriveManagerError.driveNotFound
        }
    }
    
    func resume(driveWithId id: UUID) throws {
        if let index = self.drives.firstIndex(where: {$0.id == id}) {
            print("Resuming drive with id \(id)")
            
            self.drives[index].status = .idle
            try self.persist()
        } else {
            throw DS3DriveManagerError.driveNotFound
        }
    }
    
    func disconnect(driveWithId id: UUID) throws {
        if let index = self.drives.firstIndex(where: {$0.id == id}) {
            print("Disconnecting drive with id \(id)")
            
            let removedDrive = self.drives.remove(at: index)
            
            NSFileProviderManager.remove(self.domain(forDrive: removedDrive)) { error in
                if error != nil {
                    print("An error occurred: \(error?.localizedDescription ?? "Unknown error") ")
                }
                
                do {
                    try self.persist()
                } catch {
                    print("An error occurred: \(error.localizedDescription) ")
                }
            }
        } else {
            throw DS3DriveManagerError.driveNotFound
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
    
    func add(drive: DS3Drive) throws {
        self.drives.append(drive)
        try self.persist()
        self.syncFileProvider()
    }
    
    func update(drive: DS3Drive) throws {
        if let index = self.drives.firstIndex(where: {$0.id == drive.id}) {
            self.drives[index] = drive
            try self.persist()
        } else {
            throw DS3DriveManagerError.driveNotFound
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
