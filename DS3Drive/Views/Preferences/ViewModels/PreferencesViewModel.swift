import DS3Lib
import Foundation
import os.log
import SwiftUI

@MainActor @Observable
class PreferencesViewModel {
    var account: Account

    private let logger = Logger(subsystem: LogSubsystem.app, category: LogCategory.app.rawValue)

    init(account: Account) {
        self.account = account
    }

    func disconnectAccount() {
        do {
            UserDefaults.standard.removeObject(forKey: DefaultSettings.UserDefaultsKeys.tutorial)

            try SharedData.default().deleteAccountFromPersistence()
            try SharedData.default().deleteAccountSessionFromPersistence()
            try SharedData.default().deleteDS3DrivesFromPersistence()
            try SharedData.default().deleteDS3APIKeysFromPersistence()
        } catch {
            logger.error("Failed to disconnect account: \(error.localizedDescription)")
        }

        NSApplication.shared.terminate(self)
    }

    func formatFullName() -> String {
        "\(self.account.firstName) \(self.account.lastName)"
    }

    func mainEmail() -> String {
        let defaultEmail = self.account.emails.first(where: { $0.isDefault })

        return defaultEmail?.email ?? ""
    }

    func formatPassword() -> String {
        // NOTE: Just for display purposes
        UUID().uuidString
    }

    func setStartAtLogin(_ value: Bool) {
        do {
            try setLoginItem(value)
        } catch {
            self.logger.error("An error occurred while setting login item: \(error)")
        }
    }
}
