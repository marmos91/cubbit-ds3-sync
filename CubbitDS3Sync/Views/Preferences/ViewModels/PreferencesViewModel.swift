import SwiftUI
import Foundation
import os.log
import DS3Lib

@Observable class PreferencesViewModel {
    var account: Account
    
    private let logger: Logger = Logger(subsystem: "io.cubbit.CubbitDS3Sync", category: "PreferencesViewModel")
    
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
            try setLoginItem(value)
        } catch {
            self.logger.error("An error occurred while setting login item: \(error)")
        }
    }
}
