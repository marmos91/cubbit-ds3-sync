import XCTest
@testable import DS3Lib

/// Schema-parity gate (Phase 16 Plan 06 / D-25).
///
/// Decodes the same JSON fixture bytes that
/// `core/ds3-models/tests/serde_tests.rs` round-trips on the Rust side.
/// Both sides assert against the SAME locked field values. If a Rust field
/// rename (e.g. `is_internal` -> `internal_account`) ships without a
/// matching Swift `CodingKeys` change — or vice versa — exactly one side
/// stops decoding and CI fails the PR.
///
/// The fixture bytes are committed twice for SPM-sandbox reasons (SPM
/// `.copy` paths must live inside the test target). A CI byte-equality
/// step guarantees the two copies match — see `.github/workflows/build.yml`
/// "Schema parity fixture byte-equality".
final class SchemaParityTests: XCTestCase {
    // MARK: - Helpers

    private func loadFixture(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws -> Data {
        guard let url = Bundle.module.url(
            forResource: name,
            withExtension: "json",
            subdirectory: "Resources/fixtures"
        ) ?? Bundle.module.url(
            forResource: name,
            withExtension: "json",
            subdirectory: "fixtures"
        ) ?? Bundle.module.url(
            forResource: name,
            withExtension: "json"
        ) else {
            XCTFail("schema-parity fixture not found in bundle: \(name).json", file: file, line: line)
            throw NSError(
                domain: "SchemaParityTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "missing fixture \(name).json"]
            )
        }
        return try Data(contentsOf: url)
    }

    // MARK: - Tests

    func testDrivesFixtureDecodes() throws {
        let data = try loadFixture("drives_v4")
        let drives = try JSONDecoder().decode([DS3Drive].self, from: data)

        XCTAssertEqual(drives.count, 2, "drives_v4.json fixture has 2 records")
        XCTAssertEqual(drives[0].name, "Alpha Drive")
        XCTAssertEqual(drives[0].syncAnchor.bucket.name, "test-bucket-1")
        XCTAssertEqual(drives[0].syncAnchor.prefix, "documents/")
        XCTAssertEqual(drives[0].syncAnchor.IAMUser.id, "iam-user-001")
        XCTAssertTrue(drives[0].syncAnchor.IAMUser.isRoot)
        XCTAssertEqual(drives[0].syncAnchor.project.id, "proj-fixture-001")

        XCTAssertEqual(drives[1].syncAnchor.bucket.name, "test-bucket-2")
        XCTAssertNil(drives[1].syncAnchor.prefix)
        XCTAssertFalse(drives[1].syncAnchor.IAMUser.isRoot)
    }

    func testCredentialsFixtureDecodes() throws {
        let data = try loadFixture("credentials_v1")
        let keys = try JSONDecoder().decode([DS3ApiKey].self, from: data)

        XCTAssertEqual(keys.count, 2)
        XCTAssertEqual(keys[0].name, "ds3-drive-fixture-key-1")
        XCTAssertEqual(keys[0].apiKey, "AKIAFIXTURE0000000001")
        XCTAssertEqual(keys[0].secretKey, "fixtureSecretKeyValue00000000000000000001")

        // Second key omits secret_key — must decode as nil.
        XCTAssertEqual(keys[1].name, "ds3-drive-fixture-key-2")
        XCTAssertNil(keys[1].secretKey)
    }

    func testAccountSessionFixtureDecodes() throws {
        let data = try loadFixture("accountSession_v1")
        let session = try JSONDecoder().decode(AccountSession.self, from: data)

        XCTAssertEqual(session.token.token, "eyJhbGciOiJIUzI1NiJ9.fixture-access-token.signature")
        XCTAssertEqual(session.token.exp, 1_735_689_600)
        XCTAssertEqual(session.refreshToken, "fixture-refresh-token-value-0123456789abcdef")
        XCTAssertFalse(session.refreshToken.isEmpty)
    }

    func testAccountFixtureDecodes() throws {
        let data = try loadFixture("account_v1")
        let account = try JSONDecoder().decode(Account.self, from: data)

        XCTAssertEqual(account.id, "acc-fixture-001")
        XCTAssertEqual(account.firstName, "Fixture")
        XCTAssertEqual(account.lastName, "User")
        XCTAssertFalse(account.isInternal)
        XCTAssertFalse(account.isBanned)
        XCTAssertEqual(account.maxAllowedProjects, 5)
        XCTAssertEqual(account.tenantId, "tenant-fixture")
        // endpoint_gateway (snake_case wire) -> endpointGateway (camelCase Swift).
        // This single assertion catches the highest-risk D-25 drift mode.
        XCTAssertEqual(account.endpointGateway, "https://s3.fixture.example.com")
        XCTAssertEqual(account.authProvider, "cubbit")
        XCTAssertFalse(account.endpointGateway.isEmpty)
        XCTAssertEqual(account.emails.count, 1)
        XCTAssertEqual(account.emails[0].email, "test-user@example.com")
        XCTAssertTrue(account.emails[0].isDefault)
        XCTAssertTrue(account.emails[0].isVerified)
    }
}
