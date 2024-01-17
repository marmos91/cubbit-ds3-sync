import SwiftUI
import Foundation
import ServiceManagement
import os.log

@Observable class PreferencesViewModel {
    var account: Account
    let logger: Logger = Logger(subsystem: "io.cubbit.CubbitDS3Sync", category: "PreferencesViewModel")
    
    init(account: Account) {
        self.account = account
    }
    
    func disconnectAccount() {
        do {
            UserDefaults.standard.removeObject(forKey: DefaultSettings.UserDefaultsKeys.tutorial)
            
            try SharedData.shared.deleteAccountFromPersistence()
            try SharedData.shared.deleteAccountSessionFromPersistence()
            try SharedData.shared.deleteDS3DrivesFromPersistence()
            try SharedData.shared.deleteDS3APIKeysFromPersistence()
        } catch { }
        
        NSApplication.shared.terminate(self)
    }
    
    func formatFullName() -> String {
        return "\(self.account.firstName) \(self.account.lastName)"
    }
    
    func mainEmail() -> String {
        let defaultEmail = self.account.emails.first(where: {$0.isDefault})
        
        return defaultEmail?.email ?? ""
    }
    
    func formatPassword() -> String {
        // NOTE: Just for display purposes
        return UUID().uuidString
    }
    
    func setStartAtLogin(_ value: Bool) {
        do {
            let smAppService = SMAppService()
            
            if value {
                try smAppService.register()
            } else {
                try smAppService.unregister()
            }
        } catch {
            self.logger.error("An error occurred while setting login item: \(error)")
        }
    }
}
