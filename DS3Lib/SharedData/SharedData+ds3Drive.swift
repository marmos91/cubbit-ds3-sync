import Foundation
import FileProvider

extension SharedData {
    func loadDS3DrivesFromPersistence() throws -> [DS3Drive] {
        guard let sharedContainerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: DefaultSettings.appGroup) else {
            throw SharedDataError.cannotAccessAppGroup
        }
        
        let drivesURL = sharedContainerURL.appendingPathComponent(DefaultSettings.FileNames.drivesFileName)
        
        let drives = try JSONDecoder().decode([DS3Drive].self, from: Data(contentsOf: drivesURL))
        
        return drives
    }

    func loadDS3DriveFromPersistence(withDomainIdentifier identifier: NSFileProviderDomainIdentifier) throws -> DS3Drive {
        guard let uuid = UUID(uuidString: identifier.rawValue) else {
            throw SharedDataError.conversionError
        }
        
        return try loadDS3DriveFromPersistence(withId: uuid)
    }

    func loadDS3DriveFromPersistence(withId id: UUID) throws -> DS3Drive {
        let drives = try loadDS3DrivesFromPersistence()
        
        guard let drive = drives.first(where: {$0.id == id}) else {
            throw SharedDataError.ds3DriveNotFound
        }
        
        return drive
    }

    func persistDS3Drives(ds3Drives: [DS3Drive]) throws {
        guard let sharedContainerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: DefaultSettings.appGroup) else {
            throw SharedDataError.cannotAccessAppGroup
        }
        
        let drivesURL = sharedContainerURL.appendingPathComponent(DefaultSettings.FileNames.drivesFileName)
        
        let encoder = JSONEncoder()
        let encodedDrives = try encoder.encode(ds3Drives)
        
        try encodedDrives.write(to: drivesURL)
    }

    func deleteDS3DrivesFromPersistence() throws {
        guard let sharedContainerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: DefaultSettings.appGroup) else {
            throw SharedDataError.cannotAccessAppGroup
        }
        
        let drivesURL = sharedContainerURL.appendingPathComponent(DefaultSettings.FileNames.drivesFileName)
        
        try FileManager.default.removeItem(at: drivesURL)
    }
}
