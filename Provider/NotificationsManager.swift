import Foundation
import os.log

class NotificationManager {
    private let logger: Logger = Logger(subsystem: "io.cubbit.CubbitDS3Sync.provider", category: "NotificationManager")
    
    private let drive: DS3Drive
    private var driveStatus: DS3DriveStatus
    
    // Used to debounce status change notifications
    var debounceTimer: Timer?
    
    init(drive: DS3Drive) {
        self.drive = drive
        self.driveStatus = .idle
    }
    
    /// Sends a notification to the app with the current status of the drive debounced. If you want to send the notification immediately, use `sendDriveChangedNotification(status: DS3DriveStatus)`
    /// - Parameter status: status to send
    func sendDriveChangedNotificationWithDebounce(status: DS3DriveStatus) {
        self.debounceTimer?.invalidate()
        
        DispatchQueue.main.async {
            // This has to happen on the main eventLoop to work
            self.debounceTimer = Timer.scheduledTimer(
                withTimeInterval: DefaultSettings.Extension.statusChangeDebounceInterval,
                repeats: false
            ) { _ in
                self.sendDriveChangedNotification(status: status)
            }
        }
    }
    
    /// Sends a notification to the app with the current status of the drive. If you want to debounce the notification, use `sendDriveChangedNotificationWithDebounce(status: DS3DriveStatus)`
    /// - Parameter status: the status to sendc
    func sendDriveChangedNotification(status: DS3DriveStatus) {
        if status != self.driveStatus {
            self.driveStatus = status
            
            let driveStatusChange = DS3DriveStatusChange(
                driveId: self.drive.id, 
                status: self.driveStatus
            )
            
            guard
                let encodedDriveStatusData = try? JSONEncoder().encode(driveStatusChange),
                let encodedDriveStatusString = String(data: encodedDriveStatusData, encoding: .utf8)
            else { return }
            
            DistributedNotificationCenter
                .default()
                .post(
                    Notification(name: .driveStatusChanged, object: encodedDriveStatusString)
                )
        }
    }
    
    func sendTransferSpeedNotification(_ transferSpeed: DriveTransferStats) {
        guard
            let encodedTransferSpeedData = try? JSONEncoder().encode(transferSpeed),
            let encodedTransferSpeedString = String(data: encodedTransferSpeedData, encoding: .utf8)
        else { return }
        
        DistributedNotificationCenter
            .default()
            .post(
                Notification(name: .driveTransferStats, object: encodedTransferSpeedString)
            )
    }
}
