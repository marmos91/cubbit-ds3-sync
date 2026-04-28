@testable import DS3Lib
import Foundation
import os
import XCTest

/// Tests for `OrphanSweeper` (Phase 13 D-25, D-26, D-27, D-28; THUMB-19).
///
/// The sweeper lists `<drivePrefix>` recursively (Phase 11 places `.thumbnails/`
/// per-folder, NOT at the drive root), filters via `S3PathUtils.isThumbnailKey`,
/// then deletes any thumbnail whose implied original key is NOT in the BFS-
/// enumerated key set. Capped at `DefaultSettings.Thumbnail.maxOrphanDeletesPerPass`.
///
/// Tests use a recording mock `DS3S3ClientProtocol` to assert exact list / delete
/// invocation counts. No real S3 traffic.
final class OrphanSweepTests: XCTestCase {
    private func makeLogger() -> os.Logger {
        os.Logger(subsystem: "io.cubbit.DS3Drive.tests", category: "orphan-sweep")
    }

    private func makeSummary(key: String) -> S3ObjectSummary {
        S3ObjectSummary(key: key, etag: "etag-\(key)", lastModified: Date(), size: 1024)
    }

    // MARK: - Test 1 — Set-diff orphan detection

    /// Seed the bucket with three thumbnails (`a.jpg.jpg`, `b.jpg.jpg`,
    /// `orphan.jpg.jpg`); enumeratedKeys contains the originals for `a` and `b`
    /// only; sweep MUST issue exactly one deleteThumbnail call, for the orphan.
    func testSweepDeletesThumbnailsWhoseOriginalsNotInEnumeratedSet() async {
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

        let sweeper = OrphanSweeper(s3Client: mock, logger: makeLogger())
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
    func testSweepRespectsMaxDeletesPerPassCap() async {
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

        let sweeper = OrphanSweeper(s3Client: mock, logger: makeLogger())
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

    func testSweepNoOpWhenAllThumbnailsHaveOriginals() async {
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

        let sweeper = OrphanSweeper(s3Client: mock, logger: makeLogger())
        let deleted = await sweeper.sweep(
            bucket: drive.syncAnchor.bucket.name,
            drivePrefix: drive.syncAnchor.prefix,
            enumeratedKeys: enumerated
        )

        XCTAssertEqual(deleted, 0)
        XCTAssertEqual(mock.deletedKeys, [])
    }

    // MARK: - Test 4 — Empty thumbnail listing is no-op

    func testSweepEmptyThumbnailPrefixIsNoOp() async {
        let drive = ProviderTestFixtures.makeDrive()
        let mock = OrphanSweepMockS3Client()
        mock.listObjectsResults = [.init(
            objects: [],
            commonPrefixes: [],
            nextContinuationToken: nil,
            isTruncated: false
        )]

        let sweeper = OrphanSweeper(s3Client: mock, logger: makeLogger())
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
    func testSweepHandlesUnparseableThumbnailKeyGracefully() async {
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
        let sweeper = OrphanSweeper(s3Client: mock, logger: makeLogger())
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
    func testSweepDoesNotInvokeDeleteOnFolderKeys() async {
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

        let sweeper = OrphanSweeper(s3Client: mock, logger: makeLogger())
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
    func testSweepPaginatesUntilOrphanBudgetMet() async {
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

        let sweeper = OrphanSweeper(s3Client: mock, logger: makeLogger())
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
    func testSweepHandlesListFailureGracefully() async {
        let drive = ProviderTestFixtures.makeDrive()
        let mock = OrphanSweepMockS3Client()
        mock.listObjectsError = NSError(domain: "TestDomain", code: 99, userInfo: nil)

        let sweeper = OrphanSweeper(s3Client: mock, logger: makeLogger())
        let deleted = await sweeper.sweep(
            bucket: drive.syncAnchor.bucket.name,
            drivePrefix: drive.syncAnchor.prefix,
            enumeratedKeys: []
        )

        XCTAssertEqual(deleted, 0)
        XCTAssertEqual(mock.deletedKeys, [])
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
