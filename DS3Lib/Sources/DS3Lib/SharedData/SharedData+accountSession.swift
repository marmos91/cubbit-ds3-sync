import Foundation

extension SharedData {
    /// Persist the given `AccountSession` to shared container using NSFileCoordinator for cross-process safety.
    /// - Parameter accountSession: the account session to persist.
    /// - Throws: `SharedDataError.cannotAccessAppGroup` if the app group cannot be accessed. Other error can be thrown if writing and encoding fails
    public func persistAccountSession(
        accountSession: AccountSession
    ) throws {
        let sessionURL = try sharedContainerURL().appendingPathComponent(DefaultSettings.FileNames.accountSessionFileName)
        let encodedSession = try JSONEncoder().encode(accountSession)
        try coordinatedWrite(data: encodedSession, to: sessionURL)
    }

    /// Loads the saved `AccountSession` from shared container using NSFileCoordinator for cross-process safety.
    /// - Returns: the saved `AccountSession`.
    /// - Throws: `SharedDataError.cannotAccessAppGroup` if the app group cannot be accessed. Other error can be thrown if reading and decoding fails
    public func loadAccountSessionFromPersistence() throws -> AccountSession {
        let sessionURL = try sharedContainerURL().appendingPathComponent(DefaultSettings.FileNames.accountSessionFileName)
        return try coordinatedRead(from: sessionURL) { data in
            try JSONDecoder().decode(AccountSession.self, from: data)
        }
    }

    /// Deletes the saved `AccountSession` from shared container.
    /// - Throws: `SharedDataError.cannotAccessAppGroup` if the app group cannot be accessed.
    public func deleteAccountSessionFromPersistence() throws {
        let sessionURL = try sharedContainerURL().appendingPathComponent(DefaultSettings.FileNames.accountSessionFileName)
        try coordinatedDelete(at: sessionURL)
    }
}
