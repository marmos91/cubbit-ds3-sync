import XCTest
import SwiftData
@testable import DS3Lib

/// Tests that MetadataStore.purgeRowsContainingSentinels removes rows whose
/// `s3Key` contains, or whose `parentKey` equals, an Apple sentinel raw value
/// (residue from a pre-fix bug where `parentItemIdentifier.rawValue` was
/// concatenated into S3 keys).
final class MetadataStorePurgeTests: XCTestCase {
    private var container: ModelContainer!
    private var store: MetadataStore!
    private let driveId = UUID()
    private let otherDriveId = UUID()

    // Apple sentinel raw values, hard-coded here to avoid importing FileProvider
    // into DS3Lib. These are stable platform constants.
    private let trashSentinel = "NSFileProviderTrashContainerItemIdentifier"
    private let workingSetSentinel = "NSFileProviderWorkingSetContainerItemIdentifier"
    private let rootSentinel = "NSFileProviderRootContainerItemIdentifier"

    override func setUp() async throws {
        let schema = Schema(versionedSchema: SyncedItemSchemaV2.self)
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, configurations: [config])
        store = MetadataStore(modelContainer: container)
    }

    func testPurgeRemovesRowWhoseKeyContainsTrashSentinel() async throws {
        let mangled = trashSentinel + "IMG_4172.MOV"
        try await store.upsertItem(s3Key: mangled, driveId: driveId, syncStatus: .synced)

        let purged = try await store.purgeRowsContainingSentinels(
            driveId: driveId, sentinels: [trashSentinel, workingSetSentinel, rootSentinel]
        )

        XCTAssertEqual(purged, 1)
        let status = try await store.fetchItemSyncStatus(byKey: mangled, driveId: driveId)
        XCTAssertNil(status, "Mangled row should be deleted")
    }

    func testPurgeRemovesRowWhoseParentKeyEqualsSentinel() async throws {
        try await store.upsertItem(
            s3Key: "legitimate-file.txt", driveId: driveId,
            syncStatus: .synced, parentKey: trashSentinel
        )

        let purged = try await store.purgeRowsContainingSentinels(
            driveId: driveId, sentinels: [trashSentinel, workingSetSentinel, rootSentinel]
        )

        XCTAssertEqual(purged, 1)
        let status = try await store.fetchItemSyncStatus(byKey: "legitimate-file.txt", driveId: driveId)
        XCTAssertNil(status, "Row whose parentKey equals a sentinel should be deleted")
    }

    func testPurgePreservesLegitimateRows() async throws {
        try await store.upsertItem(s3Key: "Personal/photo.jpg", driveId: driveId, syncStatus: .synced)
        try await store.upsertItem(s3Key: "Cubbit/", driveId: driveId, syncStatus: .synced)
        try await store.upsertItem(
            s3Key: "Cubbit/notes.txt", driveId: driveId,
            syncStatus: .synced, parentKey: "Cubbit/"
        )

        let purged = try await store.purgeRowsContainingSentinels(
            driveId: driveId, sentinels: [trashSentinel, workingSetSentinel, rootSentinel]
        )

        XCTAssertEqual(purged, 0)
        let count = try await store.countItemsByDrive(driveId: driveId)
        XCTAssertEqual(count, 3, "All legitimate rows should remain")
    }

    func testPurgeIsScopedToDrive() async throws {
        let mangled = trashSentinel + "IMG_other.MOV"
        try await store.upsertItem(s3Key: mangled, driveId: otherDriveId, syncStatus: .synced)
        try await store.upsertItem(s3Key: trashSentinel + "IMG_self.MOV", driveId: driveId, syncStatus: .synced)

        let purged = try await store.purgeRowsContainingSentinels(
            driveId: driveId, sentinels: [trashSentinel]
        )

        XCTAssertEqual(purged, 1, "Only rows for the targeted drive should be deleted")
        let otherStatus = try await store.fetchItemSyncStatus(byKey: mangled, driveId: otherDriveId)
        XCTAssertNotNil(otherStatus, "Rows for other drives must be untouched")
    }

    func testPurgeWithEmptySentinelListIsNoop() async throws {
        try await store.upsertItem(s3Key: "Personal/photo.jpg", driveId: driveId, syncStatus: .synced)

        let purged = try await store.purgeRowsContainingSentinels(driveId: driveId, sentinels: [])

        XCTAssertEqual(purged, 0)
        let status = try await store.fetchItemSyncStatus(byKey: "Personal/photo.jpg", driveId: driveId)
        XCTAssertNotNil(status)
    }

    func testPurgeRemovesMultipleMangledRows() async throws {
        for n in [4172, 4176, 4186, 4224] {
            let mangled = trashSentinel + "IMG_\(n).MOV"
            try await store.upsertItem(s3Key: mangled, driveId: driveId, syncStatus: .synced)
        }

        let purged = try await store.purgeRowsContainingSentinels(
            driveId: driveId, sentinels: [trashSentinel]
        )

        XCTAssertEqual(purged, 4, "Should delete all four mangled rows from the live repro")
        let count = try await store.countItemsByDrive(driveId: driveId)
        XCTAssertEqual(count, 0)
    }

    func testPurgeDoesNotMatchSimilarLegitimateKey() async throws {
        // A user could legitimately name a folder "NSFileProviderTrashFooBar".
        // Only exact substring matches of the full sentinel string should trigger.
        try await store.upsertItem(s3Key: "NSFileProviderTrashFooBar/file.txt", driveId: driveId, syncStatus: .synced)

        let purged = try await store.purgeRowsContainingSentinels(
            driveId: driveId, sentinels: [trashSentinel]
        )

        XCTAssertEqual(purged, 0)
    }
}
