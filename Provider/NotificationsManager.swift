import Foundation
import os.log

class NotificationManager {
    private var drive: DS3Drive
    private let logger: Logger = Logger(subsystem: "io.cubbit.CubbitDS3Sync", category: "NotificationManager")
    
    // Used to debounce status change notifications
    var debounceTimer: Timer?
    
    init(drive: DS3Drive) {
        self.drive = drive
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
        if status != self.drive.status {
            self.drive.status = status
            
            guard
                let encodedDriveData = try? JSONEncoder().encode(self.drive),
                let encodedDriveString = String(data: encodedDriveData, encoding: .utf8)
            else { return }
                    
            self.logger.debug("Sending notification for driveStatusChanged")
            
            DistributedNotificationCenter
                .default()
                .post(
                    Notification(name: .driveChanged, object: encodedDriveString)
                )
        }
    }
}