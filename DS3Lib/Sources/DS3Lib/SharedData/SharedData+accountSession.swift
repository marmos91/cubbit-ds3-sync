import Foundation

extension SharedData {
    /// Persist the given `AccountSession` to shared container.
    /// - Parameter accountSession: the account session to persist.
    /// - Throws: `SharedDataError.cannotAccessAppGroup` if the app group cannot be accessed. Other error can be thrown if writing and encoding fails
    func persistAccountSession(
        accountSession: AccountSession
    ) throws {
        guard let sharedContainerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: DefaultSettings.appGroup) else {
            throw SharedDataError.cannotAccessAppGroup
        }
        
        let sessionURL = sharedContainerURL.appendingPathComponent(DefaultSettings.FileNames.accountSessionFileName)
        
        let encoder = JSONEncoder()
        
        let encodedSession = try encoder.encode(accountSession)
        try encodedSession.write(to: sessionURL)
    }
    
    /// Loads the saved `AccountSession` from shared container.
    /// - Returns: the saved `AccountSession`.
    /// - Throws: `SharedDataError.cannotAccessAppGroup` if the app group cannot be accessed. Other error can be thrown if reading and decoding fails
    func loadAccountSessionFromPersistence() throws -> AccountSession {
        guard let sharedContainerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: DefaultSettings.appGroup) else {
            throw SharedDataError.cannotAccessAppGroup
        }
        
        let sessionURL = sharedContainerURL.appendingPathComponent(DefaultSettings.FileNames.accountSessionFileName)
        
        return try JSONDecoder().decode(AccountSession.self, from: Data(contentsOf: sessionURL))
    }
    
    /// Deletes the saved `AccountSession` from shared container.
    /// - Throws: `SharedDataError.cannotAccessAppGroup` if the app group cannot be accessed. 
    func deleteAccountSessionFromPersistence() throws {
        guard let sharedContainerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: DefaultSettings.appGroup) else {
            throw SharedDataError.cannotAccessAppGroup
        }
        
        let sessionURL = sharedContainerURL.appendingPathComponent(DefaultSettings.FileNames.accountSessionFileName)
        
        try FileManager.default.removeItem(at: sessionURL)
    }
}
