import Foundation

extension SharedData {
    func persistAccount(account: Account) throws {
        guard let sharedContainerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: DefaultSettings.appGroup) else {
            throw SharedDataError.cannotAccessAppGroup
        }
        
        let accountURL = sharedContainerURL.appendingPathComponent(DefaultSettings.FileNames.accountFileName)
        
        let encoder = JSONEncoder()
        
        let encodedAccount = try encoder.encode(account)
        try encodedAccount.write(to: accountURL)
    }

    func loadAccountFromPersistence() throws -> Account {
        guard let sharedContainerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: DefaultSettings.appGroup) else {
            throw SharedDataError.cannotAccessAppGroup
        }
        
        let accountURL = sharedContainerURL.appendingPathComponent(DefaultSettings.FileNames.accountFileName)
        
        return try JSONDecoder().decode(Account.self, from: Data(contentsOf: accountURL))
    }

    func deleteAccountFromPersistence() throws {
        guard let sharedContainerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: DefaultSettings.appGroup) else {
            throw SharedDataError.cannotAccessAppGroup
        }
        
        let accountURL = sharedContainerURL.appendingPathComponent(DefaultSettings.FileNames.accountFileName)
        
        try FileManager.default.removeItem(at: accountURL)
    }
}
