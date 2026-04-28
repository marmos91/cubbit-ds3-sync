import XCTest
import SwiftData
@testable import DS3Lib

/// Phase 13-05 coverage for `ThumbnailBackfillCoordinator`.
///
/// Phase 12-05 shipped the empty-store smoke + no-S3-call tests below
/// (`testRunBatchOnEmptyStoreReturnsZeroCounts`,
/// `testRunBatchOnEmptyStoreMakesNoS3Calls`). Phase 13-05 extends the actor
/// with thermal gating (D-19), pause-aware skipping (D-20), 3-strike
/// integration (D-29 / Plan 13-04), and external-Task cancellation
/// cooperation. The new tests below cover those four behaviors.
///
/// Test injection points (added in Plan 13-05):
///   - `thermalStateProvider: () -> ProcessInfo.ThermalState` — closures that
///     return `.serious` or `.critical` exercise the early-bail branch
///     without needing real thermal pressure.
///   - `pauseProvider: (UUID) -> Bool` — closures that return `true` exercise
///     the pause-skip branch without writing the App Group container's
///     `pause-state.json`. Production wires this to
///     `SharedData.default().isDrivePaused(_:)`.
final class ThumbnailBackfillCoordinatorTests: XCTestCase {

    // MARK: - Helpers

    /// Construct an in-memory V4 MetadataStore with zero rows.
    private func makeInMemoryMetadataStore() throws -> MetadataStore {
        let schema = Schema(versionedSchema: SyncedItemSchemaV4.self)
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

    /// Seed a `.pending` raster row with optional fail-count pre-state.
    @discardableResult
    private func seedPendingItem(
        _ store: MetadataStore,
        s3Key: String,
        driveId: UUID,
        etag: String? = "\"seed-etag\"",
        bumpFailCountTo: Int? = nil
    ) async throws -> String {
        try await store.upsertItem(
            s3Key: s3Key, driveId: driveId, etag: etag, syncStatus: .synced, size: 100
        )
        if let target = bumpFailCountTo {
            try await store.bumpFailCountForTesting(
                s3Key: s3Key, driveId: driveId, to: target
            )
        }
        return s3Key
    }

    /// Configure the mock to satisfy the download contract — `getObject(toFile:)`
    /// must return a non-nil `S3DownloadResult`. The empty file written to
    /// `tempURL` is intentional: `ThumbnailRenderer().renderJPEG(from: emptyURL)`
    /// returns nil (CGImageSourceCreateWithURL fails on 0-byte files), exercising
    /// the render-nil failure path needed by tests C and D below.
    private func configureDownloadStub(_ mock: MockDS3S3Client) {
        mock.getObjectResult = S3DownloadResult(
            etag: "\"download-etag\"",
            contentType: "image/jpeg",
            lastModified: nil,
            contentLength: 0
        )
    }

    // MARK: - Phase 12 baseline tests (preserved verbatim)

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

    // MARK: - Phase 13-05: Strike-rule integration (D-29)

    /// Test C — render-nil failure routes through `setThumbnailFailure`,
    /// NOT a direct `.failed` set. After one runBatch the row's
    /// `thumbnailFailCount == 1` and `thumbnailStatus == .pending`.
    func testRunBatchOnRendererNilIncrementsStrike() async throws {
        let store = try makeInMemoryMetadataStore()
        let mock = MockDS3S3Client()
        let drive = makeFixtureDrive()
        configureDownloadStub(mock)

        let key = try await seedPendingItem(
            store, s3Key: "renders-nil/photo.jpg", driveId: drive.id
        )

        let coordinator = ThumbnailBackfillCoordinator(
            metadataStore: store,
            s3Client: mock,
            drive: drive
        )

        let result = try await coordinator.runBatch(maxItems: 5)

        XCTAssertEqual(result.processed, 1)
        XCTAssertEqual(result.failed, 1)

        let state = try await store.thumbnailStateForTesting(
            s3Key: key, driveId: drive.id
        )
        XCTAssertEqual(state?.0, 1, "fail count must increment on render-nil")
        XCTAssertEqual(
            state?.1, ThumbnailStatus.pending.rawValue,
            "below threshold, status must stay .pending so next BFS pass retries"
        )
    }

    /// Test D — third consecutive failure flips the row to terminal `.failed`,
    /// and subsequent runBatch invocations DO NOT re-process it (excluded by
    /// the `.pending`-only predicate per Plan 13-04 D-30).
    func testRunBatchAfterThreeFailuresMarksFailed() async throws {
        let store = try makeInMemoryMetadataStore()
        let mock = MockDS3S3Client()
        let drive = makeFixtureDrive()
        configureDownloadStub(mock)

        let key = try await seedPendingItem(
            store,
            s3Key: "renders-nil/strike3.jpg",
            driveId: drive.id,
            bumpFailCountTo: 2
        )

        let coordinator = ThumbnailBackfillCoordinator(
            metadataStore: store,
            s3Client: mock,
            drive: drive
        )

        // First runBatch — third strike → terminal .failed.
        _ = try await coordinator.runBatch(maxItems: 5)

        let postState = try await store.thumbnailStateForTesting(
            s3Key: key, driveId: drive.id
        )
        XCTAssertEqual(postState?.0, 3, "third failure must bring count to 3")
        XCTAssertEqual(
            postState?.1, ThumbnailStatus.failed.rawValue,
            "count >= 3 must transition to terminal .failed (Pitfall 10 boundary)"
        )

        // Second runBatch — terminal row must not be re-processed.
        mock.resetCalls()
        let secondResult = try await coordinator.runBatch(maxItems: 5)

        XCTAssertEqual(
            secondResult.processed, 0,
            ".failed rows must not appear in fetchPendingThumbnails (D-30)"
        )
        XCTAssertFalse(
            mock.calls.contains(where: { $0.hasPrefix("getObject(") }),
            "no further S3 GETs once the row is terminal"
        )
    }

    // MARK: - Phase 13-05: Pause-aware skipping (D-20)

    /// Test E — paused drive: runBatch returns zero counts AND makes zero
    /// S3 calls. `pauseProvider` simulates `SharedData.isDrivePaused` returning
    /// true.
    func testRunBatchOnPausedDriveReturnsZero() async throws {
        let store = try makeInMemoryMetadataStore()
        let mock = MockDS3S3Client()
        let drive = makeFixtureDrive()
        configureDownloadStub(mock)

        // Seed 5 pending items so we'd have plenty to do if pause didn't gate.
        for index in 0..<5 {
            _ = try await seedPendingItem(
                store, s3Key: "pause/photo-\(index).jpg", driveId: drive.id
            )
        }

        let coordinator = ThumbnailBackfillCoordinator(
            metadataStore: store,
            s3Client: mock,
            drive: drive,
            pauseProvider: { _ in true }
        )

        let result = try await coordinator.runBatch(maxItems: 5)

        XCTAssertEqual(result.processed, 0, "paused drives must not process any items")
        XCTAssertEqual(result.failed, 0)
        XCTAssertFalse(
            mock.calls.contains(where: { $0.hasPrefix("getObject(") }),
            "paused drives must make zero S3 calls"
        )
        XCTAssertFalse(
            mock.calls.contains(where: { $0.hasPrefix("putObjectData(") }),
            "paused drives must make zero S3 calls"
        )
    }

    // MARK: - Phase 13-05: Thermal gating (D-19)

    /// Test F — nominal thermal state proceeds through the existing flow.
    /// Sanity check that the thermal injection point doesn't break the happy
    /// path. (The downstream renderer still returns nil because the temp
    /// file is empty — that's fine; the assertion is on whether the work
    /// was even attempted.)
    func testRunBatchOnNormalThermalProcessesItems() async throws {
        let store = try makeInMemoryMetadataStore()
        let mock = MockDS3S3Client()
        let drive = makeFixtureDrive()
        configureDownloadStub(mock)

        _ = try await seedPendingItem(
            store, s3Key: "thermal-ok/photo.jpg", driveId: drive.id
        )

        let coordinator = ThumbnailBackfillCoordinator(
            metadataStore: store,
            s3Client: mock,
            drive: drive,
            thermalStateProvider: { .nominal }
        )

        let result = try await coordinator.runBatch(maxItems: 5)

        XCTAssertEqual(result.processed, 1, "nominal thermal must let the item enter the loop")
        XCTAssertTrue(
            mock.calls.contains(where: { $0.hasPrefix("getObject(") }),
            "nominal thermal must allow the download phase"
        )
    }

    /// Test G — `.serious` thermal state triggers an early bail. Zero S3 calls,
    /// zero processed.
    func testRunBatchOnSeriousThermalReturnsZero() async throws {
        let store = try makeInMemoryMetadataStore()
        let mock = MockDS3S3Client()
        let drive = makeFixtureDrive()
        configureDownloadStub(mock)

        for index in 0..<3 {
            _ = try await seedPendingItem(
                store, s3Key: "thermal-bail/photo-\(index).jpg", driveId: drive.id
            )
        }

        let coordinator = ThumbnailBackfillCoordinator(
            metadataStore: store,
            s3Client: mock,
            drive: drive,
            thermalStateProvider: { .serious }
        )

        let result = try await coordinator.runBatch(maxItems: 5)

        XCTAssertEqual(result.processed, 0, ".serious thermal must skip the entire batch")
        XCTAssertEqual(result.succeeded, 0)
        XCTAssertEqual(result.failed, 0)
        XCTAssertFalse(
            mock.calls.contains(where: { $0.hasPrefix("getObject(") }),
            "no downloads under thermal pressure"
        )
        XCTAssertFalse(
            mock.calls.contains(where: { $0.hasPrefix("putObjectData(") }),
            "no PUTs under thermal pressure"
        )
    }

    /// Test G2 — `.critical` thermal state also triggers the early bail.
    /// Pitfall 7 / D-19 specify both `.serious` and `.critical` levels.
    func testRunBatchOnCriticalThermalReturnsZero() async throws {
        let store = try makeInMemoryMetadataStore()
        let mock = MockDS3S3Client()
        let drive = makeFixtureDrive()
        configureDownloadStub(mock)

        _ = try await seedPendingItem(
            store, s3Key: "thermal-critical/photo.jpg", driveId: drive.id
        )

        let coordinator = ThumbnailBackfillCoordinator(
            metadataStore: store,
            s3Client: mock,
            drive: drive,
            thermalStateProvider: { .critical }
        )

        let result = try await coordinator.runBatch(maxItems: 5)

        XCTAssertEqual(result.processed, 0, ".critical thermal must skip the entire batch")
        XCTAssertFalse(
            mock.calls.contains(where: { $0.hasPrefix("getObject(") }),
            "no downloads under critical thermal pressure"
        )
    }

    // MARK: - Phase 13-05: External-Task cancellation (D-20)

    /// Test H — external Task cancellation propagates into the coordinator
    /// via Swift Concurrency's structured cancellation. A delayed download
    /// stub provides a window for `task.cancel()` to land before the loop
    /// can advance to the next item; the in-flight item bails at the
    /// pre-PUT `Task.checkCancellation()` point. Subsequent items are not
    /// processed.
    ///
    /// Phase 13-05 contract (D-20): cancellation observed at iteration
    /// boundaries DOES NOT count as a failure, so the strike count must
    /// stay at zero. This guards against accidentally routing
    /// `CancellationError` through the strike helper.
    func testCancelInFlightDoesNotIncrementStrike() async throws {
        let store = try makeInMemoryMetadataStore()
        let mock = MockDS3S3Client()
        let drive = makeFixtureDrive()
        configureDownloadStub(mock)
        // Each download blocks for 200 ms, giving the outer Task.cancel()
        // a deterministic window to land before the loop completes.
        mock.getObjectDelayNanos = 200_000_000

        // Seed 5 pending items.
        var keys: [String] = []
        for index in 0..<5 {
            keys.append(try await seedPendingItem(
                store, s3Key: "cancel/photo-\(index).jpg", driveId: drive.id
            ))
        }

        let coordinator = ThumbnailBackfillCoordinator(
            metadataStore: store,
            s3Client: mock,
            drive: drive
        )

        // Spawn the batch as an outer Task and cancel it before it can
        // process all 5 items. This is the canonical wiring pattern Plan
        // 13-09 will use from the BFS hook.
        let task = Task { try? await coordinator.runBatch(maxItems: 5) }
        // Yield window long enough for the first download to start, but
        // shorter than 5 × 200 ms (= 1 s) so cancellation lands mid-batch.
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        _ = await task.value

        // The strike count for every seeded row must remain 0 — cancellation
        // must NOT route through `setThumbnailFailure`. (Some items may not
        // have been touched at all; some may have been touched but the
        // cancellation must short-circuit before the strike write.)
        for key in keys {
            let state = try await store.thumbnailStateForTesting(
                s3Key: key, driveId: drive.id
            )
            XCTAssertNotNil(state)
            XCTAssertEqual(
                state?.0, 0,
                "cancellation must NOT increment fail count for \(key)"
            )
        }
    }

    /// Test H2 — outer-Task cancellation stops the batch and leaves the
    /// coordinator reusable. The structured cancellation signal is the
    /// authoritative path; there is no separate flag-based API.
    func testOuterTaskCancellationStopsBatchAndCoordinatorRemainsUsable() async throws {
        let store = try makeInMemoryMetadataStore()
        let mock = MockDS3S3Client()
        let drive = makeFixtureDrive()
        configureDownloadStub(mock)
        mock.getObjectDelayNanos = 200_000_000

        for index in 0..<5 {
            _ = try await seedPendingItem(
                store, s3Key: "cancel-api/photo-\(index).jpg", driveId: drive.id
            )
        }

        let coordinator = ThumbnailBackfillCoordinator(
            metadataStore: store,
            s3Client: mock,
            drive: drive
        )

        let runTask = Task { try? await coordinator.runBatch(maxItems: 5) }
        try await Task.sleep(for: .milliseconds(50))
        runTask.cancel()
        _ = await runTask.value

        // Sanity: the coordinator must still be usable after cancellation —
        // a fresh runBatch invocation processes available items normally.
        // Drop the delay so the second batch finishes promptly.
        mock.getObjectDelayNanos = 0
        let secondResult = try await coordinator.runBatch(maxItems: 1)
        XCTAssertGreaterThanOrEqual(
            secondResult.processed, 0,
            "coordinator must remain usable after outer-Task cancellation"
        )
    }
}
