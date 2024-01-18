import Foundation

extension SharedData {
    func loadDS3APIKeysFromPersistence() throws -> [DS3ApiKey] {
        guard let sharedContainerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: DefaultSettings.appGroup) else {
            throw SharedDataError.cannotAccessAppGroup
        }
        
        let apiKeysURL = sharedContainerURL.appendingPathComponent(DefaultSettings.FileNames.credentialsFileName)
        
        let apiKeys = try JSONDecoder().decode([DS3ApiKey].self, from: Data(contentsOf: apiKeysURL))
        
        return apiKeys
    }

    func loadDS3APIKeyFromPersistence(forUser user: IAMUser, projectName: String) throws -> DS3ApiKey {
        let apiKeys = try loadDS3APIKeysFromPersistence()
        let apiKeyName = apiKeyName(forUser: user, projectName: projectName)
        
        guard let apiKey = apiKeys.first(where: {$0.name == apiKeyName}) else {
            throw SharedDataError.apiKeyNotFound
        }
        
        return apiKey
    }

    func persistDS3APIKeys(_ apiKeys: [DS3ApiKey]) throws {
        guard let sharedContainerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: DefaultSettings.appGroup) else {
            throw SharedDataError.cannotAccessAppGroup
        }
        
        let apiKeysURL = sharedContainerURL.appendingPathComponent(DefaultSettings.FileNames.credentialsFileName)
        
        let encoder = JSONEncoder()
        let encodedApiKeys = try encoder.encode(apiKeys)
        
        try encodedApiKeys.write(to: apiKeysURL)
    }

    func deleteDS3APIKeysFromPersistence() throws {
        guard let sharedContainerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: DefaultSettings.appGroup) else {
            throw SharedDataError.cannotAccessAppGroup
        }
        
        let apiKeysURL = sharedContainerURL.appendingPathComponent(DefaultSettings.FileNames.credentialsFileName)
        
        try FileManager.default.removeItem(at: apiKeysURL)
    }
    
    func deleteDS3APIKeyFromPersistence(withName apiKeyName: String) throws {
        var apiKeys = try loadDS3APIKeysFromPersistence()
        
        guard let apiKeyIndex = apiKeys.firstIndex(where: {$0.name == apiKeyName}) else {
            throw SharedDataError.apiKeyNotFound
        }
        
        apiKeys.remove(at: apiKeyIndex)
        
        try persistDS3APIKeys(apiKeys)
    }
}
