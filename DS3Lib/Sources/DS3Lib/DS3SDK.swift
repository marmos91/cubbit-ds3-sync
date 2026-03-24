import Foundation
import os.log

/// Errors that can occur during DS3 SDK operations
public enum DS3SDKError: Error, LocalizedError {
    case invalidURL(url: String? = nil)
    case serverError
    case jsonConversion
    case encodingError
    
    public var errorDescription: String? {
        switch self {
        case .invalidURL(let url):
            return NSLocalizedString("Invalid URL: \(url ?? "")", comment: "Invalid URL")
        case .serverError:
            return NSLocalizedString("Server error", comment: "Server error")
        case .jsonConversion:
            return NSLocalizedString("JSON conversion error", comment: "JSON conversion error")
        case .encodingError:
            return NSLocalizedString("Encoding error", comment: "Encoding error")
        }
    }
}

/// Class that manages the communication with the DS3 API.
/// Provides methods for project listing, API key management, and key reconciliation.
@Observable public final class DS3SDK: @unchecked Sendable {
    private var authentication: DS3Authentication
    private let urls: CubbitAPIURLs
    private let logger: Logger = Logger(subsystem: LogSubsystem.app, category: LogCategory.auth.rawValue)

    public init(
        withAuthentication authentication: DS3Authentication,
        urls: CubbitAPIURLs? = nil
    ) {
        self.authentication = authentication
        self.urls = urls ?? authentication.urls
    }
    
    // MARK: - Projects
    
    /// Retrieves all the projects for the current user.
    /// - Returns: the list of projects for the current user.
    public func getRemoteProjects() async throws -> [Project] {
        try await self.authentication.refreshIfNeeded()
        
        guard let url = URL(string: self.urls.projectsURL) else { throw DS3AuthenticationError.invalidURL(url: self.urls.projectsURL) }
        guard let session = self.authentication.accountSession else { throw DS3AuthenticationError.loggedOut }
        
        var request = URLRequest(url: url)
        
        request.allHTTPHeaderFields = [
          "Content-Type": "application/json",
          "Authorization": "Bearer \(session.token.token)"
        ]
        
        request.httpMethod = "GET"
        
        let (responseData, response) = try await URLSession.shared.data(for: request)
        
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(data: responseData, encoding: .utf8) ?? "<non-UTF8>"
            self.logger.error("An error occurred. Status code is \(statusCode) Response is: \(body)")
            throw DS3AuthenticationError.serverError
        }
        guard let projects = try? JSONDecoder().decode([Project].self, from: responseData) else { throw DS3AuthenticationError.jsonConversion }
        
        return projects
    }
   
    // MARK: - API Keys
    
    /// This method retrieves all the API keys for the selected IAM user.
    /// - Parameter user: the IAM user for which to retrieve the API keys.
    /// - Returns: the list of API keys for the selected IAM user.
    public func getRemoteApiKeys(
        forIAMUser user: IAMUser
    ) async throws -> [DS3ApiKey] {
        let iamToken = try await authentication.forgeIAMToken(forIAMUser: user)
        
        guard let url = URL(string: "\(self.urls.keysURL)?user_id=\(user.id)") else {
            throw DS3SDKError.invalidURL(url: self.urls.keysURL)
        }
        
        var request = URLRequest(url: url)
        
        request.allHTTPHeaderFields = [
          "Authorization": "Bearer \(iamToken.token)"
        ]
        
        request.httpMethod = "GET"
        
        let (responseData, response) = try await URLSession.shared.data(for: request)
        
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(data: responseData, encoding: .utf8) ?? "<non-UTF8>"
            self.logger.error("An error occurred. Status code is \(statusCode) Response is: \(body)")
            throw DS3SDKError.serverError
        }
        guard let apiKeys = try? JSONDecoder().decode([DS3ApiKey].self, from: responseData) else { throw DS3SDKError.jsonConversion }
        
        return apiKeys
    }
    
    /// Deletes the given API key for the given IAM user.
    /// - Parameters:
    ///   - apiKey: the api key to delete.
    ///   - user: the IAM user for which to delete the API key.
    public func deleteApiKey(
        _ apiKey: DS3ApiKey,
        forIAMUser user: IAMUser
    ) async throws {
        let iamToken = try await authentication.forgeIAMToken(forIAMUser: user)
        
        guard let urlencodedApiKey = apiKey.apiKey.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { throw DS3SDKError.encodingError }
        
        guard let url = URL(string: "\(self.urls.keysURL)/\(urlencodedApiKey)?user_id=\(user.id)") else {
            throw DS3SDKError.invalidURL(url: self.urls.keysURL)
        }
        
        var request = URLRequest(url: url)
        
        request.allHTTPHeaderFields = [
          "Authorization": "Bearer \(iamToken.token)"
        ]
        
        request.httpMethod = "DELETE"
        
        let (responseData, response) = try await URLSession.shared.data(for: request)
        
        guard (response as? HTTPURLResponse)?.statusCode == 200 || (response as? HTTPURLResponse)?.statusCode == 204 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(data: responseData, encoding: .utf8) ?? "<non-UTF8>"
            self.logger.error("An error occurred. Status code is \(statusCode) Response is: \(body)")
            throw DS3SDKError.serverError
        }
    }
    
    /// Load API keys for the given iam user and ds3 project from disk, if already available. Otherwise creates a new pair and save it to disk
    /// - Parameters:
    ///   - user: the IAM user for which to load or create the API keys.
    ///   - ds3ProjectName: the name of the DS3 project for which to load or create the API keys.
    /// - Returns: the API keys for the given IAM user and DS3 project.
    public func loadOrCreateDS3APIKeys(
        forIAMUser user: IAMUser,
        ds3ProjectName: String
    ) async throws -> DS3ApiKey {
        let apiKeyName = DS3SDK.apiKeyName(forUser: user, projectName: ds3ProjectName)

        let localApiKeys = (try? SharedData.default().loadDS3APIKeysFromPersistence()) ?? []
        let localApiKey = localApiKeys.first(where: { $0.name == apiKeyName })

        let iamToken = try await authentication.forgeIAMToken(forIAMUser: user)

        let remoteApiKeys = try await self.getRemoteApiKeys(forIAMUser: user)
        let remoteApiKey = remoteApiKeys.first(where: { $0.name == apiKeyName })

        // If local matches remote, return local without generating a new key
        if let localApiKey, let remoteApiKey, localApiKey == remoteApiKey {
            self.logger.debug("Returning existing API key since it matches the remote one")
            return localApiKey
        }

        // Clean up stale keys before generating a new one
        if let remoteApiKey, localApiKey == nil {
            self.logger.debug("Deleting remote API key since it is not found locally")
            try await self.deleteApiKey(remoteApiKey, forIAMUser: user)
        }

        if let localApiKey, remoteApiKey == nil {
            self.logger.debug("Deleting local key since it is not found remotely")
            try SharedData.default().deleteDS3APIKeyFromPersistence(withName: localApiKey.name)
        }

        return try await self.generateDS3APIKey(forIAMUser: user, iamToken: iamToken, apiKeyName: apiKeyName)
    }
    
    /// Generates a new API key for the given IAM user.
    /// - Parameters:
    ///   - user: the IAM user for which to generate the API key.
    ///   - iamToken: the IAM token to use for authentication. You can generate one with `forgeIAMToken(forIAMUser:)`.
    ///   - apiKeyName: the name to give to the new API key.
    /// - Returns: the newly generated API key.
    public func generateDS3APIKey(
        forIAMUser user: IAMUser,
        iamToken: Token,
        apiKeyName: String
    ) async throws -> DS3ApiKey {
        guard let url = URL(string: "\(self.urls.keysURL)/\(apiKeyName)?user_id=\(user.id)") else {
            throw DS3SDKError.invalidURL(url: self.urls.keysURL)
        }
        
        self.logger.debug("Generating new API Key for IAM user: \(user.username)")
        
        var request = URLRequest(url: url)
        
        request.allHTTPHeaderFields = [
          "Authorization": "Bearer \(iamToken.token)"
        ]
        
        request.httpMethod = "POST"
        
        let (responseData, response) = try await URLSession.shared.data(for: request)
        
        guard (response as? HTTPURLResponse)?.statusCode == 201 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(data: responseData, encoding: .utf8) ?? "<non-UTF8>"
            self.logger.error("An error occurred. Status code is \(statusCode) Response is: \(body)")
            throw DS3SDKError.serverError
        }
        guard let newApiKey = try? JSONDecoder().decode(DS3ApiKey.self, from: responseData) else { throw DS3SDKError.jsonConversion }
        
        var localApiKeys = (try? SharedData.default().loadDS3APIKeysFromPersistence()) ?? []
        localApiKeys.append(newApiKey)
        
        try SharedData.default().persistDS3APIKeys(localApiKeys)
        
        return newApiKey
    }
    
    /// Returns an unique name for an API key for the given IAM user and DS3 project.
    /// - Parameters:
    ///   - user: the IAM user for which to generate the API key name.
    ///   - projectName: the project name for which to generate the API key name.
    /// - Returns: A unique name for an API key for the given IAM user and DS3 project.
    public static func apiKeyName(
        forUser user: IAMUser,
        projectName: String
    ) -> String {
        return "\(DefaultSettings.apiKeyNamePrefix)(\(user.username)_\(projectName.lowercased().replacingOccurrences(of: " ", with: "_"))_\(DefaultSettings.appUUID))"
    }
}
