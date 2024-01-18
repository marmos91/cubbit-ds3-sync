import Foundation
import os.log

enum DS3SDKError: Error, LocalizedError {
    case invalidURL(url: String? = nil)
    case serverError
    case jsonConversion
    case encodingError
}

@Observable class DS3SDK {
    private var authentication: DS3Authentication
    private let logger: Logger = Logger(subsystem: "com.cubbit.CubbitDS3Sync", category: "DS3SDK")
    
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
        
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            self.logger.error("An error occurred. Status code is \((response as! HTTPURLResponse).statusCode) Response is: \(String(data: responseData, encoding: .utf8)!)")
            throw DS3AuthenticationError.serverError
        }
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
        
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            self.logger.error("An error occurred. Status code is \((response as! HTTPURLResponse).statusCode) Response is: \(String(data: responseData, encoding: .utf8)!)")
            throw DS3SDKError.serverError
        }
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
        
        let (responseData, response) = try await URLSession.shared.data(for: request)
        
        guard (response as? HTTPURLResponse)?.statusCode == 200 || (response as? HTTPURLResponse)?.statusCode == 204 else {
            self.logger.error("An error occurred. Status code is \((response as! HTTPURLResponse).statusCode) Response is \(String(data: responseData, encoding: .utf8)!)")
            throw DS3SDKError.serverError
        }
    }
    
    /// Load API keys for the given iam user and ds3 project from disk, if already available. Otherwise creates a new pair and save it to disk
    func loadOrCreateDS3APIKeys(forIAMUser user: IAMUser, ds3ProjectName: String) async throws -> DS3ApiKey {
        let apiKeyName = apiKeyName(forUser: user, projectName: ds3ProjectName)
        
        let localApiKeys = (try? SharedData.shared.loadDS3APIKeysFromPersistence()) ?? []
        let localApiKey = localApiKeys.first(where: {$0.name == apiKeyName})
        
        let iamToken = try await authentication.forgeIAMToken(forIAMUser: user)
        
        let remoteApiKeys = try await self.getRemoteApiKeys(forIAMUser: user)
        let remoteApiKey = remoteApiKeys.first(where: {$0.name == apiKeyName})
        
        if localApiKey == nil {
            if remoteApiKey != nil {
                // If local does not exists and remote with name exists, delete remote and generate a new one
                self.logger.debug("Deleting remote API key since it is not found locally")
                try await self.deleteApiKey(remoteApiKey!, forIAMUser: user)
            }
                        
            return try await self.generateDS3APIKey(forIAMUser: user, iamToken: iamToken, apiKeyName: apiKeyName)
        } else {
            // If local key exists already
            if remoteApiKey != nil {
                if localApiKey == remoteApiKey {
                    // If local matches remote return local without generating
                    self.logger.debug("Returning existing API key since it matches the remote one")
                    return localApiKey!
                }
                
                // Otherwise create a new key
                return try await self.generateDS3APIKey(forIAMUser: user, iamToken: iamToken, apiKeyName: apiKeyName)
            } else {
                self.logger.debug("Deleting local key since it is not found remotely")
                // If local exists and remote does not, delete local and generate a new one
                try SharedData.shared.deleteDS3APIKeyFromPersistence(withName: localApiKey!.name)
                
                return try await self.generateDS3APIKey(forIAMUser: user, iamToken: iamToken, apiKeyName: apiKeyName)
            }
        }
    }
    
    func generateDS3APIKey(forIAMUser user: IAMUser, iamToken: Token, apiKeyName: String) async throws -> DS3ApiKey {
        guard let url = URL(string: "\(CubbitAPIURLs.keyvault.createKeyURL)/\(apiKeyName)?user_id=\(user.id)") else {
            throw DS3SDKError.invalidURL(url: CubbitAPIURLs.IAM.auth.challengeURL)
        }
        
        self.logger.debug("Generating new API Key for IAM user: \(user.username)")
        
        var request = URLRequest(url: url)
        
        request.allHTTPHeaderFields = [
          "Authorization": "Bearer \(iamToken.token)"
        ]
        
        request.httpMethod = "POST"
        
        let (responseData, response) = try await URLSession.shared.data(for: request)
        
        guard (response as? HTTPURLResponse)?.statusCode == 201 else {
            self.logger.error("An error occurred. Status code is \((response as! HTTPURLResponse).statusCode) Response is: \(String(data: responseData, encoding: .utf8)!)")
            throw DS3SDKError.serverError
        }
        guard let newApiKey = try? JSONDecoder().decode(DS3ApiKey.self, from: responseData) else { throw DS3SDKError.jsonConversion }
        
        var localApiKeys = (try? SharedData.shared.loadDS3APIKeysFromPersistence()) ?? []
        localApiKeys.append(newApiKey)
        
        try SharedData.shared.persistDS3APIKeys(localApiKeys)
        
        return newApiKey
    }
}
