import Foundation

extension SharedData {
    func persistAccountSession(accountSession: AccountSession) throws {
        guard let sharedContainerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: DefaultSettings.appGroup) else {
            throw SharedDataError.cannotAccessAppGroup
        }
        
        let sessionURL = sharedContainerURL.appendingPathComponent(DefaultSettings.FileNames.accountSessionFileName)
        
        let encoder = JSONEncoder()
        
        let encodedSession = try encoder.encode(accountSession)
        try encodedSession.write(to: sessionURL)
    }

    func loadAccountSessionFromPersistence() throws -> AccountSession {
        guard let sharedContainerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: DefaultSettings.appGroup) else {
            throw SharedDataError.cannotAccessAppGroup
        }
        
        let sessionURL = sharedContainerURL.appendingPathComponent(DefaultSettings.FileNames.accountSessionFileName)
        
        return try JSONDecoder().decode(AccountSession.self, from: Data(contentsOf: sessionURL))
    }

    func deleteAccountSessionFromPersistence() throws {
        guard let sharedContainerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: DefaultSettings.appGroup) else {
            throw SharedDataError.cannotAccessAppGroup
        }
        
        let sessionURL = sharedContainerURL.appendingPathComponent(DefaultSettings.FileNames.accountSessionFileName)
        
        try FileManager.default.removeItem(at: sessionURL)
    }
}
