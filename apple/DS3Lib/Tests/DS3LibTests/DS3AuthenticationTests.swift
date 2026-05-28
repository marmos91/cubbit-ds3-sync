import DS3CoreFFI
@testable import DS3Lib
import XCTest

/// Tests for DS3Authentication pure methods (no network calls).
///
/// Phase 16 Plan 04: the Curve25519 signing and the HTTP request-body structs
/// (`DS3ChallengeRequest` / `DS3LoginRequest`) moved into Rust and were
/// removed from the Swift surface; the corresponding tests are kept inside
/// `core/ds3-auth/src/crypto.rs` (sign_challenge unit tests) and
/// `core/ds3-http/src/serde.rs` (request-body serde tests). The Plan 04
/// SUMMARY tracks this migration in §"Test refactors".
final class DS3AuthenticationTests: XCTestCase {
    // MARK: - Login State

    func testInitialStateIsLoggedOut() {
        let auth = DS3Authentication()
        XCTAssertFalse(auth.isLogged)
        XCTAssertTrue(auth.isNotLogged)
        XCTAssertNil(auth.accountSession)
        XCTAssertNil(auth.account)
    }

    func testLogoutClearsState() async throws {
        let token = try TestHelpers.makeToken(expiringAt: Date().addingTimeInterval(3600))
        let session = AccountSession(token: token, refreshToken: "refresh")
        let account = Account(
            id: "acc-1", firstName: "Test", lastName: "User",
            isInternal: false, isBanned: false, createdAt: "2023-01-01",
            maxAllowedProjects: 5,
            emails: [], isTwoFactorEnabled: false, tenantId: "t-1",
            endpointGateway: "https://s3.cubbit.eu", authProvider: "cubbit"
        )

        let auth = DS3Authentication(accountSession: session, account: account, isLogged: true)
        XCTAssertTrue(auth.isLogged)

        await auth.logout()

        XCTAssertFalse(auth.isLogged)
        XCTAssertNil(auth.accountSession)
        XCTAssertNil(auth.account)
    }

    func testLogoutWhenAlreadyLoggedOutIsNoOp() async {
        let auth = DS3Authentication()
        XCTAssertFalse(auth.isLogged)

        // Should not crash
        await auth.logout()

        XCTAssertFalse(auth.isLogged)
    }

    func testLogoutDeletesFilesFromInjectedSharedData() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sharedData = SharedData(testContainerURL: tempDir)
        let token = try TestHelpers.makeToken(expiringAt: Date().addingTimeInterval(3600))
        let session = AccountSession(token: token, refreshToken: "refresh")
        let account = Account(
            id: "acc-1", firstName: "Test", lastName: "User",
            isInternal: false, isBanned: false, createdAt: "2023-01-01",
            maxAllowedProjects: 5,
            emails: [], isTwoFactorEnabled: false, tenantId: "t-1",
            endpointGateway: "https://s3.cubbit.eu", authProvider: "cubbit"
        )

        let auth = DS3Authentication(
            accountSession: session, account: account,
            isLogged: true, sharedData: sharedData
        )
        // Write session and account to the temp dir
        try auth.persist()
        // Also write an empty API keys list so deleteDS3APIKeysFromPersistence() is exercised
        try sharedData.persistDS3APIKeys([])

        let sessionFile = tempDir.appendingPathComponent(DefaultSettings.FileNames.accountSessionFileName)
        let accountFile = tempDir.appendingPathComponent(DefaultSettings.FileNames.accountFileName)
        let apiKeysFile = tempDir.appendingPathComponent(DefaultSettings.FileNames.credentialsFileName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionFile.path), "session should exist before logout")
        XCTAssertTrue(FileManager.default.fileExists(atPath: accountFile.path), "account should exist before logout")
        XCTAssertTrue(FileManager.default.fileExists(atPath: apiKeysFile.path), "apiKeys should exist before logout")

        await auth.logout()

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: sessionFile.path),
            "session should be deleted after logout"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: accountFile.path),
            "account should be deleted after logout"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: apiKeysFile.path),
            "apiKeys should be deleted after logout"
        )
    }

    /// Regression: logout must also clear drives.json. Leaving drive entries
    /// behind after credentials are wiped creates a `drives.json` ↔ `credentials.json`
    /// mismatch — the extension can construct the drive but fails to build a
    /// `DS3Client` because the matching API key is gone, entering a fileproviderd
    /// crash loop at next launch.
    func testLogoutDeletesDrivesJSON() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sharedData = SharedData(testContainerURL: tempDir)
        let token = try TestHelpers.makeToken(expiringAt: Date().addingTimeInterval(3600))
        let session = AccountSession(token: token, refreshToken: "refresh")
        let account = Account(
            id: "acc-1", firstName: "Test", lastName: "User",
            isInternal: false, isBanned: false, createdAt: "2023-01-01",
            maxAllowedProjects: 5,
            emails: [], isTwoFactorEnabled: false, tenantId: "t-1",
            endpointGateway: "https://s3.cubbit.eu", authProvider: "cubbit"
        )

        let auth = DS3Authentication(
            accountSession: session, account: account,
            isLogged: true, sharedData: sharedData
        )
        try auth.persist()
        try sharedData.persistDS3APIKeys([])
        try sharedData.persistDS3Drives(ds3Drives: [])

        let drivesFile = tempDir.appendingPathComponent(DefaultSettings.FileNames.drivesFileName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: drivesFile.path), "drives.json should exist before logout")

        await auth.logout()

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: drivesFile.path),
            "drives.json must be deleted on logout to keep the credentials↔drives invariant"
        )
    }

    // MARK: - shouldRefreshToken

    func testTokenFarFromExpiryDoesNotNeedRefresh() throws {
        let token = try TestHelpers.makeToken(expiringAt: Date().addingTimeInterval(600))
        XCTAssertFalse(DS3Authentication.shouldRefreshToken(token))
    }

    func testTokenNearExpiryNeedsRefresh() throws {
        let token = try TestHelpers.makeToken(expiringAt: Date().addingTimeInterval(240))
        XCTAssertTrue(DS3Authentication.shouldRefreshToken(token))
    }

    func testExpiredTokenNeedsRefresh() throws {
        let token = try TestHelpers.makeToken(expiringAt: Date().addingTimeInterval(-60))
        XCTAssertTrue(DS3Authentication.shouldRefreshToken(token))
    }

    func testCustomThreshold() throws {
        let token = try TestHelpers.makeToken(expiringAt: Date().addingTimeInterval(50))
        // Default threshold is 300s — should need refresh
        XCTAssertTrue(DS3Authentication.shouldRefreshToken(token, threshold: 300))
        // With 10s threshold — should not need refresh
        XCTAssertFalse(DS3Authentication.shouldRefreshToken(token, threshold: 10))
    }

    // MARK: - Refresh Guards

    func testRefreshIfNeededThrowsWhenLoggedOut() async {
        let auth = DS3Authentication()

        do {
            try await auth.refreshIfNeeded()
            XCTFail("Should throw loggedOut error")
        } catch {
            XCTAssertTrue(error is DS3AuthenticationError)
        }
    }

    // MARK: - URL Configuration

    func testDefaultURLs() {
        let auth = DS3Authentication()
        XCTAssertEqual(auth.urls.coordinatorURL, CubbitAPIURLs.defaultCoordinatorURL)
    }

    func testCustomURLs() {
        let urls = CubbitAPIURLs(coordinatorURL: "https://custom.api.example.com")
        let auth = DS3Authentication(urls: urls)
        XCTAssertEqual(auth.urls.coordinatorURL, "https://custom.api.example.com")
    }

    // MARK: - Error translation (T-16-04-01 / D-15)

    // The Rust `DS3Error` uses `thiserror` to produce canonical Display strings
    // (`"2FA code required"`, `"Not logged in"`, etc.). UniFFI's `flat_error`
    // attribute collapses every variant into a `Case(message: String)` shape
    // on the Swift side, where `message` IS the Display string. The
    // `ds3ErrorCode(message:)` free function matches against those canonical
    // strings — tests must use them verbatim or they fall through to the
    // unknown-code branch (which the translator maps to `.serverError`).

    func testTranslateMaps1007ToMissing2FA() {
        // Load-bearing: code 1007 MUST map to .missing2FA so the LoginViewModel
        // re-prompts the user for a TFA code. Any other mapping silently
        // bypasses the 2FA UI (auth bypass — see threat T-16-04-01).
        let rust = Ds3Error.Missing2Fa(message: "2FA code required")
        let translated = DS3AuthenticationError.translate(rust)
        guard case .missing2FA = translated else {
            XCTFail("Expected .missing2FA for Missing2Fa Ds3Error, got \(translated)")
            return
        }
    }

    func testTranslateMaps1005ToLoggedOut() {
        let rust = Ds3Error.LoggedOut(message: "Not logged in")
        let translated = DS3AuthenticationError.translate(rust)
        guard case .loggedOut = translated else {
            XCTFail("Expected .loggedOut, got \(translated)")
            return
        }
    }

    func testTranslateMaps1006ToTokenExpired() {
        let rust = Ds3Error.TokenExpired(message: "Token expired")
        let translated = DS3AuthenticationError.translate(rust)
        guard case .tokenExpired = translated else {
            XCTFail("Expected .tokenExpired, got \(translated)")
            return
        }
    }

    func testTranslateMaps1002ToServerError() {
        let rust = Ds3Error.ServerError(message: "Server error: HTTP 500")
        let translated = DS3AuthenticationError.translate(rust)
        guard case .serverError = translated else {
            XCTFail("Expected .serverError, got \(translated)")
            return
        }
    }

    func testTranslateUnknownCodeFallsBackToServerError() {
        // S3Error (code 3003) is not an auth error; the auth translator's
        // default branch falls through to .serverError so the LoginViewModel
        // still surfaces a non-fatal error.
        let rust = Ds3Error.S3Error(message: "S3 error: unexpected")
        let translated = DS3AuthenticationError.translate(rust)
        guard case .serverError = translated else {
            XCTFail("Expected .serverError for default branch, got \(translated)")
            return
        }
    }
}
