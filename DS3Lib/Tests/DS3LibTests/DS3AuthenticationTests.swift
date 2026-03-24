import XCTest
@testable import DS3Lib

/// Tests for DS3Authentication pure methods (no network calls).
final class DS3AuthenticationTests: XCTestCase {
    // MARK: - Sign Challenge

    func testSignChallengeProducesValidBase64() throws {
        let auth = DS3Authentication()
        let challenge = Challenge(challenge: "test-challenge-123", salt: "test-salt-456")
        let password = "my-password"

        let signature = try auth.signChallenge(challenge: challenge, password: password)

        let decoded = Data(base64Encoded: signature)
        XCTAssertNotNil(decoded, "Signature should be valid base64")
        // Ed25519 signatures are 64 bytes
        XCTAssertEqual(decoded?.count, 64, "Ed25519 signature should be 64 bytes")
    }

    func testSignChallengeDiffersWithDifferentPasswords() throws {
        let auth = DS3Authentication()
        let challenge = Challenge(challenge: "challenge", salt: "salt")

        let sig1 = try auth.signChallenge(challenge: challenge, password: "password1")
        let sig2 = try auth.signChallenge(challenge: challenge, password: "password2")

        XCTAssertNotEqual(sig1, sig2, "Different passwords should produce different signatures")
    }

    func testSignChallengeDiffersWithDifferentChallenges() throws {
        let auth = DS3Authentication()
        let password = "same-password"

        let challenge1 = Challenge(challenge: "challenge-1", salt: "salt")
        let challenge2 = Challenge(challenge: "challenge-2", salt: "salt")

        let sig1 = try auth.signChallenge(challenge: challenge1, password: password)
        let sig2 = try auth.signChallenge(challenge: challenge2, password: password)

        XCTAssertNotEqual(sig1, sig2)
    }

    func testSignChallengeDiffersWithDifferentSalts() throws {
        let auth = DS3Authentication()
        let password = "same-password"

        let challenge1 = Challenge(challenge: "challenge", salt: "salt-1")
        let challenge2 = Challenge(challenge: "challenge", salt: "salt-2")

        let sig1 = try auth.signChallenge(challenge: challenge1, password: password)
        let sig2 = try auth.signChallenge(challenge: challenge2, password: password)

        XCTAssertNotEqual(sig1, sig2)
    }

    // MARK: - Login State

    func testInitialStateIsLoggedOut() {
        let auth = DS3Authentication()
        XCTAssertFalse(auth.isLogged)
        XCTAssertTrue(auth.isNotLogged)
        XCTAssertNil(auth.accountSession)
        XCTAssertNil(auth.account)
    }

    func testLogoutClearsState() throws {
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

        auth.logout()

        XCTAssertFalse(auth.isLogged)
        XCTAssertNil(auth.accountSession)
        XCTAssertNil(auth.account)
    }

    func testLogoutWhenAlreadyLoggedOutIsNoOp() {
        let auth = DS3Authentication()
        XCTAssertFalse(auth.isLogged)

        // Should not crash
        auth.logout()

        XCTAssertFalse(auth.isLogged)
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

    // MARK: - ChallengeRequest Encoding

    func testChallengeRequestEncoding() throws {
        let request = DS3ChallengeRequest(email: "test@cubbit.io", tenantId: "my-tenant")
        let data = try JSONEncoder().encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertEqual(json?["email"] as? String, "test@cubbit.io")
        XCTAssertEqual(json?["tenant_id"] as? String, "my-tenant")
    }

    func testChallengeRequestWithoutTenant() throws {
        let request = DS3ChallengeRequest(email: "test@cubbit.io", tenantId: nil)
        let data = try JSONEncoder().encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertEqual(json?["email"] as? String, "test@cubbit.io")
        XCTAssertNil(json?["tenant_id"])
    }

    // MARK: - LoginRequest Encoding

    func testLoginRequestEncoding() throws {
        let request = DS3LoginRequest(
            email: "test@cubbit.io",
            signedChallenge: "base64sig==",
            tfaCode: "123456",
            tenantId: "tenant-1"
        )

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertEqual(json?["email"] as? String, "test@cubbit.io")
        XCTAssertEqual(json?["signed_challenge"] as? String, "base64sig==")
        XCTAssertEqual(json?["tfa_code"] as? String, "123456")
        XCTAssertEqual(json?["tenant_id"] as? String, "tenant-1")
    }
}
