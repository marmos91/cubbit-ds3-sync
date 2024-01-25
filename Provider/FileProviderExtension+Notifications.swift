import Foundation

extension FileProviderExtension {

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
    
    func sendAppStatusNotification(status: AppStatus) {
        DistributedNotificationCenter
            .default()
            .post(
                Notification(name: .appStatusChange, object: status.rawValue)
            )
    }
}
