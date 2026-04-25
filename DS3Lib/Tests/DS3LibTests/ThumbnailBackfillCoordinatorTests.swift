import XCTest
import SwiftData
@testable import DS3Lib

/// Phase 12-05 scaffold smoke test for `ThumbnailBackfillCoordinator`.
///
/// Per D-39 and CONTEXT — Phase 12 ships only the empty-store path. End-to-end
/// flow tests (fetch → download → render → put) belong to Phase 13 when real
/// callers wire the coordinator up.
final class ThumbnailBackfillCoordinatorTests: XCTestCase {

    // MARK: - Helpers

    /// Construct an in-memory V3 MetadataStore with zero rows.
    private func makeInMemoryMetadataStore() throws -> MetadataStore {
        let schema = Schema(versionedSchema: SyncedItemSchemaV3.self)
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        return MetadataStore(modelContainer: container)
    }

    /// Synthetic drive fixture sufficient for the empty-store path. The
    /// coordinator only reads `drive.id`, `drive.syncAnchor.bucket.name`, and
    /// `drive.syncAnchor.prefix`, so the project / IAM user values are
    /// minimal placeholders.
    private func makeFixtureDrive() -> DS3Drive {
        let project = Project(
            id: "test-project",
            name: "Test",
            description: "fixture",
            email: "test@example.com",
            createdAt: "2026-04-25",
            tenantId: "test-tenant",
            users: []
        )
        let iamUser = IAMUser(id: "test-user", username: "test", isRoot: false)
        let bucket = Bucket(name: "test-bucket")
        let anchor = SyncAnchor(
            project: project, IAMUser: iamUser, bucket: bucket, prefix: "drive/"
        )
        return DS3Drive(id: UUID(), name: "Test Drive", syncAnchor: anchor)
    }

    // MARK: - Tests

    /// Empty MetadataStore + maxItems: 1 → BatchResult zero counts, no S3 calls.
    func testRunBatchOnEmptyStoreReturnsZeroCounts() async throws {
        let store = try makeInMemoryMetadataStore()
        let mock = MockDS3S3Client()
        let drive = makeFixtureDrive()

        let coordinator = ThumbnailBackfillCoordinator(
            metadataStore: store,
            s3Client: mock,
            drive: drive
        )

        let result: ThumbnailBackfillCoordinator.BatchResult =
            try await coordinator.runBatch(maxItems: 1)

        XCTAssertEqual(result.processed, 0)
        XCTAssertEqual(result.succeeded, 0)
        XCTAssertEqual(result.skipped, 0)
        XCTAssertEqual(result.failed, 0)
    }

    /// On the empty path, the coordinator must short-circuit before touching
    /// S3 — proves we don't speculatively download or PUT.
    func testRunBatchOnEmptyStoreMakesNoS3Calls() async throws {
        let store = try makeInMemoryMetadataStore()
        let mock = MockDS3S3Client()
        let drive = makeFixtureDrive()

        let coordinator = ThumbnailBackfillCoordinator(
            metadataStore: store,
            s3Client: mock,
            drive: drive
        )

        _ = try await coordinator.runBatch(maxItems: 1)

        XCTAssertFalse(
            mock.calls.contains(where: { $0.hasPrefix("getObject(") }),
            "Coordinator must not download any originals when no pending rows exist"
        )
        XCTAssertFalse(
            mock.calls.contains(where: { $0.hasPrefix("putObjectData(") }),
            "Coordinator must not upload any thumbnails when no pending rows exist"
        )
    }
}
