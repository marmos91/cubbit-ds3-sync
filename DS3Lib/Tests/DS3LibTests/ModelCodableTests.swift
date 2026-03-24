import XCTest
@testable import DS3Lib

/// Tests Codable round-trip encoding/decoding for all DS3Lib models.
final class ModelCodableTests: XCTestCase {
    // MARK: - Helpers

    /// Helper: encode then decode a Codable value, asserting round-trip succeeds.
    private func assertRoundTrip<T: Codable & Equatable>(_ value: T, file: StaticString = #file, line: UInt = #line) throws {
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(T.self, from: data)
        XCTAssertEqual(decoded, value, "Round-trip failed for \(T.self)", file: file, line: line)
    }

    /// Helper: encode then decode a Codable value, asserting decoding succeeds (for non-Equatable types).
    /// If encoding or decoding fails, the thrown error fails the test.
    private func assertDecodable<T: Codable>(_ value: T, file: StaticString = #file, line: UInt = #line) throws {
        let data = try JSONEncoder().encode(value)
        _ = try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - Token

    func testTokenRoundTrip() throws {
        let json = """
        {
            "token": "eyJhbGciOiJIUzI1NiJ9.test",
            "exp": 1700000000,
            "exp_date": "2023-11-14T22:13:20.000Z"
        }
        """.data(using: .utf8)!

        let token = try JSONDecoder().decode(Token.self, from: json)
        XCTAssertEqual(token.token, "eyJhbGciOiJIUzI1NiJ9.test")
        XCTAssertEqual(token.exp, 1700000000)

        // Re-encode and decode
        let reencoded = try JSONEncoder().encode(token)
        let redecoded = try JSONDecoder().decode(Token.self, from: reencoded)
        XCTAssertEqual(redecoded.token, token.token)
        XCTAssertEqual(redecoded.exp, token.exp)
    }

    func testTokenInvalidDateFails() {
        let json = """
        {
            "token": "test",
            "exp": 1700000000,
            "exp_date": "not-a-date"
        }
        """.data(using: .utf8)!

        XCTAssertThrowsError(try JSONDecoder().decode(Token.self, from: json))
    }

    // MARK: - Account

    func testAccountRoundTrip() throws {
        let account = Account(
            id: "acc-123",
            firstName: "Marco",
            lastName: "Moschettini",
            isInternal: false,
            isBanned: false,
            createdAt: "2023-01-01T00:00:00.000Z",
            maxAllowedProjects: 5,
            emails: [
                AccountEmail(
                    id: "email-1", email: "test@cubbit.io", isDefault: true,
                    createdAt: "2023-01-01T00:00:00.000Z", isVerified: true, tenantId: "tenant-1"
                )
            ],
            isTwoFactorEnabled: false,
            tenantId: "tenant-1",
            endpointGateway: "https://s3.cubbit.eu",
            authProvider: "cubbit"
        )

        try assertDecodable(account)
    }

    func testAccountWithOptionalFields() throws {
        let account = Account(
            id: "acc-123",
            firstName: "Test",
            lastName: "User",
            isInternal: true,
            isBanned: true,
            createdAt: "2023-01-01T00:00:00.000Z",
            deletedAt: "2024-01-01T00:00:00.000Z",
            bannedAt: "2023-06-01T00:00:00.000Z",
            maxAllowedProjects: 10,
            emails: [],
            isTwoFactorEnabled: true,
            tenantId: "tenant-2",
            endpointGateway: "https://s3.custom.eu",
            authProvider: "saml"
        )

        let data = try JSONEncoder().encode(account)
        let decoded = try JSONDecoder().decode(Account.self, from: data)
        XCTAssertEqual(decoded.deletedAt, "2024-01-01T00:00:00.000Z")
        XCTAssertEqual(decoded.bannedAt, "2023-06-01T00:00:00.000Z")
    }

    // MARK: - AccountSession

    func testAccountSessionRoundTrip() throws {
        let tokenJson = """
        {
            "token": "eyJ0ZXN0IjoidG9rZW4ifQ",
            "exp": 1700000000,
            "exp_date": "2023-11-14T22:13:20.000Z"
        }
        """.data(using: .utf8)!
        let token = try JSONDecoder().decode(Token.self, from: tokenJson)

        let session = AccountSession(token: token, refreshToken: "refresh-token-abc")

        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(AccountSession.self, from: data)
        XCTAssertEqual(decoded.token.token, "eyJ0ZXN0IjoidG9rZW4ifQ")
        XCTAssertEqual(decoded.refreshToken, "refresh-token-abc")
    }

    // MARK: - DS3Drive

    func testDS3DriveRoundTrip() throws {
        let project = Project(
            id: "proj-1", name: "TestProject", description: "A test project",
            email: "project@cubbit.io", createdAt: "2023-01-01", tenantId: "tenant-1",
            users: [IAMUser(id: "user-1", username: "testuser", isRoot: true)]
        )
        let syncAnchor = SyncAnchor(
            project: project,
            IAMUser: IAMUser(id: "user-1", username: "testuser", isRoot: true),
            bucket: Bucket(name: "test-bucket"),
            prefix: "documents/"
        )
        let drive = DS3Drive(id: UUID(), name: "My Drive", syncAnchor: syncAnchor)

        let data = try JSONEncoder().encode(drive)
        let decoded = try JSONDecoder().decode(DS3Drive.self, from: data)
        XCTAssertEqual(decoded.id, drive.id)
        XCTAssertEqual(decoded.name, "My Drive")
        XCTAssertEqual(decoded.syncAnchor.bucket.name, "test-bucket")
        XCTAssertEqual(decoded.syncAnchor.prefix, "documents/")
    }

    func testDS3DriveWithNilPrefix() throws {
        let project = Project(
            id: "proj-1", name: "Test", description: "desc",
            email: "e@c.io", createdAt: "2023-01-01", tenantId: "t-1",
            users: []
        )
        let syncAnchor = SyncAnchor(
            project: project,
            IAMUser: IAMUser(id: "u-1", username: "user", isRoot: false),
            bucket: Bucket(name: "bucket"),
            prefix: nil
        )
        let drive = DS3Drive(id: UUID(), name: "Drive", syncAnchor: syncAnchor)

        let data = try JSONEncoder().encode(drive)
        let decoded = try JSONDecoder().decode(DS3Drive.self, from: data)
        XCTAssertNil(decoded.syncAnchor.prefix)
    }

    // MARK: - DS3ApiKey

    func testDS3ApiKeyRoundTrip() throws {
        let json = """
        {
            "name": "DS3Drive-for-macOS(user_project_uuid)",
            "api_key": "AKIAIOSFODNN7EXAMPLE",
            "secret_key": "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
            "created_at": "2023-11-14T22:13:20.000Z"
        }
        """.data(using: .utf8)!

        let apiKey = try JSONDecoder().decode(DS3ApiKey.self, from: json)
        XCTAssertEqual(apiKey.name, "DS3Drive-for-macOS(user_project_uuid)")
        XCTAssertEqual(apiKey.apiKey, "AKIAIOSFODNN7EXAMPLE")
        XCTAssertEqual(apiKey.secretKey, "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY")

        // Re-encode round trip
        let reencoded = try JSONEncoder().encode(apiKey)
        let redecoded = try JSONDecoder().decode(DS3ApiKey.self, from: reencoded)
        XCTAssertEqual(redecoded, apiKey)
    }

    func testDS3ApiKeyWithoutSecretKey() throws {
        let json = """
        {
            "name": "test-key",
            "api_key": "AKIATEST",
            "created_at": "2023-11-14T22:13:20.000Z"
        }
        """.data(using: .utf8)!

        let apiKey = try JSONDecoder().decode(DS3ApiKey.self, from: json)
        XCTAssertNil(apiKey.secretKey)

        // Secret key should not be present in re-encoded output
        let reencoded = try JSONEncoder().encode(apiKey)
        let jsonDict = try JSONSerialization.jsonObject(with: reencoded) as? [String: Any]
        XCTAssertNil(jsonDict?["secret_key"])
    }

    func testDS3ApiKeyInvalidDateFails() {
        let json = """
        {
            "name": "test",
            "api_key": "AKIA",
            "created_at": "invalid-date"
        }
        """.data(using: .utf8)!

        XCTAssertThrowsError(try JSONDecoder().decode(DS3ApiKey.self, from: json))
    }

    func testDS3ApiKeyEquality() throws {
        let json1 = """
        {"name":"key1","api_key":"AKIA1","secret_key":"secret1","created_at":"2023-11-14T22:13:20.000Z"}
        """.data(using: .utf8)!
        let json2 = """
        {"name":"key1","api_key":"AKIA1","secret_key":"secret2","created_at":"2024-01-01T00:00:00.000Z"}
        """.data(using: .utf8)!

        let key1 = try JSONDecoder().decode(DS3ApiKey.self, from: json1)
        let key2 = try JSONDecoder().decode(DS3ApiKey.self, from: json2)

        // Equality is based on name + apiKey only
        XCTAssertEqual(key1, key2)
    }

    // MARK: - SyncAnchor

    func testSyncAnchorRoundTrip() throws {
        let project = Project(
            id: "proj-1", name: "Test", description: "desc",
            email: "e@c.io", createdAt: "2023-01-01", tenantId: "t-1",
            users: [IAMUser(id: "u-1", username: "user", isRoot: true)]
        )
        let anchor = SyncAnchor(
            project: project,
            IAMUser: IAMUser(id: "u-1", username: "user", isRoot: true),
            bucket: Bucket(name: "my-bucket"),
            prefix: "prefix/"
        )

        try assertDecodable(anchor)
    }

    // MARK: - Project

    func testProjectRoundTrip() throws {
        let project = Project(
            id: "proj-1", name: "TestProject", description: "A test",
            email: "project@cubbit.io", createdAt: "2023-01-01",
            bannedAt: nil, imageUrl: "https://example.com/img.png",
            tenantId: "tenant-1", rootAccountEmail: "root@cubbit.io",
            users: [
                IAMUser(id: "user-1", username: "admin", isRoot: true),
                IAMUser(id: "user-2", username: "viewer", isRoot: false)
            ]
        )

        let data = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(Project.self, from: data)
        XCTAssertEqual(decoded.id, "proj-1")
        XCTAssertEqual(decoded.name, "TestProject")
        XCTAssertEqual(decoded.users.count, 2)
        XCTAssertEqual(decoded.imageUrl, "https://example.com/img.png")
        XCTAssertEqual(decoded.rootAccountEmail, "root@cubbit.io")
    }

    func testProjectShort() {
        let project = Project(
            id: "p", name: "MyProject", description: "", email: "",
            createdAt: "", tenantId: "", users: []
        )
        XCTAssertEqual(project.short(), "My")
    }

    func testProjectShortSingleChar() {
        let project = Project(
            id: "p", name: "X", description: "", email: "",
            createdAt: "", tenantId: "", users: []
        )
        XCTAssertEqual(project.short(), "X")
    }

    // MARK: - IAMUser

    func testIAMUserRoundTrip() throws {
        let user = IAMUser(id: "user-123", username: "testuser", isRoot: true)
        let data = try JSONEncoder().encode(user)
        let decoded = try JSONDecoder().decode(IAMUser.self, from: data)
        XCTAssertEqual(decoded.id, "user-123")
        XCTAssertEqual(decoded.username, "testuser")
        XCTAssertTrue(decoded.isRoot)
    }

    func testIAMUserFromExternalJSON() throws {
        // Matches the API response format with snake_case keys
        let json = """
        {"user_id": "u-42", "user_name": "admin", "is_root": false}
        """.data(using: .utf8)!

        let user = try JSONDecoder().decode(IAMUser.self, from: json)
        XCTAssertEqual(user.id, "u-42")
        XCTAssertEqual(user.username, "admin")
        XCTAssertFalse(user.isRoot)
    }

    // MARK: - Bucket

    func testBucketRoundTrip() throws {
        let bucket = Bucket(name: "test-bucket-123")
        try assertRoundTrip(bucket)
    }

    func testBucketIdentifiable() {
        let bucket = Bucket(name: "my-bucket")
        XCTAssertEqual(bucket.id, "my-bucket")
    }

    // MARK: - Challenge

    func testChallengeRoundTrip() throws {
        let challenge = Challenge(challenge: "random-challenge-string", salt: "random-salt")
        let data = try JSONEncoder().encode(challenge)
        let decoded = try JSONDecoder().decode(Challenge.self, from: data)
        XCTAssertEqual(decoded.challenge, "random-challenge-string")
        XCTAssertEqual(decoded.salt, "random-salt")
    }

    // MARK: - RefreshToken

    func testRefreshTokenRoundTrip() throws {
        let token = RefreshToken(
            cid: "client-1", cversion: 2, exp: 1700000000,
            sub: "user-123", subType: "account", type: "refresh"
        )
        let data = try JSONEncoder().encode(token)
        let decoded = try JSONDecoder().decode(RefreshToken.self, from: data)
        XCTAssertEqual(decoded.cid, "client-1")
        XCTAssertEqual(decoded.sub, "user-123")
        XCTAssertEqual(decoded.exp, 1700000000)
    }

    // MARK: - ConflictInfo

    func testConflictInfoRoundTrip() throws {
        let driveId = UUID()
        let conflict = ConflictInfo(
            driveId: driveId,
            originalFilename: "report.pdf",
            conflictKey: "docs/report (Conflict on mac 2023-11-14 ab12).pdf"
        )
        let data = try JSONEncoder().encode(conflict)
        let decoded = try JSONDecoder().decode(ConflictInfo.self, from: data)
        XCTAssertEqual(decoded.driveId, driveId)
        XCTAssertEqual(decoded.originalFilename, "report.pdf")
        XCTAssertEqual(decoded.conflictKey, conflict.conflictKey)
    }

    // MARK: - TrashSettings

    func testTrashSettingsRoundTrip() throws {
        let settings = TrashSettings(enabled: true, retentionDays: 30)
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(TrashSettings.self, from: data)
        XCTAssertEqual(decoded.enabled, true)
        XCTAssertEqual(decoded.retentionDays, 30)
    }

    func testTrashSettingsDefaults() {
        let settings = TrashSettings()
        XCTAssertTrue(settings.enabled)
        XCTAssertEqual(settings.retentionDays, DefaultSettings.Trash.defaultRetentionDays)
    }

    // MARK: - DS3DriveStatus

    func testDriveStatusRawValues() {
        XCTAssertEqual(DS3DriveStatus.sync.rawValue, "sync")
        XCTAssertEqual(DS3DriveStatus.indexing.rawValue, "indexing")
        XCTAssertEqual(DS3DriveStatus.idle.rawValue, "idle")
        XCTAssertEqual(DS3DriveStatus.error.rawValue, "error")
        XCTAssertEqual(DS3DriveStatus.paused.rawValue, "paused")
    }

    // MARK: - TransferStatus

    func testTransferStatusComparable() {
        XCTAssertTrue(TransferStatus.syncing < TransferStatus.error)
        XCTAssertTrue(TransferStatus.error < TransferStatus.completed)
        XCTAssertTrue(TransferStatus.syncing < TransferStatus.completed)
    }

    // MARK: - RecentFileEntry

    func testRecentFileEntryDisplaySize() {
        let entry = RecentFileEntry(
            driveId: UUID(), filename: "test.txt", size: 2048,
            status: .completed, timestamp: Date()
        )
        XCTAssertEqual(entry.displaySize, "2.0 KB")

        let largeEntry = RecentFileEntry(
            driveId: UUID(), filename: "big.zip", size: 5 * 1024 * 1024,
            status: .completed, timestamp: Date()
        )
        XCTAssertEqual(largeEntry.displaySize, "5.0 MB")
    }

    func testRecentFileEntryDisplaySpeed() {
        let syncing = RecentFileEntry(
            driveId: UUID(), filename: "file.txt", size: 1000,
            status: .syncing, timestamp: Date(), speed: 1024
        )
        XCTAssertEqual(syncing.displaySpeed, "1.0 KB/s")

        let idle = RecentFileEntry(
            driveId: UUID(), filename: "file.txt", size: 1000,
            status: .completed, timestamp: Date(), speed: 1024
        )
        XCTAssertNil(idle.displaySpeed)
    }

    // MARK: - S3 Supporting Types

    func testS3ListingResult() {
        let result = S3ListingResult(
            objects: [S3ObjectSummary(key: "a.txt", etag: "abc", lastModified: nil, size: 100)],
            commonPrefixes: ["folder/"],
            nextContinuationToken: "token123",
            isTruncated: true
        )
        XCTAssertEqual(result.objects.count, 1)
        XCTAssertEqual(result.objects.first?.key, "a.txt")
        XCTAssertEqual(result.commonPrefixes, ["folder/"])
        XCTAssertTrue(result.isTruncated)
    }

    func testS3ObjectMetadata() {
        let metadata = S3ObjectMetadata(
            etag: "abc123", contentType: "application/pdf",
            lastModified: Date(), versionId: "v1",
            contentLength: 42, metadata: ["x-custom": "value"]
        )
        XCTAssertEqual(metadata.etag, "abc123")
        XCTAssertEqual(metadata.contentLength, 42)
        XCTAssertEqual(metadata.metadata?["x-custom"], "value")
    }

    func testTransferProgress() {
        let progress = TransferProgress(
            bytesTransferred: 500, totalBytes: 1000,
            duration: 2.5, direction: .upload, filename: "test.txt"
        )
        XCTAssertEqual(progress.bytesTransferred, 500)
        XCTAssertEqual(progress.totalBytes, 1000)
        XCTAssertEqual(progress.direction, .upload)
    }

    func testPartDescriptor() {
        let part = PartDescriptor(partNumber: 1, offset: 0, length: 5 * 1024 * 1024)
        XCTAssertEqual(part.partNumber, 1)
        XCTAssertEqual(part.offset, 0)
        XCTAssertEqual(part.length, 5_242_880)
    }
}
