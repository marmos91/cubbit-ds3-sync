import Foundation

extension FileProviderExtension {
    /// Sends a notification to the app with the current status of the extension debounced. If you want to send the notification immediately, use `sendAppStatusNotification(status: AppStatus)`
    /// - Parameter status: status to send
    func sendAppStatusNotificationWithDebounce(status: AppStatus) {
        self.debounceTimer?.invalidate()

        DispatchQueue.main.async {
            // This has to happen on the main eventLoop to work
            self.debounceTimer = Timer.scheduledTimer(
                withTimeInterval: DefaultSettings.Extension.statusChangeDebounceInterval,
                repeats: false
            ) { _ in
                self.sendAppStatusNotification(status: status)
            }
        }
    }
    
    /// Sends a notification to the app with the current status of the extension. If you want to debounce the notification, use `sendAppStatusNotificationWithDebounce(status: AppStatus)`
    /// - Parameter status: the status to sendc
    func sendAppStatusNotification(status: AppStatus) {
        DistributedNotificationCenter
            .default()
            .post(
                Notification(name: .appStatusChange, object: status.rawValue)
            )
    }
}
