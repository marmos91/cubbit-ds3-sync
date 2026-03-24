import Foundation

public extension SharedData {
    /// Persist `Account` to shared container using NSFileCoordinator for cross-process safety.
    /// - Parameter account: the account to persist.
    /// - Throws: `SharedDataError.cannotAccessAppGroup` if the app group cannot be accessed. Other error can be thrown
    /// if reading and decoding fails
    func persistAccount(account: Account) throws {
        let accountURL = try sharedContainerURL().appendingPathComponent(DefaultSettings.FileNames.accountFileName)
        let encodedAccount = try JSONEncoder().encode(account)
        try coordinatedWrite(data: encodedAccount, to: accountURL)
    }

    /// Loads the saved `Account` from shared container using NSFileCoordinator for cross-process safety.
    /// - Returns: the loaded `Account`.
    /// - Throws: `SharedDataError.cannotAccessAppGroup` if the app group cannot be accessed. Other error can be thrown
    /// if reading and decoding fails
    func loadAccountFromPersistence() throws -> Account {
        let accountURL = try sharedContainerURL().appendingPathComponent(DefaultSettings.FileNames.accountFileName)
        return try coordinatedRead(from: accountURL) { data in
            try JSONDecoder().decode(Account.self, from: data)
        }
    }

    /// Deletes the saved `Account` from shared container.
    /// - Throws: `SharedDataError.cannotAccessAppGroup` if the app group cannot be accessed. Other error can be thrown
    /// if reading and decoding fails
    func deleteAccountFromPersistence() throws {
        let accountURL = try sharedContainerURL().appendingPathComponent(DefaultSettings.FileNames.accountFileName)
        try coordinatedDelete(at: accountURL)
    }
}
