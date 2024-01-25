import Foundation
import SwiftUI
import os.log

@Observable class AppStatusManager {
    private let logger: Logger = Logger(subsystem: "io.cubbit.CubbitDS3Sync", category: "AppStatusManager")
    
    var status: AppStatus = .idle
    
    init() {
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(AppStatusManager.statusChanged),
            name: .appStatusChange,
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
    }
    
    deinit {
        DistributedNotificationCenter
            .default()
            .removeObserver(self)
    }
    
    @objc
    func statusChanged(_ notification: Notification) {
        guard
            let stringEnum = notification.object as? String,
            let appStatus = AppStatus(rawValue: stringEnum)
        else { return }
        
        self.logger.debug("App status changed to \(appStatus.rawValue)")
        
        self.status = appStatus
    }
}
