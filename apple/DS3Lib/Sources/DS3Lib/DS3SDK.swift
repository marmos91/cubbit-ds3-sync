import DS3CoreFFI
import Foundation
import os.log

/// Errors that can occur during DS3 SDK operations
public enum DS3SDKError: Error, LocalizedError {
    case invalidURL(url: String? = nil)
    case serverError
    case jsonConversion
    case encodingError
    case loggedOut

    public var errorDescription: String? {
        switch self {
        case let .invalidURL(url):
            NSLocalizedString("Invalid URL: \(url ?? "")", comment: "Invalid URL")
        case .serverError:
            NSLocalizedString("Server error", comment: "Server error")
        case .jsonConversion:
            NSLocalizedString("JSON conversion error", comment: "JSON conversion error")
        case .encodingError:
            NSLocalizedString("Encoding error", comment: "Encoding error")
        case .loggedOut:
            NSLocalizedString(
                "You need to be logged in to perform this operation",
                comment: "DS3SDK logged out error"
            )
        }
    }
}

extension DS3SDKError {
    /// Translates a Rust `Ds3Error` (UniFFI flat-error shape) into the
    /// corresponding `DS3SDKError` case. Mirrors `DS3AuthenticationError.translate`
    /// but routes auth-level codes (1005/1006/1007) to `.serverError` because
    /// the SDK never re-prompts for 2FA (that path is owned by login UI). The
    /// LoggedOut path is the only one that flows through verbatim so callers
    /// can route back to login on session loss.
    static func translate(_ rust: Ds3Error) -> DS3SDKError {
        let message = DS3AuthenticationError.describe(rust)
        let code = ds3ErrorCode(message: message)
        switch code {
        case 1001: return .invalidURL(url: nil)
        case 1003: return .jsonConversion
        case 1004: return .encodingError
        case 1005: return .loggedOut
        // 1002 server, 1006 expired, 1007 missing 2FA, 1008 cookies, 3xxx transport
        // — all surfaced as serverError so the caller backs off / retries.
        default: return .serverError
        }
    }
}

/// Class that manages the communication with the DS3 API.
///
/// Phase 16 Plan 04: provides methods for project listing, API key management,
/// and key reconciliation. URLSession + manual Bearer-token plumbing has been
/// replaced with calls to `Ds3SessionHandle` (DS3CoreFFI). The Rust handle is
/// owned by `DS3Authentication`; the SDK borrows it lazily.
///
/// Per-method behavior: every public method short-circuits with
/// `DS3AuthenticationError.loggedOut` if `authentication.handle` is `nil` (i.e.
/// after `loadFromPersistenceOrCreateNew` restores from disk — see Plan 04
/// SUMMARY §"Known Regressions"). The reconciliation helper
/// `loadOrCreateDS3APIKeys` keeps its Swift orchestration; only the underlying
/// CRUD methods change.
@Observable
public final class DS3SDK: @unchecked Sendable {
    private var authentication: DS3Authentication
    private let urls: CubbitAPIURLs
    private let sharedData: SharedData
    private let logger = Logger(subsystem: LogSubsystem.app, category: LogCategory.auth.rawValue)

    public init(
        withAuthentication authentication: DS3Authentication,
        urls: CubbitAPIURLs? = nil,
        sharedData: SharedData = SharedData.default()
    ) {
        self.authentication = authentication
        self.urls = urls ?? authentication.urls
        self.sharedData = sharedData
    }

    // MARK: - Projects

    /// Retrieves all the projects for the current user.
    /// - Returns: the list of projects for the current user.
    public func getRemoteProjects() async throws -> [Project] {
        guard let handle = self.authentication.handle else {
            throw DS3AuthenticationError.loggedOut
        }

        do {
            let ffiProjects = try handle.getProjects()
            return ffiProjects.map { Project.fromFFI($0) }
        } catch let rustError as Ds3Error {
            self.logger.error(
                "getRemoteProjects failed: code=\(ds3ErrorCode(message: DS3AuthenticationError.describe(rustError)), privacy: .public) \(DS3AuthenticationError.describe(rustError), privacy: .public)"
            )
            throw DS3SDKError.translate(rustError)
        }
    }

    // MARK: - API Keys

    /// This method retrieves all the API keys for the selected IAM user.
    /// - Parameter user: the IAM user for which to retrieve the API keys.
    /// - Returns: the list of API keys for the selected IAM user.
    public func getRemoteApiKeys(
        forIAMUser user: IAMUser
    ) async throws -> [DS3ApiKey] {
        guard let handle = self.authentication.handle else {
            throw DS3AuthenticationError.loggedOut
        }

        let iamToken = try await authentication.forgeIAMToken(forIAMUser: user)

        do {
            let ffiKeys = try handle.loadApiKeys(userId: user.id, iamToken: iamToken.token)
            return try ffiKeys.map { try DS3ApiKey.fromFFI($0) }
        } catch let rustError as Ds3Error {
            self.logger.error(
                "getRemoteApiKeys failed: code=\(ds3ErrorCode(message: DS3AuthenticationError.describe(rustError)), privacy: .public) \(DS3AuthenticationError.describe(rustError), privacy: .public)"
            )
            throw DS3SDKError.translate(rustError)
        }
    }

    /// Deletes the given API key for the given IAM user.
    /// - Parameters:
    ///   - apiKey: the api key to delete.
    ///   - user: the IAM user for which to delete the API key.
    public func deleteApiKey(
        _ apiKey: DS3ApiKey,
        forIAMUser user: IAMUser
    ) async throws {
        guard let handle = self.authentication.handle else {
            throw DS3AuthenticationError.loggedOut
        }

        let iamToken = try await authentication.forgeIAMToken(forIAMUser: user)

        do {
            try handle.deleteApiKey(
                userId: user.id,
                apiKeyId: apiKey.apiKey,
                iamToken: iamToken.token
            )
        } catch let rustError as Ds3Error {
            self.logger.error(
                "deleteApiKey failed: code=\(ds3ErrorCode(message: DS3AuthenticationError.describe(rustError)), privacy: .public) \(DS3AuthenticationError.describe(rustError), privacy: .public)"
            )
            throw DS3SDKError.translate(rustError)
        }
    }

    /// Load API keys for the given iam user and ds3 project from disk, if already available. Otherwise creates a new
    /// pair and save it to disk
    /// - Parameters:
    ///   - user: the IAM user for which to load or create the API keys.
    ///   - ds3ProjectName: the name of the DS3 project for which to load or create the API keys.
    /// - Returns: the API keys for the given IAM user and DS3 project.
    public func loadOrCreateDS3APIKeys(
        forIAMUser user: IAMUser,
        ds3ProjectName: String
    ) async throws -> DS3ApiKey {
        let apiKeyName = DS3SDK.apiKeyName(forUser: user, projectName: ds3ProjectName)

        let localApiKeys = (try? sharedData.loadDS3APIKeysFromPersistence()) ?? []
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
            try sharedData.deleteDS3APIKeyFromPersistence(withName: localApiKey.name)
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
        guard let handle = self.authentication.handle else {
            throw DS3AuthenticationError.loggedOut
        }

        self.logger.debug("Generating new API Key for IAM user: \(user.username, privacy: .public)")

        let newApiKey: DS3ApiKey
        do {
            let ffiKey = try handle.createApiKey(
                userId: user.id,
                keyName: apiKeyName,
                iamToken: iamToken.token
            )
            newApiKey = try DS3ApiKey.fromFFI(ffiKey)
        } catch let rustError as Ds3Error {
            self.logger.error(
                "generateDS3APIKey failed: code=\(ds3ErrorCode(message: DS3AuthenticationError.describe(rustError)), privacy: .public) \(DS3AuthenticationError.describe(rustError), privacy: .public)"
            )
            throw DS3SDKError.translate(rustError)
        }

        var localApiKeys = (try? sharedData.loadDS3APIKeysFromPersistence()) ?? []
        localApiKeys.append(newApiKey)

        try sharedData.persistDS3APIKeys(localApiKeys)

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
        // swiftlint:disable:next line_length
        "\(DefaultSettings.apiKeyNamePrefix)(\(user.username)_\(projectName.lowercased().replacingOccurrences(of: " ", with: "_"))_\(DefaultSettings.appUUID))"
    }
}
