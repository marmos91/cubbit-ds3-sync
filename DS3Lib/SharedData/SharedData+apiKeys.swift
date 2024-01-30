import Foundation

extension SharedData {
    /// Loads the saved `DS3ApiKey`s from shared container.
    /// - Returns: the saved `DS3ApiKey`s.
    /// - Throws: `SharedDataError.cannotAccessAppGroup` if the app group cannot be accessed. Other error can be thrown if reading and decoding fails
    func loadDS3APIKeysFromPersistence() throws -> [DS3ApiKey] {
        guard let sharedContainerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: DefaultSettings.appGroup) else {
            throw SharedDataError.cannotAccessAppGroup
        }
        
        let apiKeysURL = sharedContainerURL.appendingPathComponent(DefaultSettings.FileNames.credentialsFileName)
        
        let apiKeys = try JSONDecoder().decode([DS3ApiKey].self, from: Data(contentsOf: apiKeysURL))
        
        return apiKeys
    }
    
    /// Loads the `DS3ApiKey` for the given user and project name from shared container.
    /// - Parameters:
    ///   - user: the IAM user to load the API key for.
    ///   - projectName: the project name to load the API key for.
    /// - Returns: the saved API key.
    /// - Throws: `SharedDataError.cannotAccessAppGroup` if the app group cannot be accessed. Other error can be thrown if reading and decoding fails
    func loadDS3APIKeyFromPersistence(
        forUser user: IAMUser,
        projectName: String
    ) throws -> DS3ApiKey {
        let apiKeys = try loadDS3APIKeysFromPersistence()
        let apiKeyName = DS3SDK.apiKeyName(forUser: user, projectName: projectName)
        
        guard let apiKey = apiKeys.first(where: {$0.name == apiKeyName}) else {
            throw SharedDataError.apiKeyNotFound
        }
        
        return apiKey
    }
    
    /// Saves the given `DS3ApiKey`s to shared container.
    /// - Parameter apiKeys: the api keys to save.
    /// - Throws: `SharedDataError.cannotAccessAppGroup` if the app group cannot be accessed. Other error can be thrown if encoding and writing fails
    func persistDS3APIKeys(
        _ apiKeys: [DS3ApiKey]
    ) throws {
        guard let sharedContainerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: DefaultSettings.appGroup) else {
            throw SharedDataError.cannotAccessAppGroup
        }
        
        let apiKeysURL = sharedContainerURL.appendingPathComponent(DefaultSettings.FileNames.credentialsFileName)
        
        let encoder = JSONEncoder()
        let encodedApiKeys = try encoder.encode(apiKeys)
        
        try encodedApiKeys.write(to: apiKeysURL)
    }
    
    /// Deletes all saved `DS3ApiKey`s from shared container.
    /// - Throws: `SharedDataError.cannotAccessAppGroup` if the app group cannot be accessed. Other error can be thrown if reading and decoding fails
    func deleteDS3APIKeysFromPersistence() throws {
        guard let sharedContainerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: DefaultSettings.appGroup) else {
            throw SharedDataError.cannotAccessAppGroup
        }
        
        let apiKeysURL = sharedContainerURL.appendingPathComponent(DefaultSettings.FileNames.credentialsFileName)
        
        try FileManager.default.removeItem(at: apiKeysURL)
    }
    
    /// Deletes the saved `DS3ApiKey`with the given name from shared container.
    /// - Parameter apiKeyName: the api key name to delete.
    /// - Throws: `SharedDataError.cannotAccessAppGroup` if the app group cannot be accessed. `SharedDataError.apiKeyNotFound` if the api key with the given name could not be found.
    func deleteDS3APIKeyFromPersistence(withName apiKeyName: String) throws {
        var apiKeys = try loadDS3APIKeysFromPersistence()
        
        guard let apiKeyIndex = apiKeys.firstIndex(where: {$0.name == apiKeyName}) else {
            throw SharedDataError.apiKeyNotFound
        }
        
        apiKeys.remove(at: apiKeyIndex)
        
        try persistDS3APIKeys(apiKeys)
    }
}
