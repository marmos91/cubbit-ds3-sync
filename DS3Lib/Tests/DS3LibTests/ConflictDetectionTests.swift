import XCTest
import SwiftData
@testable import DS3Lib

/// Integration tests for conflict detection logic across ConflictNaming, ETagUtils,
/// MetadataStore conflict tracking, and ConflictInfo serialization.
final class ConflictDetectionTests: XCTestCase {
    private var container: ModelContainer!
    private var metadataStore: MetadataStore!
    private let testDriveId = UUID()

    override func setUp() async throws {
        let schema = Schema(versionedSchema: SyncedItemSchemaV2.self)
        let config = ModelConfiguration(
            "TestConflictDetection",
            schema: schema,
            isStoredInMemoryOnly: true
        )
        container = try ModelContainer(for: schema, configurations: [config])
        metadataStore = MetadataStore(modelContainer: container)
    }

    override func tearDown() async throws {
        container = nil
        metadataStore = nil
    }

    // MARK: - Test 1: ETag mismatch detected

    func testETagMismatchDetected() {
        let storedETag = "abc123"
        let remoteETag = "def456"
        XCTAssertFalse(ETagUtils.areEqual(storedETag, remoteETag), "Different ETags should not be equal")
    }

    // MARK: - Test 2: ETag match passes through

    func testETagMatchPassesThrough() {
        let storedETag = "abc123"
        let remoteETag = "abc123"
        XCTAssertTrue(ETagUtils.areEqual(storedETag, remoteETag), "Same ETags should be equal")
    }

    // MARK: - Test 3: Quoted vs unquoted ETag comparison

    func testQuotedVsUnquotedETagComparison() {
        let storedETag = "abc123"
        let remoteETag = "\"abc123\""
        XCTAssertTrue(
            ETagUtils.areEqual(storedETag, remoteETag),
            "Quoted and unquoted versions of the same ETag should be equal"
        )
    }

    // MARK: - Test 4: Nil stored ETag skips conflict check

    func testNilStoredETagSkipsConflictCheck() {
        let nilETag: String? = nil
        let remoteETag = "abc123"
        XCTAssertFalse(
            ETagUtils.areEqual(nilETag, remoteETag),
            "Nil stored ETag should not match -- first sync, no conflict possible"
        )
    }

    // MARK: - Test 5: Conflict copy has .conflict status in MetadataStore

    func testConflictCopyHasConflictStatusInMetadataStore() async throws {
        let conflictKey = ConflictNaming.conflictKey(
            originalKey: "docs/report.pdf",
            hostname: "test-host",
            date: Date()
        )

        try await metadataStore.upsertItem(
            s3Key: conflictKey,
            driveId: testDriveId,
            etag: "conflict-etag",
            syncStatus: .conflict,
            size: 1024
        )

        let status = try await metadataStore.fetchItemSyncStatus(byKey: conflictKey, driveId: testDriveId)
        XCTAssertEqual(status, SyncStatus.conflict.rawValue, "Conflict copy should have .conflict status")
    }

    // MARK: - Test 6: Multiple conflicts produce unique keys

    func testMultipleConflictsProduceUniqueKeys() {
        let date1 = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14
        let date2 = Date(timeIntervalSince1970: 1_700_000_001) // 1 second later

        let key1 = ConflictNaming.conflictKey(originalKey: "file.txt", hostname: "mac", date: date1)
        let key2 = ConflictNaming.conflictKey(originalKey: "file.txt", hostname: "mac", date: date2)

        XCTAssertNotEqual(key1, key2, "Conflict keys with different timestamps should be unique")
    }

    // MARK: - Test 7: ETag persisted after upsertItem

    func testETagPersistedAfterUpsert() async throws {
        let s3Key = "photos/image.jpg"
        let expectedETag = "e3b0c44298fc1c149afbf4c8996fb924"

        try await metadataStore.upsertItem(
            s3Key: s3Key,
            driveId: testDriveId,
            etag: expectedETag,
            syncStatus: .synced,
            size: 2048
        )

        let fetchedETag = try await metadataStore.fetchItemEtag(byKey: s3Key, driveId: testDriveId)
        XCTAssertEqual(fetchedETag, expectedETag, "ETag should persist after upsertItem")
    }

    // MARK: - Test 8: ConflictInfo encodes and decodes correctly

    func testConflictInfoEncodesAndDecodes() throws {
        let original = ConflictInfo(
            driveId: UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!,
            originalFilename: "report.pdf",
            conflictKey: "docs/report (Conflict on mac 2024-01-15 14-30-45).pdf"
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(ConflictInfo.self, from: data)

        XCTAssertEqual(decoded.driveId, original.driveId)
        XCTAssertEqual(decoded.originalFilename, original.originalFilename)
        XCTAssertEqual(decoded.conflictKey, original.conflictKey)
    }
}
