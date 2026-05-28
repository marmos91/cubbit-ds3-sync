import DS3CoreFFI
import Foundation
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
        case let .invalidURL(url):
            NSLocalizedString("The provided URL \(url ?? "") is invalid.", comment: "The invalidURL error")
        case .timeConversion:
            NSLocalizedString("Cannot convert time string", comment: "The time conversion error")
        case .serverError:
            NSLocalizedString(
                "There was an error with the server.\nPlease try again later",
                comment: "The server error"
            )
        case .jsonConversion:
            NSLocalizedString("There was an error while converting JSON data.", comment: "The JSON conversion error")
        case .cookies:
            NSLocalizedString("Cannot retrieve cookies", comment: "The cookies authentication error")
        case .encoding:
            NSLocalizedString(
                "There was an error while encoding/decoding data.",
                comment: "The encoding authentication error"
            )
        case .loggedOut:
            NSLocalizedString(
                "You need to be logged in to perform this operation",
                comment: "The authentication already logged error"
            )
        case .alreadyLoggedIn:
            NSLocalizedString("You are already logged in", comment: "The already logged in error")
        case .alreadyLoggedOut:
            NSLocalizedString("You are already logged out", comment: "The already logged out error")
        case .tokenExpired:
            NSLocalizedString("The session token expired", comment: "Token expiration error")
        case .missing2FA:
            NSLocalizedString("Missing 2FA code", comment: "Missing 2FA code")
        }
    }
}

extension DS3AuthenticationError {
    /// Translates a Rust `Ds3Error` (UniFFI flat-error shape) into the
    /// corresponding `DS3AuthenticationError` case.
    ///
    /// **Load-bearing:** `case 1007: return .missing2FA` (D-15). The
    /// LoginViewModel detects `.missing2FA` and prompts for a TFA code; any
    /// other mapping silently bypasses the 2FA UI, which is an auth bypass.
    static func translate(_ rust: Ds3Error) -> DS3AuthenticationError {
        let message = describe(rust)
        let code = ds3ErrorCode(message: message)
        switch code {
        case 1001: return .invalidURL(url: nil)
        case 1002: return .serverError
        case 1003: return .jsonConversion
        case 1004: return .encoding
        case 1005: return .loggedOut
        case 1006: return .tokenExpired
        case 1007: return .missing2FA // load-bearing per D-15 / T-16-04-01
        case 1008: return .cookies
        default: return .serverError
        }
    }

    /// Extracts the message string from a `Ds3Error` case (UniFFI flat-error
    /// emits each variant as `Case(message: String)` where `message` is the
    /// canonical `thiserror` Display string). Used by `translate` for the
    /// numeric-code lookup, and by the adapter's catch-site logging.
    static func describe(_ rust: Ds3Error) -> String {
        switch rust {
        case let .InvalidUrl(message),
             let .ServerError(message),
             let .JsonError(message),
             let .Encoding(message),
             let .LoggedOut(message),
             let .TokenExpired(message),
             let .Missing2Fa(message),
             let .CookieError(message),
             let .MissingUploadId(message),
             let .EmptyFileData(message),
             let .MissingETag(message),
             let .ParseError(message),
             let .UnableToOpenFile(message),
             let .IoError(message),
             let .HttpError(message),
             let .S3Error(message),
             let .AuthError(message):
            message
        }
    }
}

/// Class that manages the authentication with the DS3 APIs.
///
/// Phase 16 Plan 04: the `@Observable` shell + persisted UI state remain in
/// Swift; the actual challenge/sign/refresh/forge/account-info HTTP+CryptoKit
/// flow is delegated to the Rust core via `Ds3SessionHandle`. The 2FA UI path
/// is preserved byte-identically through the load-bearing `code 1007 ->
/// .missing2FA` translation (D-15 / T-16-04-01).
///
/// App Group JSON persistence stays in Swift (D-06) — every state-mutating
/// FFI call is followed by `try self.persist()` so `accountSession.json`
/// and `account.json` keep producing the same shapes that pre-swap builds
/// could read.
@Observable
public final class DS3Authentication: @unchecked Sendable {
    private let logger = Logger(subsystem: LogSubsystem.app, category: LogCategory.auth.rawValue)

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

    /// The Rust-backed session handle. Set after a successful `login(...)`;
    /// cleared on `logout(...)`. `nil` after `loadFromPersistenceOrCreateNew`
    /// restores from disk — the handle is in-memory only in Plan 04. Callers
    /// that need to issue authenticated requests after process restart must
    /// re-`login(...)`. See 16-04-SUMMARY.md §"Known Regressions" for the
    /// known-issue note.
    @ObservationIgnored private(set) var handle: Ds3SessionHandle?

    private let sharedData: SharedData

    public init(urls: CubbitAPIURLs = CubbitAPIURLs(), sharedData: SharedData = SharedData.default()) {
        self.urls = urls
        self.sharedData = sharedData
    }

    public init(
        accountSession: AccountSession,
        account: Account,
        isLogged: Bool,
        urls: CubbitAPIURLs = CubbitAPIURLs(),
        sharedData: SharedData = SharedData.default()
    ) {
        self.urls = urls
        self.sharedData = sharedData
        self.accountSession = accountSession
        self.account = account
        self.isLogged = isLogged
    }

    // MARK: - Tokens

    /// Forges an IAM token for the specified user. The IAM token will be then used to authenticate all the next
    /// requests for the specified user.
    /// - Parameter user: the IAM user for which you want to forge the token.
    /// - Returns: the Token object containing the access token and the expiration date.
    public func forgeIAMToken(forIAMUser user: IAMUser) async throws -> Token {
        guard let handle = self.handle else { throw DS3AuthenticationError.loggedOut }

        self.logger.debug("Forging IAM token for user \(user.id, privacy: .public)")

        do {
            let ffiToken = try handle.forgeIamToken(userId: user.id)
            let swiftToken = try Token.fromFFI(ffiToken)

            // The Rust session's refresh_token cookie may have rotated; pull the
            // up-to-date session and persist so disk matches in-memory state (D-06).
            try self.syncSessionFromHandle(handle)
            try self.persist()

            return swiftToken
        } catch let rustError as Ds3Error {
            self.logger.error(
                "forgeIAMToken failed: code=\(ds3ErrorCode(message: DS3AuthenticationError.describe(rustError)), privacy: .public) \(DS3AuthenticationError.describe(rustError), privacy: .public)"
            )
            throw DS3AuthenticationError.translate(rustError)
        }
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
                    } catch DS3AuthenticationError.tokenExpired {
                        // Refresh token itself is no longer valid — the server will never
                        // return a new access token. Clear local session so the UI routes
                        // the user back to login, then exit the timer.
                        self.logger.error("Refresh token rejected by server — forcing logout")
                        await self.logout()
                        return
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
        guard self.isLogged, let session = self.accountSession else {
            throw DS3AuthenticationError.loggedOut
        }
        guard let handle = self.handle else { throw DS3AuthenticationError.loggedOut }

        if !force, !DS3Authentication.shouldRefreshToken(session.token, threshold: 0) {
            return
        }

        self.logger.debug("Refreshing access token")

        do {
            try handle.refreshToken()
            try self.syncSessionFromHandle(handle)
            try self.persist()
        } catch let rustError as Ds3Error {
            self.logger.error(
                "refresh failed: code=\(ds3ErrorCode(message: DS3AuthenticationError.describe(rustError)), privacy: .public) \(DS3AuthenticationError.describe(rustError), privacy: .public)"
            )
            throw DS3AuthenticationError.translate(rustError)
        }
    }

    // MARK: - Login

    /// Logs in to Cubbit's IAM service.
    ///
    /// - Parameters:
    ///   - email: the email to login with
    ///   - password: the password to login with
    ///   - tfaCode: optional 2FA code. When `nil`, calls `authenticate`; when set,
    ///     calls `verify2fa`. The Rust core's `authenticate` returns code 1007 when
    ///     the account has 2FA enabled — the catch path below translates that into
    ///     `DS3AuthenticationError.missing2FA` so the LoginViewModel can re-prompt
    ///     with a TFA code (D-15, T-16-04-01).
    ///   - tenant: optional tenant identifier for multi-tenant login
    public func login(
        email: String,
        password: String,
        withTfaToken tfaCode: String? = nil,
        tenant: String? = nil
    ) async throws {
        guard self.isNotLogged else { throw DS3AuthenticationError.alreadyLoggedIn }

        do {
            let newHandle: Ds3SessionHandle
            if let code = tfaCode {
                self.logger.info("Logging in with 2FA code")
                newHandle = try Ds3SessionHandle.verify2fa(
                    email: email,
                    password: password,
                    tfaCode: code,
                    tenantId: tenant,
                    coordinatorUrl: self.urls.coordinatorURL
                )
            } else {
                self.logger.info("Logging in")
                newHandle = try Ds3SessionHandle.authenticate(
                    email: email,
                    password: password,
                    tenantId: tenant,
                    coordinatorUrl: self.urls.coordinatorURL
                )
            }

            // Pull authenticated state out of the Rust handle. The order matters:
            // assign handle first so the `loggedOut` guards in syncSessionFromHandle
            // can see it, then mirror session + account into the @Observable shell.
            self.handle = newHandle
            let ffiAccount = try newHandle.accountInfo()
            let ffiSession = try newHandle.currentSession()
            self.account = Account.fromFFI(ffiAccount)
            self.accountSession = try AccountSession.fromFFI(ffiSession)
            self.isLogged = true

            try self.persist()
            self.logger.info("Login succeeded")
        } catch let rustError as Ds3Error
            where ds3ErrorCode(message: DS3AuthenticationError.describe(rustError)) == 1007 {
            // D-15 / T-16-04-01 — preserve 2FA UI flow byte-identically.
            self.logger.info("2FA required — prompting user")
            throw DS3AuthenticationError.missing2FA
        } catch let rustError as Ds3Error {
            self.logger.error(
                "login failed: code=\(ds3ErrorCode(message: DS3AuthenticationError.describe(rustError)), privacy: .public) \(DS3AuthenticationError.describe(rustError), privacy: .public)"
            )
            throw DS3AuthenticationError.translate(rustError)
        }
    }

    /// Logs out from Cubbit's IAM service.
    ///
    /// Pass a `DS3DriveManager` so the active File Provider domains are
    /// disconnected **before** credentials are deleted — the extension needs
    /// valid API keys to handle the cleanup hand-off. Callers that omit it
    /// (background timer paths that don't hold a reference) still get a clean
    /// on-disk state: `deleteFromDisk()` clears `drives.json` so the next launch
    /// reconciles to an empty set.
    public func logout(driveManager: DS3DriveManager? = nil) async {
        guard self.isLogged else { return }

        self.logger.debug("Logging out...")

        if let driveManager {
            do {
                try await driveManager.disconnectAll()
            } catch {
                self.logger.warning(
                    "Drive disconnect during logout failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }

        // Drop the handle FIRST (T-16-04-04 mitigation) so any concurrent S3 op
        // racing against logout fails with `.loggedOut` instead of using a
        // stale-credentialed handle.
        self.handle = nil
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

    // MARK: - Session sync (private)

    /// Pulls the current `AccountSession` snapshot out of the Rust handle and
    /// mirrors it into `self.accountSession`. Called after every state-mutating
    /// FFI call (login / refresh / forge) so the @Observable property and the
    /// App Group JSON on disk stay in lockstep with the Rust session (D-06,
    /// PATTERNS.md §"Pattern 5: App Group Persistence Boundary").
    private func syncSessionFromHandle(_ handle: Ds3SessionHandle) throws {
        do {
            let ffiSession = try handle.currentSession()
            self.accountSession = try AccountSession.fromFFI(ffiSession)
        } catch let rustError as Ds3Error {
            self.logger.error(
                "syncSessionFromHandle failed: code=\(ds3ErrorCode(message: DS3AuthenticationError.describe(rustError)), privacy: .public)"
            )
            throw DS3AuthenticationError.translate(rustError)
        }
    }

    // MARK: - Persistence

    public func persist() throws {
        guard
            self.isLogged,
            let accountSession = self.accountSession,
            let account = self.account
        else { throw DS3AuthenticationError.loggedOut }

        try sharedData.persistAccountSession(accountSession: accountSession)
        try sharedData.persistAccount(account: account)
    }

    /// Loads authentication state from shared container, or creates a new unauthenticated instance.
    ///
    /// **Plan 04 caveat:** the Rust `Ds3SessionHandle` is in-memory only — there
    /// is no constructor that rebuilds an authenticated handle from a persisted
    /// `refreshToken`. After app restart, the returned instance has
    /// `isLogged = true` but `handle = nil`, so any subsequent auth method
    /// (`login` / `refreshIfNeeded` / `forgeIAMToken`) throws `.loggedOut`.
    /// The user must explicitly re-login. The File Provider extension is
    /// unaffected (it constructs an S3-only handle via `Ds3SessionHandle.s3Only`
    /// using persisted API keys — no auth round-trip required).
    ///
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

    /// Deletes all persisted authentication data from disk, including the drive
    /// list. The drive list goes too because the credentials it depends on are
    /// being deleted in the same call: keeping a `drives.json` entry whose
    /// matching `DS3ApiKey` no longer exists in `credentials.json` puts the
    /// extension into a crash loop at next launch (it can construct the drive
    /// from disk but cannot build a `DS3Client` without the key).
    ///
    /// Callers that own a `DS3DriveManager` should prefer `logout(driveManager:)`
    /// so the File Provider domains are removed cleanly — this method only
    /// clears the on-disk record and does not deregister NSFileProviderDomains.
    public func deleteFromDisk() throws {
        UserDefaults.standard.removeObject(forKey: DefaultSettings.UserDefaultsKeys.tutorial)
        try sharedData.deleteAccountSessionFromPersistence()
        try sharedData.deleteAccountFromPersistence()
        try sharedData.deleteDS3APIKeysFromPersistence()
        try? sharedData.deleteDS3DrivesFromPersistence()
    }

    // MARK: - Account

    /// Retrieves Cubbit's account info.
    ///
    /// - Returns: info about Cubbit's account.
    public func accountInfo() async throws -> Account {
        guard let handle = self.handle else { throw DS3AuthenticationError.loggedOut }

        do {
            let ffiAccount = try handle.accountInfo()
            let swift = Account.fromFFI(ffiAccount)
            self.logger.info("accountInfo: endpoint_gateway=\(swift.endpointGateway, privacy: .public)")
            return swift
        } catch let rustError as Ds3Error {
            self.logger.error(
                "accountInfo failed: code=\(ds3ErrorCode(message: DS3AuthenticationError.describe(rustError)), privacy: .public) \(DS3AuthenticationError.describe(rustError), privacy: .public)"
            )
            throw DS3AuthenticationError.translate(rustError)
        }
    }
}
