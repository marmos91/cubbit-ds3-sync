import Foundation

enum DS3SDKError: Error, LocalizedError {
    case invalidURL(url: String? = nil)
    case serverError
    case jsonConversion
    case encodingError
}

@Observable class DS3SDK {
    private var authentication: DS3Authentication
    
    init(
        withAuthentication authentication: DS3Authentication
    ) {
        self.authentication = authentication
    }
    
    // MARK: - Projects

    func getRemoteProjects() async throws -> [Project] {
        try await self.authentication.refreshIfNeeded()
        
        guard let url = URL(string: CubbitAPIURLs.IAM.projects) else { throw DS3AuthenticationError.invalidURL(url: CubbitAPIURLs.IAM.projects) }
        guard let session = self.authentication.accountSession else { throw DS3AuthenticationError.loggedOut }
        
        var request = URLRequest(url: url)
        
        request.allHTTPHeaderFields = [
          "Content-Type": "application/json",
          "Authorization": "Bearer \(session.token.token)"
        ]
        
        request.httpMethod = "GET"
        
        let (responseData, response) = try await URLSession.shared.data(for: request)
        
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw DS3AuthenticationError.serverError }
        guard let projects = try? JSONDecoder().decode([Project].self, from: responseData) else { throw DS3AuthenticationError.jsonConversion }
        
        return projects
    }
   
    // MARK: - API Keys
    
    func getRemoteApiKeys(forIAMUser user: IAMUser) async throws -> [DS3ApiKey] {
        let iamToken = try await authentication.forgeIAMToken(forIAMUser: user)
        
        guard let url = URL(string: "\(CubbitAPIURLs.keyvault.getKeysURL)?user_id=\(user.id)") else {
            throw DS3SDKError.invalidURL(url: CubbitAPIURLs.IAM.auth.challengeURL)
        }
        
        var request = URLRequest(url: url)
        
        request.allHTTPHeaderFields = [
          "Authorization": "Bearer \(iamToken.token)"
        ]
        
        request.httpMethod = "GET"
        
        let (responseData, response) = try await URLSession.shared.data(for: request)
        
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw DS3SDKError.serverError }
        guard let apiKeys = try? JSONDecoder().decode([DS3ApiKey].self, from: responseData) else { throw DS3SDKError.jsonConversion }
        
        return apiKeys
    }
    
    func deleteApiKey(_ apiKey: DS3ApiKey, forIAMUser user: IAMUser) async throws {
        let iamToken = try await authentication.forgeIAMToken(forIAMUser: user)
        
        guard let urlencodedApiKey = apiKey.apiKey.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { throw DS3SDKError.encodingError }
        
        guard let url = URL(string: "\(CubbitAPIURLs.keyvault.deleteKeyURL)/\(urlencodedApiKey)?user_id=\(user.id)") else {
            throw DS3SDKError.invalidURL(url: CubbitAPIURLs.IAM.auth.challengeURL)
        }
        
        var request = URLRequest(url: url)
        
        request.allHTTPHeaderFields = [
          "Authorization": "Bearer \(iamToken.token)"
        ]
        
        request.httpMethod = "DELETE"
        
        let (_, response) = try await URLSession.shared.data(for: request)
        
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw DS3SDKError.serverError }
    }
    
    /// Load API keys for the given iam user and ds3 project from disk, if already available. Otherwise creates a new pair and save it to disk
    func loadOrCreateDS3APIKeys(forIAMUser user: IAMUser, ds3ProjectName: String) async throws -> DS3ApiKey {
        let apiKeyName = apiKeyName(forUser: user, projectName: ds3ProjectName)
        
        var apiKeys = (try? SharedData.shared.loadDS3APIKeysFromPersistence()) ?? []
        
        if let apiKey = apiKeys.first(where: {$0.name == apiKeyName}) {
            return apiKey
        }
        
        let iamToken = try await authentication.forgeIAMToken(forIAMUser: user)
        
        let existingApiKeys = try await self.getRemoteApiKeys(forIAMUser: user)
        
        if let apiKey = existingApiKeys.first(where: {$0.name == apiKeyName}) {
            try await self.deleteApiKey(apiKey, forIAMUser: user)
        }
        
        guard let url = URL(string: "\(CubbitAPIURLs.keyvault.createKeyURL)/\(apiKeyName)?user_id=\(user.id)") else {
            throw DS3SDKError.invalidURL(url: CubbitAPIURLs.IAM.auth.challengeURL)
        }
        
        var request = URLRequest(url: url)
        
        request.allHTTPHeaderFields = [
          "Authorization": "Bearer \(iamToken.token)"
        ]
        
        request.httpMethod = "POST"
        
        let (responseData, response) = try await URLSession.shared.data(for: request)
        
        guard (response as? HTTPURLResponse)?.statusCode == 201 else { throw DS3SDKError.serverError }
        guard let newApiKeys = try? JSONDecoder().decode(DS3ApiKey.self, from: responseData) else { throw DS3SDKError.jsonConversion }
        
        apiKeys.append(newApiKeys)
        
        try SharedData.shared.persistDS3APIKeys(apiKeys)
        
        return newApiKeys
    }
}
