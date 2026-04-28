@testable import DS3Lib
import Foundation
import os
import SwiftData
import XCTest

/// Tests for `OrphanSweeper` (Phase 13 D-25, D-26, D-27, D-28; THUMB-19;
/// Phase 13.1 Finding 4 / D-01..D-05).
///
/// The sweeper lists `<drivePrefix>` recursively (Phase 11 places `.thumbnails/`
/// per-folder, NOT at the drive root), filters via `S3PathUtils.isThumbnailKey`,
/// then deletes any thumbnail whose implied original key is NOT in the BFS-
/// enumerated key set AND is NOT present as a `SyncedItem` row in the
/// MetadataStore (Phase 13.1 Finding 4 freshness backstop). Capped at
/// `DefaultSettings.Thumbnail.maxOrphanDeletesPerPass`.
///
/// Tests use a recording mock `DS3S3ClientProtocol` to assert exact list / delete
/// invocation counts plus an in-memory `MetadataStore` to seed (or not seed) the
/// freshness backstop. No real S3 traffic.
final class OrphanSweepTests: XCTestCase {
    private func makeLogger() -> os.Logger {
        os.Logger(subsystem: "io.cubbit.DS3Drive.tests", category: "orphan-sweep")
    }

    private func makeSummary(key: String) -> S3ObjectSummary {
        S3ObjectSummary(key: key, etag: "etag-\(key)", lastModified: Date(), size: 1024)
    }

    /// Build a fresh in-memory `MetadataStore` per test so the freshness
    /// backstop is always empty unless a test seeds it explicitly.
    /// Mirrors the construction pattern in `UploadHookTests` /
    /// `MetadataStoreThumbnailQueriesTests`.
    private func makeInMemoryMetadataStore() throws -> MetadataStore {
        let schema = Schema(versionedSchema: SyncedItemSchemaV4.self)
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        return MetadataStore(modelContainer: container)
    }

    // MARK: - Test 1 — Set-diff orphan detection

    /// Seed the bucket with three thumbnails (`a.jpg.jpg`, `b.jpg.jpg`,
    /// `orphan.jpg.jpg`); enumeratedKeys contains the originals for `a` and `b`
    /// only; sweep MUST issue exactly one deleteThumbnail call, for the orphan.
    func testSweepDeletesThumbnailsWhoseOriginalsNotInEnumeratedSet() async throws {
        let drive = ProviderTestFixtures.makeDrive()
        let prefix = drive.syncAnchor.prefix ?? ""
        let mock = OrphanSweepMockS3Client()

        // Per-folder placement of `.thumbnails/`, matching Phase 11 thumbnailKey().
        let aThumb = "\(prefix).thumbnails/a.jpg.jpg"
        let bThumb = "\(prefix).thumbnails/b.jpg.jpg"
        let orphanThumb = "\(prefix).thumbnails/orphan.jpg.jpg"
        mock.listObjectsResults = [.init(
            objects: [
                makeSummary(key: aThumb),
                makeSummary(key: bThumb),
                makeSummary(key: orphanThumb)
            ],
            commonPrefixes: [],
            nextContinuationToken: nil,
            isTruncated: false
        )]

        let enumerated: Set = [
            "\(prefix)a.jpg",
            "\(prefix)b.jpg"
        ]

        let metadataStore = try makeInMemoryMetadataStore()
        let sweeper = OrphanSweeper(
            s3Client: mock,
            metadataStore: metadataStore,
            driveId: drive.id,
            logger: makeLogger()
        )
        let deleted = await sweeper.sweep(
            bucket: drive.syncAnchor.bucket.name,
            drivePrefix: drive.syncAnchor.prefix,
            enumeratedKeys: enumerated
        )

        XCTAssertEqual(deleted, 1)
        XCTAssertEqual(mock.deletedKeys, [orphanThumb])
    }

    // MARK: - Test 2 — 50-cap per pass

    /// Seed 100 orphans; sweeper deletes EXACTLY 50; remaining 50 left for
    /// the next pass. Exercises `DefaultSettings.Thumbnail.maxOrphanDeletesPerPass`.
    func testSweepRespectsMaxDeletesPerPassCap() async throws {
        let drive = ProviderTestFixtures.makeDrive()
        let prefix = drive.syncAnchor.prefix ?? ""
        let mock = OrphanSweepMockS3Client()

        let orphans = (0 ..< 100).map { idx in
            "\(prefix).thumbnails/orphan\(idx).jpg.jpg"
        }
        mock.listObjectsResults = [.init(
            objects: orphans.map { makeSummary(key: $0) },
            commonPrefixes: [],
            nextContinuationToken: nil,
            isTruncated: false
        )]

        // No originals exist — every thumbnail is an orphan.
        let enumerated: Set<String> = []

        // Empty MetadataStore — freshness backstop returns false for every
        // candidate, so the cap is the only thing limiting the sweep.
        let metadataStore = try makeInMemoryMetadataStore()
        let sweeper = OrphanSweeper(
            s3Client: mock,
            metadataStore: metadataStore,
            driveId: drive.id,
            logger: makeLogger()
        )
        let deleted = await sweeper.sweep(
            bucket: drive.syncAnchor.bucket.name,
            drivePrefix: drive.syncAnchor.prefix,
            enumeratedKeys: enumerated
        )

        XCTAssertEqual(deleted, DefaultSettings.Thumbnail.maxOrphanDeletesPerPass)
        XCTAssertEqual(deleted, 50, "Plan 13-01 fixed cap (sanity check)")
        XCTAssertEqual(mock.deletedKeys.count, 50)
    }

    // MARK: - Test 3 — No-op when every thumbnail has an original

    func testSweepNoOpWhenAllThumbnailsHaveOriginals() async throws {
        let drive = ProviderTestFixtures.makeDrive()
        let prefix = drive.syncAnchor.prefix ?? ""
        let mock = OrphanSweepMockS3Client()

        let aThumb = "\(prefix).thumbnails/a.jpg.jpg"
        let bThumb = "\(prefix).thumbnails/b.jpg.jpg"
        mock.listObjectsResults = [.init(
            objects: [makeSummary(key: aThumb), makeSummary(key: bThumb)],
            commonPrefixes: [],
            nextContinuationToken: nil,
            isTruncated: false
        )]

        let enumerated: Set = [
            "\(prefix)a.jpg",
            "\(prefix)b.jpg"
        ]

        let metadataStore = try makeInMemoryMetadataStore()
        let sweeper = OrphanSweeper(
            s3Client: mock,
            metadataStore: metadataStore,
            driveId: drive.id,
            logger: makeLogger()
        )
        let deleted = await sweeper.sweep(
            bucket: drive.syncAnchor.bucket.name,
            drivePrefix: drive.syncAnchor.prefix,
            enumeratedKeys: enumerated
        )

        XCTAssertEqual(deleted, 0)
        XCTAssertEqual(mock.deletedKeys, [])
    }

    // MARK: - Test 4 — Empty thumbnail listing is no-op

    func testSweepEmptyThumbnailPrefixIsNoOp() async throws {
        let drive = ProviderTestFixtures.makeDrive()
        let mock = OrphanSweepMockS3Client()
        mock.listObjectsResults = [.init(
            objects: [],
            commonPrefixes: [],
            nextContinuationToken: nil,
            isTruncated: false
        )]

        let metadataStore = try makeInMemoryMetadataStore()
        let sweeper = OrphanSweeper(
            s3Client: mock,
            metadataStore: metadataStore,
            driveId: drive.id,
            logger: makeLogger()
        )
        let deleted = await sweeper.sweep(
            bucket: drive.syncAnchor.bucket.name,
            drivePrefix: drive.syncAnchor.prefix,
            enumeratedKeys: []
        )

        XCTAssertEqual(deleted, 0)
        XCTAssertEqual(mock.deletedKeys, [])
    }

    // MARK: - Test 5 — Non-thumbnail keys returned by listing are skipped

    /// The sweeper does a recursive listing of the drive prefix and filters
    /// thumbnail keys via `S3PathUtils.isThumbnailKey`. Non-thumbnail keys
    /// (e.g. ordinary originals) are skipped — they MUST NOT be deleted.
    func testSweepHandlesUnparseableThumbnailKeyGracefully() async throws {
        let drive = ProviderTestFixtures.makeDrive()
        let prefix = drive.syncAnchor.prefix ?? ""
        let mock = OrphanSweepMockS3Client()

        // Mix of thumbnail keys and a non-thumbnail key. The non-thumbnail
        // key must NEVER be deleted regardless of enumeratedKeys content.
        let nonThumbKey = "\(prefix)photos/some-original.jpg"
        let orphanThumb = "\(prefix).thumbnails/orphan.jpg.jpg"
        mock.listObjectsResults = [.init(
            objects: [
                makeSummary(key: nonThumbKey),
                makeSummary(key: orphanThumb)
            ],
            commonPrefixes: [],
            nextContinuationToken: nil,
            isTruncated: false
        )]

        // enumeratedKeys empty — orphanThumb's original is missing → delete it.
        // nonThumbKey is NOT a thumb key → never considered for deletion even
        // though it's also "missing from enumerated".
        let metadataStore = try makeInMemoryMetadataStore()
        let sweeper = OrphanSweeper(
            s3Client: mock,
            metadataStore: metadataStore,
            driveId: drive.id,
            logger: makeLogger()
        )
        let deleted = await sweeper.sweep(
            bucket: drive.syncAnchor.bucket.name,
            drivePrefix: drive.syncAnchor.prefix,
            enumeratedKeys: []
        )

        XCTAssertEqual(deleted, 1)
        XCTAssertEqual(mock.deletedKeys, [orphanThumb])
        XCTAssertFalse(
            mock.deletedKeys.contains(nonThumbKey),
            "Non-thumbnail keys must never be deleted by the sweeper"
        )
    }

    // MARK: - Test 6 — Folder marker keys are never deleted

    /// Even if a folder marker (`...thumbnails/subfolder/`) appears in the
    /// listing, the sweeper MUST skip it (folder deletion would delete real
    /// content; thumbnails are leaves only).
    func testSweepDoesNotInvokeDeleteOnFolderKeys() async throws {
        let drive = ProviderTestFixtures.makeDrive()
        let prefix = drive.syncAnchor.prefix ?? ""
        let mock = OrphanSweepMockS3Client()

        let folderMarker = "\(prefix).thumbnails/subfolder/"
        mock.listObjectsResults = [.init(
            objects: [makeSummary(key: folderMarker)],
            commonPrefixes: [],
            nextContinuationToken: nil,
            isTruncated: false
        )]

        let metadataStore = try makeInMemoryMetadataStore()
        let sweeper = OrphanSweeper(
            s3Client: mock,
            metadataStore: metadataStore,
            driveId: drive.id,
            logger: makeLogger()
        )
        let deleted = await sweeper.sweep(
            bucket: drive.syncAnchor.bucket.name,
            drivePrefix: drive.syncAnchor.prefix,
            enumeratedKeys: []
        )

        XCTAssertEqual(deleted, 0)
        XCTAssertEqual(mock.deletedKeys, [])
    }

    // MARK: - Test 6b — Pagination reaches orphans beyond the first 1000 keys

    /// Listings of large drives are truncated. The sweeper MUST follow
    /// `nextContinuationToken` until either the listing is no longer truncated
    /// or it has gathered enough thumbnail keys to fill its delete budget.
    /// Without pagination, orphans in later-sorting prefixes would never be
    /// reclaimed.
    func testSweepPaginatesUntilOrphanBudgetMet() async throws {
        let drive = ProviderTestFixtures.makeDrive()
        let prefix = drive.syncAnchor.prefix ?? ""
        let mock = OrphanSweepMockS3Client()

        // Page 1: 1000 originals (no thumbnails) — single recursive list of
        // the drive prefix returns originals first; sweeper must continue.
        let page1Originals = (0 ..< 1000).map { idx in
            "\(prefix)docs/file-\(idx).txt"
        }
        // Page 2: a single orphan thumbnail in a deep subfolder.
        let orphanThumb = "\(prefix)photos/.thumbnails/deep-orphan.jpg.jpg"
        mock.listObjectsResults = [
            .init(
                objects: page1Originals.map { makeSummary(key: $0) },
                commonPrefixes: [],
                nextContinuationToken: "page-2-token",
                isTruncated: true
            ),
            .init(
                objects: [makeSummary(key: orphanThumb)],
                commonPrefixes: [],
                nextContinuationToken: nil,
                isTruncated: false
            )
        ]

        let metadataStore = try makeInMemoryMetadataStore()
        let sweeper = OrphanSweeper(
            s3Client: mock,
            metadataStore: metadataStore,
            driveId: drive.id,
            logger: makeLogger()
        )
        let deleted = await sweeper.sweep(
            bucket: drive.syncAnchor.bucket.name,
            drivePrefix: drive.syncAnchor.prefix,
            enumeratedKeys: []
        )

        XCTAssertEqual(
            deleted, 1,
            "Pagination must continue past the first page to reach deep orphans"
        )
        XCTAssertEqual(mock.deletedKeys, [orphanThumb])
        XCTAssertGreaterThanOrEqual(
            mock.listInvocations, 2,
            "Sweeper must issue at least two listObjects calls when isTruncated"
        )
    }

    // MARK: - Test 7 — Listing failure is graceful

    /// If listObjects throws, the sweeper logs and returns 0; no deletes
    /// issued. Ensures a transient S3 outage doesn't crash the BFS pass tail.
    func testSweepHandlesListFailureGracefully() async throws {
        let drive = ProviderTestFixtures.makeDrive()
        let mock = OrphanSweepMockS3Client()
        mock.listObjectsError = NSError(domain: "TestDomain", code: 99, userInfo: nil)

        let metadataStore = try makeInMemoryMetadataStore()
        let sweeper = OrphanSweeper(
            s3Client: mock,
            metadataStore: metadataStore,
            driveId: drive.id,
            logger: makeLogger()
        )
        let deleted = await sweeper.sweep(
            bucket: drive.syncAnchor.bucket.name,
            drivePrefix: drive.syncAnchor.prefix,
            enumeratedKeys: []
        )

        XCTAssertEqual(deleted, 0)
        XCTAssertEqual(mock.deletedKeys, [])
    }

    // MARK: - Test 8 — Phase 13.1 Finding 4 regression lock (D-04)

    /// Regression lock for Phase 13.1 Finding 4 (`.planning/debug/phase13-orphan-
    /// sweep-deletes-valid.md`).
    ///
    /// Reproduction: BFS visits prefix P at time T1; user uploads file F into P
    /// at time T2 > T1; pass-tail sweep runs at time T3. `enumeratedKeys` does
    /// NOT contain F (it was built before T2). Without the freshness backstop
    /// the sweep would delete F's thumbnail as a false-positive orphan.
    ///
    /// Plan 13-07's upload-hook writes a `SyncedItem` row synchronously
    /// alongside the original PUT. The Phase 13.1 fix consults that row as the
    /// freshness backstop. This test seeds such a row for an original whose
    /// key is NOT in `enumeratedKeys` and asserts the sweep does NOT delete
    /// the corresponding thumbnail.
    func testSweepDoesNotDeleteThumbnailWhenSyncedItemExistsForOriginal() async throws {
        let drive = ProviderTestFixtures.makeDrive()
        let prefix = drive.syncAnchor.prefix ?? ""
        let mock = OrphanSweepMockS3Client()

        let freshOriginal = "\(prefix)fresh.png"
        let freshThumb = "\(prefix).thumbnails/fresh.png.jpg"
        mock.listObjectsResults = [.init(
            objects: [makeSummary(key: freshThumb)],
            commonPrefixes: [],
            nextContinuationToken: nil,
            isTruncated: false
        )]

        // Seed MetadataStore as if upload-hook wrote the SyncedItem
        // synchronously alongside the original PUT (Plan 13-07 contract).
        let metadataStore = try makeInMemoryMetadataStore()
        try await metadataStore.batchUpsertItems([
            .init(
                s3Key: freshOriginal,
                driveId: drive.id,
                etag: "etag-fresh",
                lastModified: Date(),
                syncStatus: .synced,
                parentKey: nil,
                contentType: "image/png",
                size: 1024
            )
        ])

        let sweeper = OrphanSweeper(
            s3Client: mock,
            metadataStore: metadataStore,
            driveId: drive.id,
            logger: makeLogger()
        )

        // enumeratedKeys is EMPTY — simulates BFS having visited the parent
        // prefix BEFORE freshOriginal was uploaded. Without the backstop, the
        // sweep would delete freshThumb (Finding 4 symptom).
        let deleted = await sweeper.sweep(
            bucket: drive.syncAnchor.bucket.name,
            drivePrefix: drive.syncAnchor.prefix,
            enumeratedKeys: []
        )

        XCTAssertEqual(
            deleted, 0,
            "Fresh thumbnail with SyncedItem must NOT be deleted by orphan sweep"
        )
        XCTAssertEqual(
            mock.deletedKeys, [],
            "MetadataStore freshness backstop must prevent the false-positive delete"
        )
    }
}

// MARK: - Mock S3 client for OrphanSweep tests

/// Records `listObjects` and `deleteObject` invocations. `deleteObject` is the
/// underlying primitive `deleteThumbnail` calls (the protocol extension wraps
/// the call and swallows 404; here we want to observe every attempt).
final class OrphanSweepMockS3Client: DS3S3ClientProtocol, @unchecked Sendable {
    private struct State {
        var listInvocations: Int = 0
        var deletedKeys: [String] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var listInvocations: Int {
        state.withLock { $0.listInvocations }
    }
    var deletedKeys: [String] {
        state.withLock { $0.deletedKeys }
    }

    /// Queue of listing results to return on successive listObjects calls.
    /// Last result repeats if exhausted.
    var listObjectsResults: [S3ListingResult] = []
    var listObjectsError: Error?
    var deleteObjectError: Error?

    func listBuckets() async throws -> [(name: String, creationDate: Date?)] {
        []
    }

    func listObjects(
        bucket _: String, prefix _: String?, delimiter _: String?,
        maxKeys _: Int?, continuationToken _: String?
    ) async throws -> S3ListingResult {
        if let err = listObjectsError { throw err }
        return state.withLock { state in
            state.listInvocations += 1
            let idx = min(state.listInvocations - 1, listObjectsResults.count - 1)
            guard idx >= 0, !listObjectsResults.isEmpty else {
                return S3ListingResult(
                    objects: [], commonPrefixes: [],
                    nextContinuationToken: nil, isTruncated: false
                )
            }
            return listObjectsResults[idx]
        }
    }

    func headObject(bucket _: String, key _: String) async throws -> S3ObjectMetadata {
        throw DS3ClientError.parseError
    }

    func deleteObject(bucket _: String, key: String) async throws {
        state.withLock { state in
            state.deletedKeys.append(key)
        }
        if let err = deleteObjectError { throw err }
    }

    func deleteObjects(bucket _: String, keys _: [String]) async throws -> Int {
        0
    }

    func copyObject(
        bucket _: String, sourceKey _: String,
        destinationKey _: String, metadata _: [String: String]?
    ) async throws {
        // No-op stub — sweep tests don't observe copy.
    }

    func getObject(
        bucket _: String, key _: String,
        toFile _: URL, onProgress _: TransferProgressHandler?
    ) async throws -> S3DownloadResult {
        throw DS3ClientError.parseError
    }

    func getObjectData(bucket _: String, key _: String) async throws -> Data {
        Data()
    }

    func putObject(
        bucket _: String, key _: String,
        fileURL _: URL?, onProgress _: TransferProgressHandler?
    ) async throws -> String? {
        "mock-etag"
    }

    func putObjectData(
        bucket _: String, key _: String,
        data _: Data, metadata _: [String: String]?
    ) async throws -> String? {
        "mock-etag"
    }

    func createMultipartUpload(bucket _: String, key _: String) async throws -> String {
        "mock-upload-id"
    }

    func uploadPart(
        bucket _: String, key _: String, uploadId _: String,
        partNumber: Int, data _: Data
    ) async throws -> CompletedPartResult {
        CompletedPartResult(partNumber: partNumber, etag: "etag-part-\(partNumber)")
    }

    func completeMultipartUpload(
        bucket _: String, key _: String, uploadId _: String,
        parts _: [(partNumber: Int, etag: String)]
    ) async throws -> MultipartCompleteResult {
        MultipartCompleteResult(etag: "mock-final-etag")
    }

    func abortMultipartUpload(bucket _: String, key _: String, uploadId _: String) async throws {
        // No-op stub — sweep tests don't observe multipart.
    }

    func shutdown() throws {
        // No-op stub — mock has no resources to release.
    }
}
