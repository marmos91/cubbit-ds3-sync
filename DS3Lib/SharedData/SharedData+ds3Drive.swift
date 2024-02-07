import Foundation
import FileProvider

extension SharedData {
    /// Loads DS3 drives from shared container.
    /// - Returns: the saved DS3 drives.
    /// - Throws: `SharedDataError.cannotAccessAppGroup` if the app group cannot be accessed. Other error can be thrown if reading and decoding fails
    func loadDS3DrivesFromPersistence() throws -> [DS3Drive] {
        guard let sharedContainerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: DefaultSettings.appGroup) else {
            throw SharedDataError.cannotAccessAppGroup
        }
        
        let drivesURL = sharedContainerURL.appendingPathComponent(DefaultSettings.FileNames.drivesFileName)
        
        let drives = try JSONDecoder().decode([DS3Drive].self, from: Data(contentsOf: drivesURL))
        
        return drives
    }
    
    /// Loads DS3 drive with given domain identifier from shared container.
    /// - Parameter identifier: the domain identifier of the drive.
    /// - Returns: the saved DS3 drive.
    /// - Throws: `SharedDataError.cannotAccessAppGroup` if the app group cannot be accessed. Other error can be thrown if reading and decoding fails
    func loadDS3DriveFromPersistence(
        withDomainIdentifier identifier: NSFileProviderDomainIdentifier
    ) throws -> DS3Drive {
        guard let uuid = UUID(uuidString: identifier.rawValue) else {
            throw SharedDataError.conversionError
        }
        
        return try loadDS3DriveFromPersistence(withId: uuid)
    }
    
    /// Loads DS3 drive with given id from shared container.
    /// - Parameter id: the drive id to use to determine which drive to load.
    /// - Returns: the loaded DS3 drive.
    /// - Throws: `SharedDataError.cannotAccessAppGroup` if the app group cannot be accessed. `SharedDataError.ds3DriveNotFound` if the drive with the given id cannot be found. Other error can be thrown if reading and decoding fails
    func loadDS3DriveFromPersistence(
        withId id: UUID
    ) throws -> DS3Drive {
        let drives = try loadDS3DrivesFromPersistence()
        
        guard let drive = drives.first(where: {$0.id == id}) else {
            throw SharedDataError.ds3DriveNotFound
        }
        
        return drive
    }
    
    /// Saves DS3 drives to shared container.
    /// - Parameter ds3Drives: the drives to save.
    /// - Throws: `SharedDataError.cannotAccessAppGroup` if the app group cannot be accessed. Other error can be thrown if encoding and writing fails
    func persistDS3Drives(
        ds3Drives: [DS3Drive]
    ) throws {
        guard let sharedContainerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: DefaultSettings.appGroup) else {
            throw SharedDataError.cannotAccessAppGroup
        }
        
        let drivesURL = sharedContainerURL.appendingPathComponent(DefaultSettings.FileNames.drivesFileName)
        
        let encoder = JSONEncoder()
        let encodedDrives = try encoder.encode(ds3Drives)
        
        try encodedDrives.write(to: drivesURL)
    }
    
    /// Saves DS3 drives to shared container.
    /// - Parameter ds3Drives: the drives to save.
    /// - Throws: `SharedDataError.cannotAccessAppGroup` if the app group cannot be accessed. Other error can be thrown if encoding and writing fails
    func persistDS3Drive(
        ds3Drive: DS3Drive
    ) throws {
        guard let sharedContainerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: DefaultSettings.appGroup) else {
            throw SharedDataError.cannotAccessAppGroup
        }
        
        let drivesURL = sharedContainerURL.appendingPathComponent(DefaultSettings.FileNames.drivesFileName)
        
        var drives = try loadDS3DrivesFromPersistence()
        
        if let index = drives.firstIndex(where: {$0.id == ds3Drive.id}) {
            drives[index] = ds3Drive
        } else {
            drives.append(ds3Drive)
        }
        
        let encoder = JSONEncoder()
        let encodedDrives = try encoder.encode(drives)
        
        try encodedDrives.write(to: drivesURL)
    }
    
    /// Deletes the saved DS3 drives from shared container.
    /// - Throws: `SharedDataError.cannotAccessAppGroup` if the app group cannot be accessed. 
    func deleteDS3DrivesFromPersistence() throws {
        guard let sharedContainerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: DefaultSettings.appGroup) else {
            throw SharedDataError.cannotAccessAppGroup
        }
        
        let drivesURL = sharedContainerURL.appendingPathComponent(DefaultSettings.FileNames.drivesFileName)
        
        try FileManager.default.removeItem(at: drivesURL)
    }
}
