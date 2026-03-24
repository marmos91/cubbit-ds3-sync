import Foundation
import CryptoKit
import os.log

/// Errors that can occur during authentication with Cubbit IAM
public enum DS3AuthenticationError: Error, LocalizedError {
    case invalidURL(url: String? = nil)
    case timeConversion
    case cookies
    case encoding
    case serverError
    case jsonConversion
    case loggedOut
    case alreadyLoggedIn
    case alreadyLoggedOut
    case tokenExpired
    case missing2FA
    
    public var errorDescription: String? {
        switch self {
        case .invalidURL(let url):
            return NSLocalizedString("The provided URL \(url ?? "") is invalid.", comment: "The invalidURL error")
        case .timeConversion:
            return NSLocalizedString("Cannot convert time string", comment: "The time conversion error")
        case .serverError:
            return NSLocalizedString("There was an error with the server.\nPlease try again later", comment: "The server error")
        case .jsonConversion:
            return NSLocalizedString("There was an error while converting JSON data.", comment: "The JSON conversion error")
        case .cookies:
            return NSLocalizedString("Cannot retrieve cookies", comment: "The cookies authentication error")
        case .encoding:
            return NSLocalizedString("There was an error while encoding/decoding data.", comment: "The encoding authentication error")
        case .loggedOut:
            return NSLocalizedString("You need to be logged in to perform this operation", comment: "The authentication already logged error")
        case .alreadyLoggedIn:
            return NSLocalizedString("You are already logged in", comment: "The already logged in error")
        case .alreadyLoggedOut:
            return NSLocalizedString("You are already logged out", comment: "The already logged out error")
        case .tokenExpired:
            return NSLocalizedString("The session token expired", comment: "Token expiration error")
        case .missing2FA:
            return NSLocalizedString("Missing 2FA code", comment: "Missing 2FA code")
        }
    }
}

enum APIError {
    static let Missing2FA = "missing two factor code"
}

/// Request to retrieve the challenge for the login
struct DS3ChallengeRequest: Codable {
    /// The user email
    var email: String

    /// Optional tenant identifier for multi-tenant login
    var tenantId: String?

    enum CodingKeys: String, CodingKey {
        case email
        case tenantId = "tenant_id"
    }
}

/// Login request through the DS3 APIs
struct DS3LoginRequest: Codable {
    /// The user email
    var email: String

    /// The retrieved challenge signed with the user private key (you can retrieve the challenge through the `DS3ChallengeRequest`)
    var signedChallenge: String

    /// Optional: the 2FA code if the user has enabled it
    var tfaCode: String?

    /// Optional tenant identifier for multi-tenant login
    var tenantId: String?

    enum CodingKeys: String, CodingKey {
        case email
        case signedChallenge
        case tfaCode = "tfa_code"
        case tenantId = "tenant_id"
    }
}

/// Response for the login request
struct DS3Missing2FAResponse: Codable {
    var message: String
}

/// Class that manages the authentication with the DS3 APIs.
/// Uses challenge-response (Curve25519) authentication with JWT tokens.
@Observable public final class DS3Authentication: @unchecked Sendable {
    private let logger: Logger = Logger(subsystem: LogSubsystem.app, category: LogCategory.auth.rawValue)

    /// The URL configuration for all API calls
    public var urls: CubbitAPIURLs

    /// The current account session, if authenticated
    public var accountSession: AccountSession?

    /// The current account information, if authenticated
    public var account: Account?

    /// Whether the user is currently logged in
    public var isLogged: Bool = false

    /// Whether the user is currently logged out
    public var isNotLogged: Bool {
        !self.isLogged
    }

    public init(urls: CubbitAPIURLs = CubbitAPIURLs()) {
        self.urls = urls
    }

    public init(
        accountSession: AccountSession,
        account: Account,
        isLogged: Bool,
        urls: CubbitAPIURLs = CubbitAPIURLs()
    ) {
        self.urls = urls
        self.accountSession = accountSession
        self.account = account
        self.isLogged = isLogged
    }
    
    // MARK: - Tokens

    /// Forges an IAM token for the specified user. The IAM token will be then used to authenticate all the next requests for the specified user
    /// - Parameter user: the IAM user for which you want to forge the token
    /// - Returns: the Token object containing the access token and the expiration date
    public func forgeIAMToken(forIAMUser user: IAMUser) async throws -> Token {
        try await self.refreshIfNeeded()

        guard
            self.isLogged,
            let session = self.accountSession
        else { throw DS3AuthenticationError.loggedOut }

        guard let url = URL(string: "\(self.urls.forgeAccessJWTURL)?user_id=\(user.id)") else {
            throw DS3AuthenticationError.invalidURL(
                url: self.urls.forgeAccessJWTURL
            )
        }

        var request = URLRequest(url: url)

        self.logger.debug("Forging IAM token for user \(user.id)")

        request.allHTTPHeaderFields = [
            "Content-Type": "application/json",
            "Cookie": "_refresh=\(session.refreshToken)"
        ]
        request.httpShouldHandleCookies = true
        request.httpMethod = "GET"

        let (responseData, response) = try await URLSession.shared.data(for: request)

        let (token, newRefreshToken) = try self.parseTokenResponse(data: responseData, response: response, url: url)

        session.refreshRefreshToken(refreshToken: newRefreshToken)

        try self.persist()

        return token
    }
    
    // MARK: - Proactive Refresh

    /// Returns true if the token should be refreshed (within threshold of expiry).
    /// - Parameters:
    ///   - token: The token to check
    ///   - threshold: Seconds before expiry to trigger refresh (default: 300 = 5 minutes)
    public static func shouldRefreshToken(_ token: Token, threshold: TimeInterval = 300) -> Bool {
        token.expDate.timeIntervalSinceNow <= threshold
    }

    /// Starts a background Task that checks token expiry every 60 seconds and refreshes proactively.
    /// Returns the Task so the caller can cancel it when no longer needed.
    @discardableResult
    public func startProactiveRefreshTimer() -> Task<Void, Never> {
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard let self, self.isLogged, let session = self.accountSession else { continue }

                if DS3Authentication.shouldRefreshToken(session.token) {
                    do {
                        try await self.refreshIfNeeded(force: true)
                        self.logger.info("Proactive token refresh successful")
                    } catch {
                        self.logger.error("Proactive token refresh failed: \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    // MARK: - Refresh

    /// Refresh auth token if expired
    /// - Parameter force: force token refresh
    public func refreshIfNeeded(force: Bool = false) async throws {
        guard
            self.isLogged,
            let session = self.accountSession
        else { throw DS3AuthenticationError.loggedOut }

        guard force || Date() > session.token.expDate else { return }

        self.logger.debug("Refreshing access token")

        guard let url = URL(string: self.urls.tokenRefreshURL) else { throw DS3AuthenticationError.invalidURL() }

        var request = URLRequest(url: url)

        request.allHTTPHeaderFields = [
            "Content-Type": "application/json",
            "Cookie": "_refresh=\(session.refreshToken)"
        ]
        request.httpShouldHandleCookies = true
        request.httpMethod = "GET"

        let (responseData, response) = try await URLSession.shared.data(for: request)

        let (token, refreshToken) = try self.parseTokenResponse(data: responseData, response: response, url: url)

        session.refreshTokens(token: token, refreshToken: refreshToken)

        try self.persist()
    }
    
    // MARK: - Login
    
    /// Logs in to Cubbit's IAM service
    ///  - Parameters:
    ///   - email: the email to login with
    ///   - password: the password to login with
    ///   - tfaCode: optional 2FA code
    ///   - tenant: optional tenant identifier for multi-tenant login
    public func login(email: String, password: String, withTfaToken tfaCode: String? = nil, tenant: String? = nil) async throws {
        guard self.isNotLogged else { throw DS3AuthenticationError.alreadyLoggedIn }

        let challenge = try await self.getChallenge(email: email, tenant: tenant)
        let signedChallenge = try self.signChallenge(challenge: challenge, password: password)
        let accountSession = try await self.getAccountSession(email: email, signedChallengeBase64: signedChallenge, withTfaToken: tfaCode, tenant: tenant)

        self.accountSession = accountSession
        self.isLogged = true

        self.account = try await self.accountInfo()
    }

    /// Logs out from Cubbit's IAM service
    public func logout() {
        guard self.isLogged else { return }

        self.logger.debug("Logging out...")

        self.accountSession = nil
        self.account = nil
        self.isLogged = false

        // Best-effort disk cleanup — missing files should not prevent logout
        do {
            try self.deleteFromDisk()
        } catch {
            self.logger.warning("Disk cleanup during logout failed: \(error.localizedDescription, privacy: .public)")
        }
    }
    
    /// Gets a challenge from Cubbit's IAM service
    /// - Parameters:
    ///   - email: the email you want to get the challenge for
    ///   - tenant: optional tenant identifier for multi-tenant login
    /// - Returns: the challenge
    public func getChallenge(email: String, tenant: String? = nil) async throws -> Challenge {
        guard let url = URL(string: self.urls.challengeURL) else { throw DS3AuthenticationError.invalidURL(url: self.urls.challengeURL) }

        let challengeRequestBody = DS3ChallengeRequest(email: email, tenantId: tenant)
        
        self.logger.debug("Retrieving challenge for email \(email)")
        
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(challengeRequestBody) else { throw DS3AuthenticationError.jsonConversion }
        
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpMethod = "POST"
        request.httpBody = data
        
        let (responseData, response) = try await URLSession.shared.data(for: request)
        
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw DS3AuthenticationError.serverError }
        guard let challenge = try? JSONDecoder().decode(Challenge.self, from: responseData) else { throw DS3AuthenticationError.jsonConversion }
        
        self.logger.debug("Challenge retrieved")
        
        return challenge
    }
    
    /// Sign a provided challenge with a private key generated from user's password
    /// - Parameters:
    ///   - challenge: the challenge to sign
    ///   - password: the password to use to sign the challenge
    /// - Returns: the signed challenge in base64 format
    public func signChallenge(challenge: Challenge, password: String) throws -> String {
        guard let passwordBuffer = password.data(using: .utf8) else { throw DS3AuthenticationError.encoding }
        guard let saltBuffer = challenge.salt.data(using: .utf8) else { throw DS3AuthenticationError.encoding }
        
        self.logger.debug("Signing challenge")
        
        let buffer = passwordBuffer + saltBuffer
        
        var sha = SHA256()
        sha.update(data: buffer)
        let seed = sha.finalize()
        
        let keychain = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        
        guard let challengeData = challenge.challenge.data(using: .utf8) else {
            throw DS3AuthenticationError.encoding
        }
        let signedChallenge = try keychain.signature(for: challengeData)
        
        self.logger.debug("Challenge signed")
        
        return signedChallenge.base64EncodedString()
    }
    
    /// Retrieves an account session token using a challenge and an email. To generate the signed challenge refer to the `signChallenge` method
    /// - Parameters:
    ///   - email: the email related to the account session to retrieve
    ///   - signedChallengeBase64: the signed challenge to use for signin in the account
    /// - Returns: the session for the provided email
    public func getAccountSession(email: String, signedChallengeBase64: String, withTfaToken tfaCode: String? = nil, tenant: String? = nil) async throws -> AccountSession {
        guard let url = URL(string: self.urls.signinURL) else { throw DS3AuthenticationError.invalidURL(url: self.urls.signinURL) }

        let accountSessionRequest = DS3LoginRequest(email: email, signedChallenge: signedChallengeBase64, tfaCode: tfaCode, tenantId: tenant)

        self.logger.debug("Getting account session for email \(email)")

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        guard let data = try? encoder.encode(accountSessionRequest) else { throw DS3AuthenticationError.encoding }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpMethod = "POST"
        request.httpBody = data

        let (responseData, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            if let mfaResponse = try? JSONDecoder().decode(DS3Missing2FAResponse.self, from: responseData),
               mfaResponse.message == APIError.Missing2FA {
                throw DS3AuthenticationError.missing2FA
            }

            throw DS3AuthenticationError.serverError
        }

        let (token, refreshToken) = try self.parseTokenResponse(data: responseData, response: response, url: url)

        self.logger.debug("Account session retrieved")

        return AccountSession(token: token, refreshToken: refreshToken)
    }
    
    // MARK: - Response Parsing

    /// Parses a token and refresh cookie from an HTTP response.
    /// Shared by `forgeIAMToken`, `refreshIfNeeded`, and `getAccountSession`.
    private func parseTokenResponse(data: Data, response: URLResponse, url: URL) throws -> (token: Token, refreshToken: String) {
        guard
            let httpResponse = response as? HTTPURLResponse,
            httpResponse.statusCode == 200
        else { throw DS3AuthenticationError.tokenExpired }

        guard let token = try? JSONDecoder().decode(Token.self, from: data) else { throw DS3AuthenticationError.jsonConversion }

        guard let fields = httpResponse.allHeaderFields as? [String: String] else { throw DS3AuthenticationError.serverError }

        let cookies = HTTPCookie.cookies(withResponseHeaderFields: fields, for: url)

        guard let refreshToken = cookies.first(where: { $0.name == "_refresh" })?.value else { throw DS3AuthenticationError.cookies }

        return (token, refreshToken)
    }

    // MARK: - Persistence
   
    public func persist() throws {
        guard
            self.isLogged,
            let accountSession = self.accountSession,
            let account = self.account
        else { throw DS3AuthenticationError.loggedOut }

        let sharedData = SharedData.default()
        try sharedData.persistAccountSession(accountSession: accountSession)
        try sharedData.persistAccount(account: account)
    }
    
    /// Loads authentication state from shared container, or creates a new unauthenticated instance.
    /// - Parameter urls: The URL configuration to use. Defaults to the standard coordinator.
    public static func loadFromPersistenceOrCreateNew(urls: CubbitAPIURLs = CubbitAPIURLs()) -> DS3Authentication {
        do {
            let sharedData = SharedData.default()
            let accountSession = try sharedData.loadAccountSessionFromPersistence()
            let account = try sharedData.loadAccountFromPersistence()

            return DS3Authentication(
                accountSession: accountSession,
                account: account,
                isLogged: true,
                urls: urls
            )
        } catch {
            return DS3Authentication(urls: urls)
        }
    }
    
    /// Deletes all persisted authentication data from disk.
    public func deleteFromDisk() throws {
        UserDefaults.standard.removeObject(forKey: DefaultSettings.UserDefaultsKeys.tutorial)
        let sharedData = SharedData.default()
        try sharedData.deleteAccountSessionFromPersistence()
        try sharedData.deleteAccountFromPersistence()
        try sharedData.deleteDS3DrivesFromPersistence()
        try sharedData.deleteDS3APIKeysFromPersistence()
    }

    // MARK: - Account
    
    /// Retrieves Cubbit's account info
    /// - Returns: info about Cubbit's account
    public func accountInfo() async throws -> Account {
        guard self.isLogged else { throw DS3AuthenticationError.loggedOut }
        
        try await self.refreshIfNeeded()
        
        guard let session = self.accountSession else { throw DS3AuthenticationError.loggedOut }
        guard let url = URL(string: self.urls.accountsMeURL) else { throw DS3AuthenticationError.invalidURL(url: self.urls.accountsMeURL) }

        var request = URLRequest(url: url)

        request.allHTTPHeaderFields = [
          "Content-Type": "application/json",
          "Authorization": "Bearer \(session.token.token)"
        ]
        
        request.httpMethod = "GET"
        
        let (responseData, response) = try await URLSession.shared.data(for: request)
        
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw DS3AuthenticationError.serverError }
        guard let account = try? JSONDecoder().decode(Account.self, from: responseData) else { throw DS3AuthenticationError.jsonConversion }
        
        return account
    }
}
