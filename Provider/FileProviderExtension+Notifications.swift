import Foundation

extension FileProviderExtension {
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
        if status != self.drive!.status {
            self.drive!.status = status
            
            guard
                let drive = self.drive,
                let encodedDriveData = try? JSONEncoder().encode(drive),
                let encodedDriveString = String(data: encodedDriveData, encoding: .utf8)
            else { return }
                    
            DistributedNotificationCenter
                .default()
                .post(
                    Notification(name: .driveChanged, object: encodedDriveString)
                )
        }
    }
}
