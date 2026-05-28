import DS3CoreFFI
@testable import DS3Lib
import XCTest

/// Tests for FFI -> Swift model translation helpers (Plan 04 Task 1).
///
/// Phase 16 Plan 04 — Option B: every model type collides on name across
/// modules (`DS3CoreFFI.Account` vs `DS3Lib.Account`, etc.). The `+FFI` files
/// own translation at the FFI boundary; these tests pin field-by-field that
/// the FFI struct snapshot lifts into the Swift Codable type without losing
/// or reshaping fields, so the resulting App Group JSON byte shapes (D-06)
/// remain unchanged.
final class ModelFFIBridgeTests: XCTestCase {
    // MARK: - Token

    func testTokenFromFFIPreservesFields() throws {
        let isoString = "2026-12-31T23:59:59.000Z"
        let ffi = DS3CoreFFI.Token(
            token: "jwt-access-token",
            exp: 1_798_761_599,
            expDate: isoString
        )

        let swift = try Token.fromFFI(ffi)

        XCTAssertEqual(swift.token, "jwt-access-token")
        XCTAssertEqual(swift.exp, 1_798_761_599)
        XCTAssertNotNil(swift.expDate)
    }

    func testTokenFromFFIRoundTripsViaCodable() throws {
        let isoString = "2026-12-31T23:59:59.000Z"
        let ffi = DS3CoreFFI.Token(
            token: "jwt-access-token",
            exp: 1_798_761_599,
            expDate: isoString
        )
        let swift = try Token.fromFFI(ffi)

        // Encode -> decode round-trip should preserve all fields.
        let encoded = try JSONEncoder().encode(swift)
        let decoded = try JSONDecoder().decode(Token.self, from: encoded)

        XCTAssertEqual(decoded.token, swift.token)
        XCTAssertEqual(decoded.exp, swift.exp)
        XCTAssertEqual(decoded.expDate, swift.expDate)
    }

    func testTokenFromFFIThrowsOnInvalidDate() {
        let ffi = DS3CoreFFI.Token(
            token: "token",
            exp: 0,
            expDate: "not-an-iso8601-string"
        )
        XCTAssertThrowsError(try Token.fromFFI(ffi))
    }

    // MARK: - AccountSession

    func testAccountSessionFromFFIPreservesTokenAndRefresh() throws {
        let ffiToken = DS3CoreFFI.Token(
            token: "tok",
            exp: 1_798_761_599,
            expDate: "2026-12-31T23:59:59.000Z"
        )
        let ffi = DS3CoreFFI.AccountSession(
            token: ffiToken,
            refreshToken: "refresh-cookie-value"
        )

        let swift = try AccountSession.fromFFI(ffi)

        XCTAssertEqual(swift.token.token, "tok")
        XCTAssertEqual(swift.refreshToken, "refresh-cookie-value")
    }

    func testAccountSessionAppGroupJSONShape() throws {
        let ffiToken = DS3CoreFFI.Token(
            token: "tok",
            exp: 1_798_761_599,
            expDate: "2026-12-31T23:59:59.000Z"
        )
        let ffi = DS3CoreFFI.AccountSession(
            token: ffiToken,
            refreshToken: "rt"
        )
        let swift = try AccountSession.fromFFI(ffi)

        let json = try JSONEncoder().encode(swift)
        let parsed = try JSONSerialization.jsonObject(with: json) as? [String: Any]

        XCTAssertNotNil(parsed?["token"], "App Group JSON must contain 'token'")
        XCTAssertNotNil(parsed?["refreshToken"], "App Group JSON must contain 'refreshToken'")
    }

    // MARK: - Account

    func testAccountFromFFIPreservesAllFields() {
        let ffi = DS3CoreFFI.Account(
            id: "acc-1",
            firstName: "Marco",
            lastName: "Tester",
            isInternal: false,
            isBanned: false,
            createdAt: "2024-01-01T00:00:00.000Z",
            deletedAt: nil,
            bannedAt: nil,
            maxAllowedProjects: 5,
            emails: [
                DS3CoreFFI.AccountEmail(
                    id: "em-1",
                    email: "marco@cubbit.io",
                    isDefault: true,
                    createdAt: "2024-01-01T00:00:00.000Z",
                    isVerified: true,
                    tenantId: "t-1"
                )
            ],
            isTwoFactorEnabled: false,
            tenantId: "t-1",
            endpointGateway: "https://s3.eu00wi.cubbit.services",
            authProvider: "cubbit"
        )

        let swift = Account.fromFFI(ffi)

        XCTAssertEqual(swift.id, "acc-1")
        XCTAssertEqual(swift.firstName, "Marco")
        XCTAssertEqual(swift.lastName, "Tester")
        XCTAssertEqual(swift.maxAllowedProjects, 5)
        XCTAssertEqual(swift.emails.count, 1)
        XCTAssertEqual(swift.emails.first?.email, "marco@cubbit.io")
        XCTAssertEqual(swift.endpointGateway, "https://s3.eu00wi.cubbit.services")
        XCTAssertEqual(swift.tenantId, "t-1")
        XCTAssertEqual(swift.authProvider, "cubbit")
    }

    func testAccountAppGroupJSONShape() throws {
        let ffi = DS3CoreFFI.Account(
            id: "acc-1",
            firstName: "Marco",
            lastName: "Tester",
            isInternal: false,
            isBanned: false,
            createdAt: "2024-01-01T00:00:00.000Z",
            deletedAt: nil,
            bannedAt: nil,
            maxAllowedProjects: 5,
            emails: [],
            isTwoFactorEnabled: false,
            tenantId: "t-1",
            endpointGateway: "https://s3.example.com",
            authProvider: "cubbit"
        )
        let swift = Account.fromFFI(ffi)

        let json = try JSONEncoder().encode(swift)
        let parsed = try JSONSerialization.jsonObject(with: json) as? [String: Any]

        // Verify the App Group JSON byte shape uses the snake_case CodingKeys
        // (D-06: persisted JSON must remain readable by pre-swap builds).
        XCTAssertEqual(parsed?["id"] as? String, "acc-1")
        XCTAssertEqual(parsed?["first_name"] as? String, "Marco")
        XCTAssertEqual(parsed?["last_name"] as? String, "Tester")
        XCTAssertEqual(parsed?["max_allowed_projects"] as? Int, 5)
        XCTAssertEqual(parsed?["tenant_id"] as? String, "t-1")
        XCTAssertEqual(parsed?["endpoint_gateway"] as? String, "https://s3.example.com")
        XCTAssertEqual(parsed?["auth_provider"] as? String, "cubbit")
        XCTAssertEqual(parsed?["two_factor_enabled"] as? Bool, false)
    }

    // MARK: - Project + IAMUser

    func testProjectFromFFIPreservesAllFields() {
        let ffi = DS3CoreFFI.Project(
            id: "proj-1",
            name: "My Project",
            description: "Test description",
            email: "project@cubbit.io",
            createdAt: "2024-01-01T00:00:00.000Z",
            bannedAt: nil,
            imageUrl: "https://example.com/img.png",
            tenantId: "t-1",
            rootAccountEmail: "root@cubbit.io",
            users: [
                DS3CoreFFI.IamUser(id: "user-1", username: "admin", isRoot: true)
            ]
        )

        let swift = Project.fromFFI(ffi)

        XCTAssertEqual(swift.id, "proj-1")
        XCTAssertEqual(swift.name, "My Project")
        XCTAssertEqual(swift.description, "Test description")
        XCTAssertEqual(swift.email, "project@cubbit.io")
        XCTAssertEqual(swift.imageUrl, "https://example.com/img.png")
        XCTAssertEqual(swift.tenantId, "t-1")
        XCTAssertEqual(swift.rootAccountEmail, "root@cubbit.io")
        XCTAssertEqual(swift.users.count, 1)
        XCTAssertEqual(swift.users.first?.username, "admin")
        XCTAssertTrue(swift.users.first?.isRoot ?? false)
    }

    func testProjectAppGroupJSONShape() throws {
        let ffi = DS3CoreFFI.Project(
            id: "proj-1",
            name: "My Project",
            description: "Test description",
            email: "project@cubbit.io",
            createdAt: "2024-01-01T00:00:00.000Z",
            bannedAt: nil,
            imageUrl: nil,
            tenantId: "t-1",
            rootAccountEmail: nil,
            users: [DS3CoreFFI.IamUser(id: "user-1", username: "admin", isRoot: true)]
        )
        let swift = Project.fromFFI(ffi)

        let json = try JSONEncoder().encode(swift)
        let parsed = try JSONSerialization.jsonObject(with: json) as? [String: Any]

        // Project uses the `project_*` CodingKeys (see Models/Project.swift).
        XCTAssertEqual(parsed?["project_id"] as? String, "proj-1")
        XCTAssertEqual(parsed?["project_name"] as? String, "My Project")
        XCTAssertEqual(parsed?["project_description"] as? String, "Test description")
        XCTAssertEqual(parsed?["project_email"] as? String, "project@cubbit.io")
        XCTAssertEqual(parsed?["project_tenant_id"] as? String, "t-1")
    }

    func testIAMUserFromFFIPreservesFields() {
        let ffi = DS3CoreFFI.IamUser(id: "user-1", username: "alice", isRoot: false)
        let swift = IAMUser.fromFFI(ffi)

        XCTAssertEqual(swift.id, "user-1")
        XCTAssertEqual(swift.username, "alice")
        XCTAssertFalse(swift.isRoot)
    }

    // MARK: - DS3ApiKey

    func testDS3ApiKeyFromFFIPreservesFields() throws {
        let ffi = DS3CoreFFI.Ds3ApiKey(
            name: "DS3Drive-for-macOS-key",
            apiKey: "AKIA1234567890",
            secretKey: "supersecret",
            createdAt: "2024-01-01T00:00:00.000+00:00"
        )

        let swift = try DS3ApiKey.fromFFI(ffi)

        XCTAssertEqual(swift.name, "DS3Drive-for-macOS-key")
        XCTAssertEqual(swift.apiKey, "AKIA1234567890")
        XCTAssertEqual(swift.secretKey, "supersecret")
        XCTAssertNotNil(swift.createdAt)
    }

    func testDS3ApiKeyFromFFIWithoutSecret() throws {
        let ffi = DS3CoreFFI.Ds3ApiKey(
            name: "DS3Drive-for-macOS-key",
            apiKey: "AKIA1234567890",
            secretKey: nil,
            createdAt: "2024-01-01T00:00:00.000+00:00"
        )

        let swift = try DS3ApiKey.fromFFI(ffi)

        XCTAssertEqual(swift.name, "DS3Drive-for-macOS-key")
        XCTAssertEqual(swift.apiKey, "AKIA1234567890")
        XCTAssertNil(swift.secretKey)
    }

    func testDS3ApiKeyAppGroupJSONShape() throws {
        let ffi = DS3CoreFFI.Ds3ApiKey(
            name: "DS3Drive-for-macOS-key",
            apiKey: "AKIA1234567890",
            secretKey: "supersecret",
            createdAt: "2024-01-01T00:00:00.000+00:00"
        )
        let swift = try DS3ApiKey.fromFFI(ffi)
        let json = try JSONEncoder().encode(swift)
        let parsed = try JSONSerialization.jsonObject(with: json) as? [String: Any]

        // credentials.json shape (see Models/DS3APIKey.swift CodingKeys).
        XCTAssertEqual(parsed?["name"] as? String, "DS3Drive-for-macOS-key")
        XCTAssertEqual(parsed?["api_key"] as? String, "AKIA1234567890")
        XCTAssertEqual(parsed?["secret_key"] as? String, "supersecret")
        XCTAssertNotNil(parsed?["created_at"])
    }
}
