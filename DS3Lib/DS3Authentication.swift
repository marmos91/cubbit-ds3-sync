import Foundation
import CryptoKit
import SwiftUI
import os.log

enum DS3AuthenticationError: Error, LocalizedError {
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
    
    var errorDescription: String? {
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
}

/// Login request through the DS3 APIs
struct DS3LoginRequest: Codable {
    /// The user email
    var email: String
    
    /// The retrieved challenge signed with the user private key (you can retrieve the challenge through the `DS3ChallengeRequest`)
    var signedChallenge: String
    
    /// Optional: the 2FA code if the user has enabled it
    var tfaCode: String?
    
    enum CodingKeys: String, CodingKey {
        case email
        case signedChallenge
        case tfaCode = "tfa_code"
    }
}

/// Response for the login request
struct DS3Missing2FAResponse: Codable {
    var message: String
}

/// Class that manages the authentication with the DS3 APIs
@Observable final class DS3Authentication {
    private let logger: Logger = Logger(subsystem: "io.cubbit.CubbitDS3Sync.DS3Lib", category: "DS3Authentication")
    
    var accountSession: AccountSession?
    var account: Account?
    
    var isLogged: Bool = false
    
    var isNotLogged: Bool {
        return !self.isLogged
    }
    
    init() {
        self.accountSession = nil
        self.isLogged = false
    }
    
    init(
        accountSession: AccountSession,
        account: Account,
        isLogged: Bool
    ) {
        self.accountSession = accountSession
        self.account = account
        self.isLogged = isLogged
    }
    
    // MARK: - Tokens
    
    /// Forges an IAM token for the specified user. The IAM token will be then used to authenticate all the next requests for the specified user
    /// - Parameter user: the IAM user for which you want to forge the token
    /// - Returns: the Token object containing the access token and the expiration date
    func forgeIAMToken(forIAMUser user: IAMUser) async throws -> Token {
        try await self.refreshIfNeeded()
        
        guard
            self.isLogged,
            let session = self.accountSession
        else { throw DS3AuthenticationError.loggedOut }
        
        guard let url = URL(string: "\(CubbitAPIURLs.IAM.auth.forgeAccessJWTURL)?user_id=\(user.id)") else {
            throw DS3AuthenticationError.invalidURL(
                url: CubbitAPIURLs.IAM.auth.forgeAccessJWTURL
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
        
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw DS3AuthenticationError.tokenExpired }
        guard let token = try? JSONDecoder().decode(Token.self, from: responseData) else { throw DS3AuthenticationError.jsonConversion }
        
        guard
            let httpResponse = response as? HTTPURLResponse,
            let fields = httpResponse.allHeaderFields as? [String: String]
        else { throw DS3AuthenticationError.serverError }
        
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: fields, for: url)
        
        guard let refreshToken = cookies.first(where: {$0.name == "_refresh"})?.value else { throw DS3AuthenticationError.cookies }
        
        session.refreshRefreshToken(refreshToken: refreshToken)
        
        try self.persist()
        
        return token
    }
    
    // MARK: - Refresh
    
     /// Refresh auth token if expired
    /// - Parameter force: force token refresh
    func refreshIfNeeded(force: Bool = false) async throws {
        guard
            self.isLogged,
            let session = self.accountSession
        else { throw DS3AuthenticationError.loggedOut }
        
        let now = Date()
        let expiration = session.token.expDate

        if force || (now > expiration) {
            self.logger.debug("Refreshing access token")
            
            guard let url = URL(string: CubbitAPIURLs.IAM.auth.tokenRefreshURL) else { throw DS3AuthenticationError.invalidURL() }
            
            var request = URLRequest(url: url)

            request.allHTTPHeaderFields = [
                "Content-Type": "application/json",
                "Cookie": "_refresh=\(session.refreshToken)"
            ]
            request.httpShouldHandleCookies = true
            request.httpMethod = "GET"
    
            let (responseData, response) = try await URLSession.shared.data(for: request)
            
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw DS3AuthenticationError.tokenExpired }
            guard let token = try? JSONDecoder().decode(Token.self, from: responseData) else { throw DS3AuthenticationError.jsonConversion }
            
            guard
                let httpResponse = response as? HTTPURLResponse,
                let fields = httpResponse.allHeaderFields as? [String: String]
            else { throw DS3AuthenticationError.serverError }
            
            let cookies = HTTPCookie.cookies(withResponseHeaderFields: fields, for: url)
            
            guard let refreshToken = cookies.first(where: {$0.name == "_refresh"})?.value else { throw DS3AuthenticationError.cookies }
            
            session.refreshTokens(token: token, refreshToken: refreshToken)
            
            try self.persist()
        }
    }
    
    // MARK: - Login
    
    /// Logs in to Cubbit's IAM service
    ///  - Parameters:
    ///   - email: the email to login with
    ///   - password: the password to login with
    func login(email: String, password: String, withTfaToken tfaCode: String? = nil) async throws {
        guard self.isNotLogged else { throw DS3AuthenticationError.alreadyLoggedIn }
        
        let challenge = try await self.getChallenge(email: email)
        let signedChallenge = try self.signChallenge(challenge: challenge, password: password)
        let accountSession = try await self.getAccountSession(email: email, signedChallengeBase64: signedChallenge, withTfaToken: tfaCode)
        
        self.accountSession = accountSession
        self.isLogged = true
        
        self.account = try await self.accountInfo()
    }

    /// Logs out from Cubbit's IAM service
    func logout() throws {
        guard self.isLogged else { throw DS3AuthenticationError.alreadyLoggedOut }
        
        self.logger.debug("Logging out...")
        
        try self.deleteFromDisk()
        
        self.accountSession = nil
        self.isLogged = false
    }
    
    /// Gets a challenge from Cubbit's IAM service
    /// - Parameter email: the email you want to get the challenge for
    /// - Returns: the challenge
    func getChallenge(email: String) async throws -> Challenge {
        guard let url = URL(string: CubbitAPIURLs.IAM.auth.challengeURL) else { throw DS3AuthenticationError.invalidURL(url: CubbitAPIURLs.IAM.auth.challengeURL) }
        
        let challengeRequestBody = DS3ChallengeRequest(email: email)
        
        self.logger.debug("Retrieving challenge for email \(email)")
        
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(challengeRequestBody) else { throw DS3AuthenticationError.jsonConversion}
        
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
    func signChallenge(challenge: Challenge, password: String) throws -> String {
        guard let passwordBuffer = password.data(using: .utf8) else { throw DS3AuthenticationError.encoding }
        guard let saltBuffer = challenge.salt.data(using: .utf8) else { throw DS3AuthenticationError.encoding }
        
        self.logger.debug("Signing challenge")
        
        let buffer = passwordBuffer + saltBuffer
        
        var sha = SHA256()
        sha.update(data: buffer)
        let seed = sha.finalize()
        
        let keychain = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        
        let signedChallenge = try keychain.signature(for: challenge.challenge.data(using: .utf8)!)
        
        self.logger.debug("Challenge signed")
        
        return signedChallenge.base64EncodedString()
    }
    
    /// Retrieves an account session token using a challenge and an email. To generate the signed challenge refer to the `signChallenge` method
    /// - Parameters:
    ///   - email: the email related to the account session to retrieve
    ///   - signedChallengeBase64: the signed challenge to use for signin in the account
    /// - Returns: the session for the provided email
    func getAccountSession(email: String, signedChallengeBase64: String, withTfaToken tfaCode: String? = nil) async throws -> AccountSession {
        guard let url = URL(string: CubbitAPIURLs.IAM.auth.signinURL) else { throw DS3AuthenticationError.invalidURL(url: CubbitAPIURLs.IAM.auth.signinURL) }
        
        let accountSessionRequest = DS3LoginRequest(email: email, signedChallenge: signedChallengeBase64, tfaCode: tfaCode)
        
        self.logger.debug("Getting account session for email \(email)")
        
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        guard let data = try? encoder.encode(accountSessionRequest) else { throw DS3AuthenticationError.encoding}
        
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpMethod = "POST"
        request.httpBody = data
        
        let (responseData, response) = try await URLSession.shared.data(for: request)
        
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            if let MFAResponse = try? JSONDecoder().decode(DS3Missing2FAResponse.self, from: responseData) {
                if MFAResponse.message == APIError.Missing2FA {
                    throw DS3AuthenticationError.missing2FA
                }
            }
            
            throw DS3AuthenticationError.serverError
        }
        guard let token = try? JSONDecoder().decode(Token.self, from: responseData) else { throw DS3AuthenticationError.jsonConversion }
        
        guard
            let httpResponse = response as? HTTPURLResponse,
            let fields = httpResponse.allHeaderFields as? [String: String]
        else { throw DS3AuthenticationError.serverError }
        
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: fields, for: url)
        
        guard let refreshToken = cookies.first(where: {$0.name == "_refresh"})?.value else { throw DS3AuthenticationError.cookies }
        
        self.logger.debug("Account session retrieved")
        
        return AccountSession(token: token, refreshToken: refreshToken)
    }
    
    // MARK: - Persistence
   
    func persist() throws {
        guard
            self.isLogged,
            self.accountSession != nil,
            self.account != nil
        else { throw DS3AuthenticationError.loggedOut }
        
        try SharedData.default().persistAccountSession(accountSession: self.accountSession!)
        try SharedData.default().persistAccount(account: self.account!)
    }
    
    static func loadFromPersistenceOrCreateNew() -> DS3Authentication{
        do {
            let accountSession = try SharedData.default().loadAccountSessionFromPersistence()
            let account =  try SharedData.default().loadAccountFromPersistence()
            
            return DS3Authentication(
                accountSession: accountSession,
                account: account,
                isLogged: true
            )
        } catch {
            return DS3Authentication()
        }
    }
    
    func deleteFromDisk() throws {
        UserDefaults.standard.removeObject(forKey: DefaultSettings.UserDefaultsKeys.tutorial)
        try SharedData.default().deleteAccountSessionFromPersistence()
        try SharedData.default().deleteAccountFromPersistence()
        try SharedData.default().deleteDS3DrivesFromPersistence()
        try SharedData.default().deleteDS3APIKeysFromPersistence()
    }
   
    
    // MARK: - Account
    
    /// Retrieves Cubbit's account info
    /// - Returns: info about Cubbit's account
    func accountInfo() async throws -> Account {
        guard self.isLogged else { throw DS3AuthenticationError.loggedOut }
        
        try await self.refreshIfNeeded()
        
        guard let url = URL(string: CubbitAPIURLs.IAM.accounts.meURL) else { throw DS3AuthenticationError.invalidURL(url: CubbitAPIURLs.IAM.accounts.meURL) }
        
        var request = URLRequest(url: url)
        
        request.allHTTPHeaderFields = [
          "Content-Type": "application/json",
          "Authorization":"Bearer \(self.accountSession!.token.token)"
        ]
        
        request.httpMethod = "GET"
        
        let (responseData, response) = try await URLSession.shared.data(for: request)
        
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw DS3AuthenticationError.serverError }
        guard let account = try? JSONDecoder().decode(Account.self, from: responseData) else { throw DS3AuthenticationError.jsonConversion }
        
        return account
    }
}
