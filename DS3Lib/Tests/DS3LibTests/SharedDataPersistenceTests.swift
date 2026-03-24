import XCTest
@testable import DS3Lib

/// Tests for SharedData persistence extensions.
/// Since the App Group container is not available in the SPM test runner,
/// we test the encode/decode/file-I/O logic using a temporary directory.
final class SharedDataPersistenceTests: XCTestCase {
    var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DS3LibTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Drives Persistence

    func testPersistAndLoadDrives() throws {
        let project = Project(
            id: "proj-1", name: "Test", description: "desc",
            email: "e@c.io", createdAt: "2023-01-01", tenantId: "t-1",
            users: [IAMUser(id: "u-1", username: "user", isRoot: true)]
        )
        let drives = [
            DS3Drive(
                id: UUID(), name: "Drive A",
                syncAnchor: SyncAnchor(
                    project: project,
                    IAMUser: IAMUser(id: "u-1", username: "user", isRoot: true),
                    bucket: Bucket(name: "bucket-a"),
                    prefix: "prefix/"
                )
            ),
            DS3Drive(
                id: UUID(), name: "Drive B",
                syncAnchor: SyncAnchor(
                    project: project,
                    IAMUser: IAMUser(id: "u-1", username: "user", isRoot: true),
                    bucket: Bucket(name: "bucket-b"),
                    prefix: nil
                )
            )
        ]

        let drivesURL = tempDir.appendingPathComponent(DefaultSettings.FileNames.drivesFileName)
        let encoder = JSONEncoder()
        try encoder.encode(drives).write(to: drivesURL)

        let loaded = try JSONDecoder().decode([DS3Drive].self, from: Data(contentsOf: drivesURL))
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded[0].name, "Drive A")
        XCTAssertEqual(loaded[1].name, "Drive B")
        XCTAssertEqual(loaded[0].syncAnchor.bucket.name, "bucket-a")
        XCTAssertNil(loaded[1].syncAnchor.prefix)
    }

    func testLoadDriveById() throws {
        let driveId = UUID()
        let project = Project(
            id: "proj-1", name: "Test", description: "desc",
            email: "e@c.io", createdAt: "2023-01-01", tenantId: "t-1",
            users: []
        )
        let drives = [
            DS3Drive(
                id: driveId, name: "Target Drive",
                syncAnchor: SyncAnchor(
                    project: project,
                    IAMUser: IAMUser(id: "u-1", username: "user", isRoot: false),
                    bucket: Bucket(name: "bucket"),
                    prefix: nil
                )
            )
        ]

        let drivesURL = tempDir.appendingPathComponent(DefaultSettings.FileNames.drivesFileName)
        try JSONEncoder().encode(drives).write(to: drivesURL)

        let loaded = try JSONDecoder().decode([DS3Drive].self, from: Data(contentsOf: drivesURL))
        let found = loaded.first(where: { $0.id == driveId })
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.name, "Target Drive")
    }

    func testLoadMissingDriveFileThrows() {
        let drivesURL = tempDir.appendingPathComponent(DefaultSettings.FileNames.drivesFileName)
        XCTAssertThrowsError(try Data(contentsOf: drivesURL))
    }

    // MARK: - API Keys Persistence

    func testPersistAndLoadApiKeys() throws {
        let json1 = """
        {"name":"key-1","api_key":"AKIA1","secret_key":"secret1","created_at":"2023-11-14T22:13:20.000Z"}
        """.data(using: .utf8)!
        let json2 = """
        {"name":"key-2","api_key":"AKIA2","created_at":"2024-01-01T00:00:00.000Z"}
        """.data(using: .utf8)!

        let key1 = try JSONDecoder().decode(DS3ApiKey.self, from: json1)
        let key2 = try JSONDecoder().decode(DS3ApiKey.self, from: json2)

        let apiKeys = [key1, key2]
        let keysURL = tempDir.appendingPathComponent(DefaultSettings.FileNames.credentialsFileName)
        try JSONEncoder().encode(apiKeys).write(to: keysURL)

        let loaded = try JSONDecoder().decode([DS3ApiKey].self, from: Data(contentsOf: keysURL))
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded[0].name, "key-1")
        XCTAssertNotNil(loaded[0].secretKey)
        XCTAssertEqual(loaded[1].name, "key-2")
        XCTAssertNil(loaded[1].secretKey)
    }

    func testDeleteApiKeyByName() throws {
        let json = """
        [
            {"name":"keep","api_key":"AKIA1","created_at":"2023-11-14T22:13:20.000Z"},
            {"name":"delete-me","api_key":"AKIA2","created_at":"2023-11-14T22:13:20.000Z"}
        ]
        """.data(using: .utf8)!

        let keysURL = tempDir.appendingPathComponent(DefaultSettings.FileNames.credentialsFileName)
        try json.write(to: keysURL)

        var apiKeys = try JSONDecoder().decode([DS3ApiKey].self, from: Data(contentsOf: keysURL))
        apiKeys.removeAll(where: { $0.name == "delete-me" })
        try JSONEncoder().encode(apiKeys).write(to: keysURL)

        let loaded = try JSONDecoder().decode([DS3ApiKey].self, from: Data(contentsOf: keysURL))
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].name, "keep")
    }

    // MARK: - Account Persistence

    func testPersistAndLoadAccount() throws {
        let account = Account(
            id: "acc-1", firstName: "Test", lastName: "User",
            isInternal: false, isBanned: false, createdAt: "2023-01-01",
            maxAllowedProjects: 5,
            emails: [AccountEmail(
                id: "e-1", email: "test@cubbit.io", isDefault: true,
                createdAt: "2023-01-01", isVerified: true, tenantId: "t-1"
            )],
            isTwoFactorEnabled: false, tenantId: "t-1",
            endpointGateway: "https://s3.cubbit.eu", authProvider: "cubbit"
        )

        let accountURL = tempDir.appendingPathComponent(DefaultSettings.FileNames.accountFileName)
        try JSONEncoder().encode(account).write(to: accountURL)

        let loaded = try JSONDecoder().decode(Account.self, from: Data(contentsOf: accountURL))
        XCTAssertEqual(loaded.id, "acc-1")
        XCTAssertEqual(loaded.firstName, "Test")
        XCTAssertEqual(loaded.emails.count, 1)
    }

    // MARK: - AccountSession Persistence

    func testPersistAndLoadAccountSession() throws {
        let tokenJson = """
        {"token":"jwt-token","exp":1700000000,"exp_date":"2023-11-14T22:13:20.000Z"}
        """.data(using: .utf8)!
        let token = try JSONDecoder().decode(Token.self, from: tokenJson)
        let session = AccountSession(token: token, refreshToken: "refresh-abc")

        let sessionURL = tempDir.appendingPathComponent(DefaultSettings.FileNames.accountSessionFileName)
        try JSONEncoder().encode(session).write(to: sessionURL)

        let loaded = try JSONDecoder().decode(AccountSession.self, from: Data(contentsOf: sessionURL))
        XCTAssertEqual(loaded.token.token, "jwt-token")
        XCTAssertEqual(loaded.refreshToken, "refresh-abc")
    }

    // MARK: - Pause State Persistence

    func testPersistAndLoadPauseState() throws {
        let driveId1 = UUID()
        let driveId2 = UUID()
        var state: [String: Bool] = [:]
        state[driveId1.uuidString] = true
        state[driveId2.uuidString] = true

        let pauseURL = tempDir.appendingPathComponent(DefaultSettings.FileNames.pauseStateFileName)
        try JSONEncoder().encode(state).write(to: pauseURL)

        let loaded = try JSONDecoder().decode([String: Bool].self, from: Data(contentsOf: pauseURL))
        XCTAssertEqual(loaded[driveId1.uuidString], true)
        XCTAssertEqual(loaded[driveId2.uuidString], true)

        // Unpause one drive
        var updated = loaded
        updated.removeValue(forKey: driveId1.uuidString)
        try JSONEncoder().encode(updated).write(to: pauseURL)

        let reloaded = try JSONDecoder().decode([String: Bool].self, from: Data(contentsOf: pauseURL))
        XCTAssertNil(reloaded[driveId1.uuidString])
        XCTAssertEqual(reloaded[driveId2.uuidString], true)
    }

    func testEmptyPauseState() throws {
        let pauseURL = tempDir.appendingPathComponent(DefaultSettings.FileNames.pauseStateFileName)
        let empty: [String: Bool] = [:]
        try JSONEncoder().encode(empty).write(to: pauseURL)

        let loaded = try JSONDecoder().decode([String: Bool].self, from: Data(contentsOf: pauseURL))
        XCTAssertTrue(loaded.isEmpty)
    }

    // MARK: - Trash Settings Persistence

    func testPersistAndLoadTrashSettings() throws {
        let driveId = UUID()
        let settings = TrashSettings(enabled: true, retentionDays: 14)

        var allSettings: [String: TrashSettings] = [:]
        allSettings[driveId.uuidString] = settings

        let trashURL = tempDir.appendingPathComponent(DefaultSettings.FileNames.trashSettingsFileName)
        try JSONEncoder().encode(allSettings).write(to: trashURL)

        let loaded = try JSONDecoder().decode([String: TrashSettings].self, from: Data(contentsOf: trashURL))
        let loadedSettings = loaded[driveId.uuidString]
        XCTAssertNotNil(loadedSettings)
        XCTAssertTrue(loadedSettings!.enabled)
        XCTAssertEqual(loadedSettings!.retentionDays, 14)
    }

    func testTrashSettingsDefaultsForMissingDrive() {
        // When no settings exist for a drive, defaults should be used
        let defaultSettings = TrashSettings()
        XCTAssertTrue(defaultSettings.enabled)
        XCTAssertEqual(defaultSettings.retentionDays, DefaultSettings.Trash.defaultRetentionDays)
    }

    // MARK: - Empty Trash Flag Persistence

    func testEmptyTrashFlag() throws {
        let driveId = UUID()
        var flags: [String: Bool] = [:]
        flags[driveId.uuidString] = true

        let flagURL = tempDir.appendingPathComponent(DefaultSettings.FileNames.emptyTrashFlagFileName)
        try JSONEncoder().encode(flags).write(to: flagURL)

        let loaded = try JSONDecoder().decode([String: Bool].self, from: Data(contentsOf: flagURL))
        XCTAssertEqual(loaded[driveId.uuidString], true)

        // Clear the flag
        var cleared = loaded
        cleared[driveId.uuidString] = nil
        try JSONEncoder().encode(cleared).write(to: flagURL)

        let reloaded = try JSONDecoder().decode([String: Bool].self, from: Data(contentsOf: flagURL))
        XCTAssertNil(reloaded[driveId.uuidString])
    }

    // MARK: - Tenant Persistence

    func testPersistAndLoadTenantName() throws {
        let tenantURL = tempDir.appendingPathComponent(DefaultSettings.FileNames.tenantFileName)
        let tenant = "my-tenant"
        try tenant.write(to: tenantURL, atomically: true, encoding: .utf8)

        let loaded = try String(contentsOf: tenantURL, encoding: .utf8)
        XCTAssertEqual(loaded, tenant)
    }

    // MARK: - Coordinator URL Persistence

    func testPersistAndLoadCoordinatorURL() throws {
        let urlFile = tempDir.appendingPathComponent(DefaultSettings.FileNames.coordinatorURLFileName)
        let coordinatorURL = "https://custom.coordinator.example.com"
        try coordinatorURL.write(to: urlFile, atomically: true, encoding: .utf8)

        let loaded = try String(contentsOf: urlFile, encoding: .utf8)
        XCTAssertEqual(loaded, coordinatorURL)
    }

    // MARK: - File Name Constants

    func testFileNameConstants() {
        XCTAssertEqual(DefaultSettings.FileNames.drivesFileName, "drives.json")
        XCTAssertEqual(DefaultSettings.FileNames.credentialsFileName, "credentials.json")
        XCTAssertEqual(DefaultSettings.FileNames.accountFileName, "account.json")
        XCTAssertEqual(DefaultSettings.FileNames.accountSessionFileName, "accountSession.json")
        XCTAssertEqual(DefaultSettings.FileNames.pauseStateFileName, "pauseState.json")
        XCTAssertEqual(DefaultSettings.FileNames.trashSettingsFileName, "trashSettings.json")
        XCTAssertEqual(DefaultSettings.FileNames.emptyTrashFlagFileName, "emptyTrashFlag.json")
        XCTAssertEqual(DefaultSettings.FileNames.tenantFileName, "tenant.txt")
        XCTAssertEqual(DefaultSettings.FileNames.coordinatorURLFileName, "coordinatorURL.txt")
    }
}
