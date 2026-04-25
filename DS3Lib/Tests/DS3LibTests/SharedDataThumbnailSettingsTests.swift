import XCTest
@testable import DS3Lib

/// Tests for `SharedData+thumbnailSettings.swift` persistence helpers.
///
/// The App Group container is not available in the SPM test runner, so these
/// tests exercise the same encode/decode/file-I/O contract against a temporary
/// directory — mirroring `SharedDataPersistenceTests`.
///
/// Locked decisions covered:
/// - D-23: 1:1 mirror of `SharedData+trashSettings.swift` template
/// - D-24: default `enabled == false` at struct init AND fallback-on-missing-file
/// - D-25: no speculative fields (only `enabled`)
final class SharedDataThumbnailSettingsTests: XCTestCase {
    var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DS3LibThumbTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Default Init (D-24 regression guard)

    func testDefaultInitDisabled() {
        // D-24: ThumbnailSettings() must have enabled == false.
        // This regression-guards an accidental future flip to `true`,
        // which would silently activate the renderer for every drive on first run.
        let settings = ThumbnailSettings()
        XCTAssertFalse(settings.enabled, "Default ThumbnailSettings() must be disabled (D-24)")
    }

    func testExplicitInitTrue() {
        let settings = ThumbnailSettings(enabled: true)
        XCTAssertTrue(settings.enabled)
    }

    // MARK: - Round-trip Persistence

    func testPersistAndLoadThumbnailSettings() throws {
        let driveId = UUID()
        let settings = ThumbnailSettings(enabled: true)

        var allSettings: [String: ThumbnailSettings] = [:]
        allSettings[driveId.uuidString] = settings

        let url = tempDir.appendingPathComponent(DefaultSettings.FileNames.thumbnailSettingsFileName)
        try JSONEncoder().encode(allSettings).write(to: url)

        let loaded = try JSONDecoder().decode(
            [String: ThumbnailSettings].self,
            from: Data(contentsOf: url)
        )
        let loadedSettings = loaded[driveId.uuidString]
        XCTAssertNotNil(loadedSettings)
        XCTAssertTrue(loadedSettings!.enabled)
    }

    func testRoundTripDisabled() throws {
        let driveId = UUID()
        let settings = ThumbnailSettings(enabled: false)

        var allSettings: [String: ThumbnailSettings] = [:]
        allSettings[driveId.uuidString] = settings

        let url = tempDir.appendingPathComponent(DefaultSettings.FileNames.thumbnailSettingsFileName)
        try JSONEncoder().encode(allSettings).write(to: url)

        let loaded = try JSONDecoder().decode(
            [String: ThumbnailSettings].self,
            from: Data(contentsOf: url)
        )
        XCTAssertEqual(loaded[driveId.uuidString]?.enabled, false)
    }

    // MARK: - Multi-drive Isolation

    func testMultipleDrivesIndependent() throws {
        let driveA = UUID()
        let driveB = UUID()

        var allSettings: [String: ThumbnailSettings] = [:]
        allSettings[driveA.uuidString] = ThumbnailSettings(enabled: true)
        allSettings[driveB.uuidString] = ThumbnailSettings(enabled: false)

        let url = tempDir.appendingPathComponent(DefaultSettings.FileNames.thumbnailSettingsFileName)
        try JSONEncoder().encode(allSettings).write(to: url)

        let loaded = try JSONDecoder().decode(
            [String: ThumbnailSettings].self,
            from: Data(contentsOf: url)
        )
        XCTAssertEqual(loaded[driveA.uuidString]?.enabled, true)
        XCTAssertEqual(loaded[driveB.uuidString]?.enabled, false)
    }

    // MARK: - Missing File / Missing Drive Defaults (D-24)

    func testMissingFileDecodeFails() {
        // The file simply doesn't exist — load helpers wrap this in `try?` and
        // return defaults. Here we just verify the decode itself fails for an
        // absent file, mirroring the pattern in `SharedDataPersistenceTests`.
        let url = tempDir.appendingPathComponent(DefaultSettings.FileNames.thumbnailSettingsFileName)
        XCTAssertThrowsError(try Data(contentsOf: url))
    }

    func testMissingDriveFallsBackToDefault() throws {
        // File exists with one drive's settings — looking up a *different* drive
        // must yield the default (`enabled == false`) per D-24.
        let driveA = UUID()
        let driveB = UUID()
        var allSettings: [String: ThumbnailSettings] = [:]
        allSettings[driveA.uuidString] = ThumbnailSettings(enabled: true)

        let url = tempDir.appendingPathComponent(DefaultSettings.FileNames.thumbnailSettingsFileName)
        try JSONEncoder().encode(allSettings).write(to: url)

        let loaded = try JSONDecoder().decode(
            [String: ThumbnailSettings].self,
            from: Data(contentsOf: url)
        )
        let fallback = loaded[driveB.uuidString] ?? ThumbnailSettings()
        XCTAssertFalse(fallback.enabled, "Missing-drive fallback must default to enabled = false (D-24)")
    }

    // MARK: - Serial Save/Load Stress (proxy for coordinated-write safety)

    func testSerialSaveLoadCyclesPreserveValue() throws {
        let driveId = UUID()
        let url = tempDir.appendingPathComponent(DefaultSettings.FileNames.thumbnailSettingsFileName)

        for cycle in 0..<50 {
            let enabled = cycle % 2 == 0
            var allSettings = (try? JSONDecoder().decode(
                [String: ThumbnailSettings].self,
                from: Data(contentsOf: url)
            )) ?? [:]
            allSettings[driveId.uuidString] = ThumbnailSettings(enabled: enabled)
            try JSONEncoder().encode(allSettings).write(to: url, options: .atomic)

            let reloaded = try JSONDecoder().decode(
                [String: ThumbnailSettings].self,
                from: Data(contentsOf: url)
            )
            XCTAssertEqual(reloaded[driveId.uuidString]?.enabled, enabled, "Cycle \(cycle) round-trip mismatch")
        }
    }

    // MARK: - File Name Constant

    func testThumbnailSettingsFileNameConstant() {
        XCTAssertEqual(DefaultSettings.FileNames.thumbnailSettingsFileName, "thumbnailSettings.json")
    }

    // MARK: - DefaultSettings.Thumbnail Constants (Pitfall 2 — bare metadata keys)

    func testThumbnailMetadataKeysAreBare() {
        // Pitfall 2: Soto auto-prepends `x-amz-meta-` via S3_shapes.swift's
        // `AWSMemberEncoding(label: "metadata", location: .headerPrefix("x-amz-meta-"))`.
        // Our constants must NOT contain the prefix or it will be doubled on the wire.
        XCTAssertEqual(DefaultSettings.Thumbnail.sourceETagMetadataKey, "source-etag")
        XCTAssertEqual(DefaultSettings.Thumbnail.formatVersionMetadataKey, "ds3drive-thumb-version")
        XCTAssertFalse(
            DefaultSettings.Thumbnail.sourceETagMetadataKey.hasPrefix("x-amz-meta-"),
            "sourceETagMetadataKey must be bare (Pitfall 2)"
        )
        XCTAssertFalse(
            DefaultSettings.Thumbnail.formatVersionMetadataKey.hasPrefix("x-amz-meta-"),
            "formatVersionMetadataKey must be bare (Pitfall 2)"
        )
    }

    func testThumbnailFormatVersion() {
        XCTAssertEqual(DefaultSettings.Thumbnail.formatVersion, 1)
    }

    func testThumbnailMaxSinglePartBytes() {
        XCTAssertEqual(DefaultSettings.Thumbnail.maxSinglePartBytes, 500_000)
    }
}
