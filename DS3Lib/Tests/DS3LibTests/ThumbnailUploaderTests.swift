import Foundation
import SwiftData
import XCTest

@testable import DS3Lib

/// Tests for `ThumbnailUploader` — the Phase 13 / Plan 13-02 render+PUT pipeline
/// invoked by the upload-hook in `createItem`/`modifyItem` (Plan 13-07 wiring).
///
/// Coverage matches Plan 13-02 `<behavior>`:
///   1. Raster fixture round-trip — render success + single PUT + `.uploaded`.
///   2. Non-raster originalKey — defensive guard, no PUT, `.notApplicable`.
///   3. Renderer returns nil (rejected fixture) — no PUT, `.failed`.
///   4. PUT throws — `.failed` AND rethrow to caller.
///   5. PUT key matches `S3PathUtils.thumbnailKey(...)` (canonical key, no ad-hoc concat).
///
/// Per D-09 the `generateAndUpload` function is `#if os(macOS)`-gated, so the whole
/// test class is gated too. iOS test runs (DS3LibTests platform=iOS) compile this
/// file as an empty translation unit.
#if os(macOS)
    final class ThumbnailUploaderTests: XCTestCase {
        // MARK: - Fixtures

        private var container: ModelContainer!
        private var metadataStore: MetadataStore!
        private var mockS3: MockDS3S3Client!
        private var uploader: ThumbnailUploader!

        private let driveId = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        private let drivePrefix: String? = nil // root-level drive — keeps thumbnailKey arithmetic simple

        override func setUp() async throws {
            // In-memory MetadataStore (V4 schema — Plan 13-04 bumped from V3).
            // The `SyncedItem` typealias now resolves to `SyncedItemSchemaV4.SyncedItem`,
            // so the container must be bound to V4 to avoid the SwiftData
            // "Failed to cast model" trap (Pitfall 3).
            let schema = Schema(versionedSchema: SyncedItemSchemaV4.self)
            let config = ModelConfiguration(isStoredInMemoryOnly: true)
            container = try ModelContainer(for: schema, configurations: [config])
            metadataStore = MetadataStore(modelContainer: container)

            mockS3 = MockDS3S3Client()
            mockS3.putObjectDataEtag = "\"thumb-etag\""

            uploader = ThumbnailUploader(s3Client: mockS3, metadataStore: metadataStore)
        }

        override func tearDown() async throws {
            uploader = nil
            mockS3 = nil
            metadataStore = nil
            container = nil
        }

        // MARK: - Helpers

        private func fixtureURL(name: String, ext: String) throws -> URL {
            try XCTUnwrap(
                Bundle.module.url(forResource: name, withExtension: ext),
                "fixture \(name).\(ext) missing — check DS3LibTests resources(.process(\"Fixtures\"))"
            )
        }

        private func makeDrive() -> DS3Drive {
            // Build a SyncAnchor with the test driveId → root prefix → "test-bucket".
            let bucket = Bucket(name: "test-bucket")
            let project = Project(
                id: "proj-id",
                name: "Test",
                description: "Test project",
                email: "test@cubbit.io",
                createdAt: "2026-01-01T00:00:00.000000Z",
                tenantId: "tenant-id",
                users: []
            )
            let user = IAMUser(id: "user-id", username: "test", isRoot: true)
            let anchor = SyncAnchor(
                project: project,
                IAMUser: user,
                bucket: bucket,
                prefix: drivePrefix
            )
            return DS3Drive(id: driveId, name: "Test Drive", syncAnchor: anchor)
        }

        /// Seeds a SyncedItem at `s3Key` with default `.pending` thumbnail status.
        private func seedItem(s3Key: String) async throws {
            try await metadataStore.upsertItem(
                s3Key: s3Key,
                driveId: driveId,
                etag: "\"original-etag\"",
                syncStatus: .synced,
                contentType: "image/jpeg",
                size: 1024
            )
        }

        /// Reads the persisted thumbnailStatus raw value for a key.
        private func currentStatus(forKey s3Key: String) async throws -> String? {
            try await metadataStore.fetchItemSyncStatusForThumbnails(
                s3Key: s3Key, driveId: driveId
            )
        }

        // MARK: - Test 1: render success + PUT + .uploaded

        func testGenerateAndUploadOnRasterFixtureRendersAndPuts() async throws {
            let url = try fixtureURL(name: "exif6-portrait", ext: "jpg")
            let drive = makeDrive()
            let originalKey = "photos/exif6-portrait.jpg"
            try await seedItem(s3Key: originalKey)

            try await uploader.generateAndUpload(
                localURL: url,
                drive: drive,
                sourceETag: "\"original-etag\"",
                originalKey: originalKey
            )

            // One PUT call landed on the S3 client with non-empty data and the
            // sourceETag carried in metadata.
            let putCount = mockS3.calls.filter { $0.hasPrefix("putObjectData(") }.count
            XCTAssertEqual(putCount, 1, "expected exactly one PUT for a raster fixture")
            XCTAssertEqual(mockS3.lastPutObjectDataBucket, "test-bucket")
            XCTAssertNotNil(mockS3.lastPutObjectDataBytes)
            XCTAssertGreaterThan(mockS3.lastPutObjectDataBytes ?? 0, 0)
            XCTAssertEqual(
                mockS3.lastPutObjectDataMetadata?[
                    DefaultSettings.Thumbnail.sourceETagMetadataKey
                ],
                "\"original-etag\""
            )

            // Status transitioned to .uploaded.
            let status = try await currentStatus(forKey: originalKey)
            XCTAssertEqual(
                status, ThumbnailStatus.uploaded.rawValue,
                "SyncedItem must transition to .uploaded on render success"
            )
        }

        // MARK: - Test 2: non-raster guard → .notApplicable, no PUT

        func testGenerateAndUploadOnNonRasterMarksNotApplicable() async throws {
            // Caller forgot to pre-filter — pass a .pdf originalKey. Defensive guard
            // must short-circuit before render and before PUT. localURL is irrelevant
            // because we never attempt to read it.
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("ignored-\(UUID().uuidString).pdf")
            let drive = makeDrive()
            let originalKey = "docs/document.pdf"
            try await seedItem(s3Key: originalKey)

            try await uploader.generateAndUpload(
                localURL: url,
                drive: drive,
                sourceETag: "src-etag",
                originalKey: originalKey
            )

            // Zero PUT calls — early return.
            let putCount = mockS3.calls.filter { $0.hasPrefix("putObjectData(") }.count
            XCTAssertEqual(putCount, 0, "non-raster originalKey must not trigger any PUT")

            let status = try await currentStatus(forKey: originalKey)
            XCTAssertEqual(
                status, ThumbnailStatus.notApplicable.rawValue,
                "non-raster originalKey must be marked .notApplicable"
            )
        }

        // MARK: - Test 3: renderer rejects fixture → strike count++, no PUT

        func testGenerateAndUploadWhenRendererReturnsNilMarksFailed() async throws {
            // The unsupported.pdf fixture is a raster-allow-list bypass: it has no
            // recognized raster extension, so the defensive guard returns early
            // BEFORE we attempt render. To exercise the render-nil path we need a
            // fixture whose path extension passes the raster guard but whose bytes
            // do not decode into a CGImageSource of an allowed UTI. The cleanest
            // way is to write garbage bytes into a .jpg file: the path extension
            // passes `isRasterExtension`, but `CGImageSourceCreateWithURL` either
            // returns nil OR the UTI is not in the allow-list — either branch
            // makes `renderJPEG` return nil.
            let bogusURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("bogus-\(UUID().uuidString).jpg")
            try Data([0x00, 0x01, 0x02, 0x03, 0x04, 0x05]).write(to: bogusURL)
            defer { try? FileManager.default.removeItem(at: bogusURL) }

            let drive = makeDrive()
            let originalKey = "photos/corrupt.jpg"
            try await seedItem(s3Key: originalKey)

            // First failure: strike count goes 0 → 1; below the 3-strike threshold,
            // so the row stays .pending (Plan 13-04 retrofitted from .failed to
            // setThumbnailFailure).
            try await uploader.generateAndUpload(
                localURL: bogusURL,
                drive: drive,
                sourceETag: "src",
                originalKey: originalKey
            )

            let putCount = mockS3.calls.filter { $0.hasPrefix("putObjectData(") }.count
            XCTAssertEqual(putCount, 0, "render-nil must not produce a PUT")

            let statusAfterOne = try await currentStatus(forKey: originalKey)
            XCTAssertEqual(
                statusAfterOne, ThumbnailStatus.pending.rawValue,
                "single render-nil failure (count=1) must keep the SyncedItem .pending below the 3-strike threshold"
            )

            // Second + third failures: strike count climbs 2, 3 — third flips terminal.
            try await uploader.generateAndUpload(
                localURL: bogusURL, drive: drive, sourceETag: "src", originalKey: originalKey
            )
            try await uploader.generateAndUpload(
                localURL: bogusURL, drive: drive, sourceETag: "src", originalKey: originalKey
            )

            let statusAfterThree = try await currentStatus(forKey: originalKey)
            XCTAssertEqual(
                statusAfterThree, ThumbnailStatus.failed.rawValue,
                "third render-nil failure (count=3) must transition the row to terminal .failed"
            )
        }

        // MARK: - Test 4: PUT throws → rethrow + strike count++

        func testGenerateAndUploadOnPutFailureRethrows() async throws {
            let url = try fixtureURL(name: "exif6-portrait", ext: "jpg")
            let drive = makeDrive()
            let originalKey = "photos/will-fail.jpg"
            try await seedItem(s3Key: originalKey)

            // Force the underlying putObjectData to throw.
            mockS3.shouldThrow = DS3ClientError.parseError

            do {
                try await uploader.generateAndUpload(
                    localURL: url,
                    drive: drive,
                    sourceETag: "src",
                    originalKey: originalKey
                )
                XCTFail("expected generateAndUpload to rethrow on PUT failure")
            } catch {
                // Expected — error must be re-surfaced to the caller.
                XCTAssertTrue(
                    error is DS3ClientError,
                    "uploader must rethrow the underlying PUT error type"
                )
            }

            // First PUT failure: strike count goes 0 → 1; below threshold, so
            // .pending (Plan 13-04 retrofitted from .failed to setThumbnailFailure).
            let statusAfterOne = try await currentStatus(forKey: originalKey)
            XCTAssertEqual(
                statusAfterOne, ThumbnailStatus.pending.rawValue,
                "single PUT failure (count=1) keeps the SyncedItem .pending below the 3-strike threshold"
            )

            // Second + third PUT failures: count climbs 2, 3 — third flips terminal.
            for _ in 0..<2 {
                _ = try? await uploader.generateAndUpload(
                    localURL: url, drive: drive, sourceETag: "src", originalKey: originalKey
                )
            }

            let statusAfterThree = try await currentStatus(forKey: originalKey)
            XCTAssertEqual(
                statusAfterThree, ThumbnailStatus.failed.rawValue,
                "third PUT failure (count=3) must transition the row to terminal .failed"
            )
        }

        // MARK: - Test 5: PUT key uses S3PathUtils.thumbnailKey (canonical)

        func testThumbnailKeyIsAppendedJpgOnExistingExtension() async throws {
            let url = try fixtureURL(name: "exif6-portrait", ext: "jpg")
            let drive = makeDrive()
            let originalKey = "photos/exif6-portrait.jpg"
            try await seedItem(s3Key: originalKey)

            try await uploader.generateAndUpload(
                localURL: url,
                drive: drive,
                sourceETag: "src",
                originalKey: originalKey
            )

            // Canonical thumbnail key — appends `.jpg` to the full filename, places
            // `.thumbnails/` in the same directory as the original. We assert the
            // PUT key matches `S3PathUtils.thumbnailKey(...)` rather than a hand-
            // computed string, so a future change to the canonical helper updates
            // both production code and this assertion together.
            let expected = S3PathUtils.thumbnailKey(
                forOriginalKey: originalKey, drivePrefix: drivePrefix
            )
            XCTAssertEqual(mockS3.lastPutObjectDataKey, expected)
            XCTAssertEqual(expected, "photos/.thumbnails/exif6-portrait.jpg.jpg")
        }
    }
#endif
