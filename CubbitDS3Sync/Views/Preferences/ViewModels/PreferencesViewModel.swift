import SwiftUI
import Foundation
import ServiceManagement

@Observable class PreferencesViewModel {
    var account: Account
    
    init(account: Account) {
        self.account = account
    }
    
    func disconnectAccount() throws {
        try SharedData.shared.deleteAccountFromPersistence()
        try SharedData.shared.deleteAccountSessionFromPersistence()
        try SharedData.shared.deleteDS3DrivesFromPersistence()
        try SharedData.shared.deleteDS3APIKeysFromPersistence()
        
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
    
    func setStartAtLogin(_ value: Bool) throws {        
        let smAppService = SMAppService()
        
        if value {
            try smAppService.register()
        } else {
            try smAppService.unregister()
        }
    }
}
