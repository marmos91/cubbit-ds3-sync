import Foundation
import DS3Lib

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
        guard let driveName = self.ds3DriveName else {
            return nil
        }

        return DS3Drive(
            id: self.driveId ?? UUID(),
            name: driveName,
            syncAnchor: self.syncAnchor
        )
    }
}
