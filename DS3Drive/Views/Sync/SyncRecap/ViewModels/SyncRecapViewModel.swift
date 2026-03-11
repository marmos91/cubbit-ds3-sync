import Foundation

@Observable class SyncRecapViewModel {
    var driveId: UUID?
    var syncAnchor: SyncAnchor
    var ds3DriveName: String?
    
    init(syncAnchor: SyncAnchor, driveName: String? = nil, driveId: UUID? = nil) {
        self.syncAnchor = syncAnchor
        self.ds3DriveName = driveName
        self.driveId = driveId
    }
    
    func setDS3DriveName(_ name: String) {
        self.ds3DriveName = name
    }
    
    func getDS3Drive() -> DS3Drive? {
        guard self.ds3DriveName != nil else {
            return nil
        }
        
        return DS3Drive(
            id: self.driveId ?? UUID(),
            name: self.ds3DriveName!,
            syncAnchor: self.syncAnchor
        )
    }
}
