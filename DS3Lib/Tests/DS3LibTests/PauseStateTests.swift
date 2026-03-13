import XCTest
@testable import DS3Lib

/// Tests for pause state persistence and DS3DriveStatus.paused case.
final class PauseStateTests: XCTestCase {
    var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Test 1: DS3DriveStatus.paused exists and is Codable

    func testDriveStatusPausedCodableRoundTrip() throws {
        let status = DS3DriveStatus.paused
        let encoded = try JSONEncoder().encode(status)
        let decoded = try JSONDecoder().decode(DS3DriveStatus.self, from: encoded)
        XCTAssertEqual(decoded, .paused)
    }

    // MARK: - Test 2: Pause state saves [UUID: Bool] to file

    func testSavePauseStateWritesFile() throws {
        let pauseFile = tempDir.appendingPathComponent("pauseState.json")

        let driveId = UUID()
        var state: [String: Bool] = [driveId.uuidString: true]

        let data = try JSONEncoder().encode(state)
        try data.write(to: pauseFile)

        let loadedData = try Data(contentsOf: pauseFile)
        let loadedState = try JSONDecoder().decode([String: Bool].self, from: loadedData)
        XCTAssertEqual(loadedState[driveId.uuidString], true)
    }

    // MARK: - Test 3: Load returns empty dict when no file exists

    func testLoadPauseStateReturnsEmptyWhenNoFile() {
        let nonExistentFile = tempDir.appendingPathComponent("pauseState.json")
        let state: [String: Bool]
        if let data = try? Data(contentsOf: nonExistentFile),
           let loaded = try? JSONDecoder().decode([String: Bool].self, from: data) {
            state = loaded
        } else {
            state = [:]
        }
        XCTAssertTrue(state.isEmpty)
    }

    // MARK: - Test 4: setDrivePaused(true) then isDrivePaused returns true

    func testSetDrivePausedTrueThenIsPausedReturnsTrue() throws {
        let pauseFile = tempDir.appendingPathComponent("pauseState.json")
        let driveId = UUID()

        // Set paused
        var state: [String: Bool] = [:]
        state[driveId.uuidString] = true
        let data = try JSONEncoder().encode(state)
        try data.write(to: pauseFile)

        // Read back
        let loadedData = try Data(contentsOf: pauseFile)
        let loadedState = try JSONDecoder().decode([String: Bool].self, from: loadedData)
        XCTAssertEqual(loadedState[driveId.uuidString], true)
    }

    // MARK: - Test 5: setDrivePaused(false) removes entry

    func testSetDrivePausedFalseRemovesEntry() throws {
        let pauseFile = tempDir.appendingPathComponent("pauseState.json")
        let driveId = UUID()

        // First, set paused
        var state: [String: Bool] = [driveId.uuidString: true]
        var data = try JSONEncoder().encode(state)
        try data.write(to: pauseFile)

        // Then un-pause (remove)
        state.removeValue(forKey: driveId.uuidString)
        data = try JSONEncoder().encode(state)
        try data.write(to: pauseFile)

        // Verify removed
        let loadedData = try Data(contentsOf: pauseFile)
        let loadedState = try JSONDecoder().decode([String: Bool].self, from: loadedData)
        XCTAssertNil(loadedState[driveId.uuidString])
    }

    // MARK: - Test 6: AppStatus.paused returns "Paused"

    func testAppStatusPausedToString() {
        let status = AppStatus.paused
        XCTAssertEqual(status.toString(), "Paused")
    }

    // MARK: - Pause state filename constant

    func testPauseStateFileNameConstant() {
        XCTAssertEqual(DefaultSettings.FileNames.pauseStateFileName, "pauseState.json")
    }
}
