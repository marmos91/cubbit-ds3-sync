import Foundation

extension SharedData {
    /// Persist `Account` to shared container.
    /// - Parameter account: the account to persist.
    /// - Throws: `SharedDataError.cannotAccessAppGroup` if the app group cannot be accessed. Other error can be thrown if reading and decoding fails
    func persistAccount(account: Account) throws {
        guard let sharedContainerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: DefaultSettings.appGroup) else {
            throw SharedDataError.cannotAccessAppGroup
        }
        
        let accountURL = sharedContainerURL.appendingPathComponent(DefaultSettings.FileNames.accountFileName)
        
        let encoder = JSONEncoder()
        
        let encodedAccount = try encoder.encode(account)
        try encodedAccount.write(to: accountURL)
    }
    
    /// Loads the saved `Account` from shared container.
    /// - Returns: the loaded `Account`.
    /// - Throws: `SharedDataError.cannotAccessAppGroup` if the app group cannot be accessed. Other error can be thrown if reading and decoding fails
    func loadAccountFromPersistence() throws -> Account {
        guard let sharedContainerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: DefaultSettings.appGroup) else {
            throw SharedDataError.cannotAccessAppGroup
        }
        
        let accountURL = sharedContainerURL.appendingPathComponent(DefaultSettings.FileNames.accountFileName)
        
        return try JSONDecoder().decode(Account.self, from: Data(contentsOf: accountURL))
    }
    
    /// Deletes the saved `Account` from shared container.
    /// - Throws: `SharedDataError.cannotAccessAppGroup` if the app group cannot be accessed. Other error can be thrown if reading and decoding fails
    func deleteAccountFromPersistence() throws {
        guard let sharedContainerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: DefaultSettings.appGroup) else {
            throw SharedDataError.cannotAccessAppGroup
        }
        
        let accountURL = sharedContainerURL.appendingPathComponent(DefaultSettings.FileNames.accountFileName)
        
        try FileManager.default.removeItem(at: accountURL)
    }
}
