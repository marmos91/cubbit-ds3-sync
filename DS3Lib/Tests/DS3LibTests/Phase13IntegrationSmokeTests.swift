import Foundation
import SotoS3
import SwiftData
import XCTest

@testable import DS3Lib

/// Phase-13 integration smoke tests (Plan 13-11, D-34).
///
/// These wire all Phase-13 production components together against a
/// **stateful** in-memory S3 bucket and a real (in-memory) `MetadataStore`.
/// Per-component unit tests (`ThumbnailUploaderTests`,
/// `ThumbnailBackfillCoordinatorTests`, `MetadataStoreThumbnailQueriesTests`,
/// `CopyThumbnailTests`, `ThumbnailStrikeRuleTests`) all use lighter mocks
/// that record calls but don't actually share storage between components.
///
/// The bug class these tests exist to catch: **contract drift between the
/// uploader and the consumer.** If the uploader writes a thumbnail to key
/// `X` and the consumer reads from key `Y`, every per-component test passes
/// but the user sees a perpetual default UTType icon. Sharing the in-memory
/// bucket across both calls makes the contract drift fail loudly.
///
/// The four tests cover:
///   1. `testUploadFlowEndToEnd` — uploader writes → store marks `.uploaded`
///      → cache-first read returns the SAME bytes. Single shared bucket.
///   2. `testBackfillFlowEndToEnd` — coordinator processes pending rows →
///      writes 3 thumbnails → cache-first reads return the SAME bytes.
///   3. `testCascadeRoundTrip` — uploader writes → copyThumbnail copies →
///      deleteThumbnail removes old → reads on new key hit, reads on old
///      key miss (Plan 13-08 rename cascade contract).
///   4. `testStrikeRuleEndToEnd` — coordinator processes a render-nil item
///      three times → row transitions to terminal `.failed` → subsequent
///      runBatch invocations skip it (predicate excludes `.failed`) →
///      ETag change resets count + status → next runBatch picks it up.
///
/// All tests are macOS-only — the uploader and the renderer are
/// `#if os(macOS)`-gated (D-09); iOS test runs compile this file as an
/// empty translation unit.
#if os(macOS)
    final class Phase13IntegrationSmokeTests: XCTestCase {

        // MARK: - In-memory S3 bucket (richer than MockDS3S3Client)

        /// Fully stateful S3 client: putObject(Data) stores bytes + metadata
        /// at key; getObjectData retrieves; copyObject reads + writes;
        /// deleteObject removes; getObject(toFile:) writes the stored bytes
        /// to the temp file (so the coordinator's render-from-temp path
        /// flows). All other protocol methods are no-op stubs because the
        /// integration smoke does not exercise them.
        ///
        /// Lock-protected dict — actor would force every call to be `await`,
        /// but `DS3S3ClientProtocol` is `Sendable` and the protocol surface
        /// is already `async`. A lock keeps the bookkeeping simple while
        /// remaining `@unchecked Sendable`-safe.
        final class InMemoryS3Bucket: DS3S3ClientProtocol, @unchecked Sendable {
            private struct StoredObject {
                let data: Data
                let metadata: [String: String]
            }

            private let lock = NSLock()
            private var storage: [String: StoredObject] = [:]
            private var calls: [String] = []
            private var _renderUndecodableForKey: String?

            /// Hook for the render-nil strike-rule test: when a key matches,
            /// the stored bytes the coordinator's `getObject(toFile:)`
            /// writes are deliberately a tiny non-decodable payload so the
            /// renderer returns nil and the strike helper fires. Defaults
            /// to nil = use whatever was put.
            var renderUndecodableForKey: String? {
                get { withLock { _renderUndecodableForKey } }
                set { withLock { _renderUndecodableForKey = newValue } }
            }

            // All lock-protected access funnels through these synchronous
            // helpers so the public async `DS3S3ClientProtocol` methods
            // can stay free of `NSLock` calls (Swift 6 forbids `NSLock`
            // from async contexts).
            private func withLock<T>(_ body: () -> T) -> T {
                lock.lock(); defer { lock.unlock() }
                return body()
            }

            /// Inspection helpers for assertions.
            func has(key: String) -> Bool {
                withLock { storage[key] != nil }
            }

            func bytes(at key: String) -> Data? {
                withLock { storage[key]?.data }
            }

            func metadata(at key: String) -> [String: String]? {
                withLock { storage[key]?.metadata }
            }

            func recordedCalls() -> [String] {
                withLock { calls }
            }

            private func record(_ call: String) {
                withLock { calls.append(call) }
            }

            /// Reads the stored object for `key`, returning the data
            /// (and writing the call to the recorded list as a side
            /// effect when `recordKind` is non-nil).
            private func storedObject(forKey key: String) -> StoredObject? {
                withLock { storage[key] }
            }

            /// Removes the stored object for `key`. Returns true when a
            /// row was removed; false when the key was absent.
            private func removeObject(forKey key: String) -> Bool {
                withLock { storage.removeValue(forKey: key) != nil }
            }

            /// Stores `object` at `key`. Overwrites any prior value.
            private func setObject(_ object: StoredObject, forKey key: String) {
                withLock { storage[key] = object }
            }

            /// Seed an "object" the original-file download path will return.
            /// Used by the backfill test to plant the originals the
            /// coordinator's `getObject(toFile:)` is meant to download
            /// before rendering.
            func seedOriginal(key: String, payload: Data) {
                setObject(StoredObject(data: payload, metadata: [:]), forKey: key)
            }

            // MARK: DS3S3ClientProtocol

            func listBuckets() async throws -> [(name: String, creationDate: Date?)] { [] }

            func listObjects(
                bucket _: String, prefix _: String?, delimiter _: String?,
                maxKeys _: Int?, continuationToken _: String?
            ) async throws -> S3ListingResult {
                S3ListingResult(
                    objects: [], commonPrefixes: [], nextContinuationToken: nil, isTruncated: false
                )
            }

            func headObject(bucket _: String, key _: String) async throws -> S3ObjectMetadata {
                throw DS3ClientError.parseError
            }

            func deleteObject(bucket _: String, key: String) async throws {
                record("deleteObject(\(key))")
                let didRemove = removeObject(forKey: key)
                if !didRemove {
                    // Mirror Soto's NoSuchKey for absent keys so deleteThumbnail's
                    // silent-on-404 contract gets exercised end-to-end.
                    throw SotoS3.S3ErrorType.noSuchKey
                }
            }

            func deleteObjects(bucket _: String, keys: [String]) async throws -> Int {
                var removed = 0
                for key in keys {
                    if removeObject(forKey: key) { removed += 1 }
                }
                return removed
            }

            func copyObject(
                bucket _: String, sourceKey: String, destinationKey: String,
                metadata _: [String: String]?
            ) async throws {
                record("copyObject(\(sourceKey)->\(destinationKey))")
                guard let src = storedObject(forKey: sourceKey) else {
                    throw SotoS3.S3ErrorType.noSuchKey
                }
                // metadata: nil → preserve source metadata (AWS COPY default).
                setObject(src, forKey: destinationKey)
            }

            func getObject(
                bucket _: String, key: String, toFile fileURL: URL,
                onProgress _: TransferProgressHandler?
            ) async throws -> S3DownloadResult {
                record("getObject(\(key))")
                guard let payload = storedObject(forKey: key)?.data else {
                    throw SotoS3.S3ErrorType.noSuchKey
                }
                // Write the stored bytes (or a deliberate non-decodable payload
                // for the strike-rule fixture) so the coordinator's
                // render-from-temp flows naturally.
                let toWrite: Data
                if renderUndecodableForKey == key {
                    toWrite = Data([0x00, 0x01, 0x02, 0x03, 0x04, 0x05])
                } else {
                    toWrite = payload
                }
                try toWrite.write(to: fileURL)
                return S3DownloadResult(
                    etag: "\"download-etag\"",
                    contentType: "image/jpeg",
                    lastModified: nil,
                    contentLength: Int64(toWrite.count)
                )
            }

            func getObjectData(bucket _: String, key: String) async throws -> Data {
                record("getObjectData(\(key))")
                guard let payload = storedObject(forKey: key)?.data else {
                    throw SotoS3.S3ErrorType.noSuchKey
                }
                return payload
            }

            func putObject(
                bucket _: String, key: String, fileURL _: URL?,
                onProgress _: TransferProgressHandler?
            ) async throws -> String? {
                record("putObject(\(key))")
                return "\"object-etag\""
            }

            func putObjectData(
                bucket _: String, key: String, data: Data, metadata: [String: String]?
            ) async throws -> String? {
                record("putObjectData(\(key))")
                setObject(StoredObject(data: data, metadata: metadata ?? [:]), forKey: key)
                return "\"thumb-etag\""
            }

            func createMultipartUpload(bucket _: String, key _: String) async throws -> String {
                "mpu-id"
            }

            func uploadPart(
                bucket _: String, key _: String, uploadId _: String,
                partNumber: Int, data _: Data
            ) async throws -> CompletedPartResult {
                CompletedPartResult(partNumber: partNumber, etag: "\"part-etag\"")
            }

            func completeMultipartUpload(
                bucket _: String, key _: String, uploadId _: String,
                parts _: [(partNumber: Int, etag: String)]
            ) async throws -> MultipartCompleteResult {
                MultipartCompleteResult(etag: "\"final-etag\"")
            }

            func abortMultipartUpload(bucket _: String, key _: String, uploadId _: String) async throws {}

            func shutdown() throws {}
        }

        // MARK: - Fixtures

        private var container: ModelContainer!
        private var metadataStore: MetadataStore!
        private var bucket: InMemoryS3Bucket!

        private let driveId = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        private let drivePrefix: String? = nil

        override func setUp() async throws {
            // V4 schema (Plan 13-04 bumped from V3).
            let schema = Schema(versionedSchema: SyncedItemSchemaV4.self)
            let config = ModelConfiguration(isStoredInMemoryOnly: true)
            container = try ModelContainer(for: schema, configurations: [config])
            metadataStore = MetadataStore(modelContainer: container)
            bucket = InMemoryS3Bucket()
        }

        override func tearDown() async throws {
            bucket = nil
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
                bucket: Bucket(name: "smoke-bucket"),
                prefix: drivePrefix
            )
            return DS3Drive(id: driveId, name: "Smoke Drive", syncAnchor: anchor)
        }

        @discardableResult
        private func seedItem(
            s3Key: String, etag: String? = "\"original-etag\""
        ) async throws -> String {
            try await metadataStore.upsertItem(
                s3Key: s3Key, driveId: driveId, etag: etag,
                syncStatus: .synced, contentType: "image/jpeg", size: 1024
            )
            return s3Key
        }

        // MARK: - Test 1: upload flow end-to-end

        /// **Cross-component contract:**
        /// `ThumbnailUploader.generateAndUpload` writes a thumbnail to key `K`
        /// AND `getThumbnailBytes(K)` reads bytes from the same `K`. If either
        /// side drifts, this fails.
        func testUploadFlowEndToEnd() async throws {
            let drive = makeDrive()
            let originalKey = "photos/exif6-portrait.jpg"
            try await seedItem(s3Key: originalKey)

            let uploader = ThumbnailUploader(s3Client: bucket, metadataStore: metadataStore)

            // Phase 1 — uploader renders + PUTs.
            try await uploader.generateAndUpload(
                localURL: try fixtureURL(name: "exif6-portrait", ext: "jpg"),
                drive: drive,
                sourceETag: "\"original-etag\"",
                originalKey: originalKey
            )

            // Cross-component pin #1 — SyncedItem must be `.uploaded`.
            let status = try await metadataStore.fetchItemSyncStatusForThumbnails(
                s3Key: originalKey, driveId: driveId
            )
            XCTAssertEqual(
                status, ThumbnailStatus.uploaded.rawValue,
                "uploader must transition the SyncedItem to .uploaded on render success"
            )

            // Cross-component pin #2 — bucket has the object at the canonical key.
            let canonicalKey = S3PathUtils.thumbnailKey(
                forOriginalKey: originalKey, drivePrefix: drivePrefix
            )
            XCTAssertTrue(
                bucket.has(key: canonicalKey),
                "uploader must PUT to the canonical thumbnail key — drift catches contract bugs"
            )

            // Cross-component pin #3 — sourceETag landed in user-metadata.
            let metadata = bucket.metadata(at: canonicalKey)
            XCTAssertEqual(
                metadata?[DefaultSettings.Thumbnail.sourceETagMetadataKey],
                "\"original-etag\"",
                "uploader must propagate sourceETag to x-amz-meta-source-etag"
            )

            // Phase 2 — cache-first read on the same key returns matching bytes.
            // This is the core consume-path contract Plan 13-06 rewrote.
            let fetched = try await bucket.getThumbnailBytes(
                bucket: drive.syncAnchor.bucket.name, key: canonicalKey
            )
            XCTAssertNotNil(fetched, "getThumbnailBytes must return non-nil for an uploaded thumbnail")
            XCTAssertEqual(
                fetched, bucket.bytes(at: canonicalKey),
                "consume path must read the SAME bytes the uploader wrote"
            )
            XCTAssertGreaterThan(fetched?.count ?? 0, 0)
        }

        // MARK: - Test 2: backfill flow end-to-end

        /// **Cross-component contract:**
        /// `ThumbnailBackfillCoordinator.runBatch` processes 3 pending rows;
        /// each row's original is downloaded via `getObject(toFile:)`,
        /// rendered via `ThumbnailRenderer`, PUT to the canonical thumbnail
        /// key, and the SyncedItem transitions to `.uploaded`. The post-
        /// condition is a 1:1 correspondence between seeded pendings and
        /// `.thumbnails/` keys in the bucket.
        func testBackfillFlowEndToEnd() async throws {
            let drive = makeDrive()
            let fixtureURL = try fixtureURL(name: "exif6-portrait", ext: "jpg")
            let originalBytes = try Data(contentsOf: fixtureURL)

            // Seed 3 pending raster rows AND plant their originals in the
            // bucket so the coordinator's `getObject(toFile:)` succeeds.
            let originalKeys = (0..<3).map { "photos/photo-\($0).jpg" }
            for key in originalKeys {
                try await seedItem(s3Key: key)
                bucket.seedOriginal(key: key, payload: originalBytes)
            }

            // Force `.pending` thumbnail status so they appear in the
            // coordinator's fetchPendingThumbnails query (upsert defaults
            // are `.pending`, but we want to be explicit).
            for key in originalKeys {
                try await metadataStore.setThumbnailStatus(
                    s3Key: key, driveId: driveId, status: .pending
                )
            }

            let coordinator = ThumbnailBackfillCoordinator(
                metadataStore: metadataStore,
                s3Client: bucket,
                drive: drive,
                thermalStateProvider: { .nominal },
                pauseProvider: { _ in false }
            )

            let result = try await coordinator.runBatch(maxItems: 5)

            XCTAssertEqual(result.processed, 3, "coordinator must process all 3 pending rows in one batch")
            XCTAssertEqual(result.succeeded, 3, "all 3 originals decode + upload cleanly")
            XCTAssertEqual(result.failed, 0)

            // Cross-component pin — every row is `.uploaded` AND every
            // canonical thumbnail key exists in the shared bucket.
            for key in originalKeys {
                let status = try await metadataStore.fetchItemSyncStatusForThumbnails(
                    s3Key: key, driveId: driveId
                )
                XCTAssertEqual(
                    status, ThumbnailStatus.uploaded.rawValue,
                    "coordinator must transition \(key) to .uploaded"
                )

                let canonical = S3PathUtils.thumbnailKey(
                    forOriginalKey: key, drivePrefix: drivePrefix
                )
                XCTAssertTrue(
                    bucket.has(key: canonical),
                    "coordinator must PUT thumbnail at canonical key for \(key)"
                )

                // The bytes the coordinator wrote must be readable via the
                // consume-path API on the SAME key.
                let fetched = try await bucket.getThumbnailBytes(
                    bucket: drive.syncAnchor.bucket.name, key: canonical
                )
                XCTAssertNotNil(
                    fetched,
                    "getThumbnailBytes must hit for backfilled key \(canonical)"
                )
            }
        }

        // MARK: - Test 3: cascade round-trip (rename)

        /// **Cross-component contract (Plan 13-08 rename cascade):**
        /// 1. uploader writes to `oldThumb`,
        /// 2. `copyThumbnail(from: oldThumb, to: newThumb)` creates `newThumb`,
        /// 3. `deleteThumbnail(oldThumb)` removes `oldThumb`,
        /// 4. consume-path read on `newThumb` returns bytes,
        /// 5. consume-path read on `oldThumb` returns nil (silent on 404).
        func testCascadeRoundTrip() async throws {
            let drive = makeDrive()
            let oldOriginal = "photos/old-name.jpg"
            let newOriginal = "photos/new-name.jpg"
            try await seedItem(s3Key: oldOriginal)

            // Phase 1 — uploader writes the original thumbnail.
            let uploader = ThumbnailUploader(s3Client: bucket, metadataStore: metadataStore)
            try await uploader.generateAndUpload(
                localURL: try fixtureURL(name: "exif6-portrait", ext: "jpg"),
                drive: drive,
                sourceETag: "\"original-etag\"",
                originalKey: oldOriginal
            )

            let oldThumbKey = S3PathUtils.thumbnailKey(
                forOriginalKey: oldOriginal, drivePrefix: drivePrefix
            )
            let newThumbKey = S3PathUtils.thumbnailKey(
                forOriginalKey: newOriginal, drivePrefix: drivePrefix
            )
            let originalBytes = try XCTUnwrap(bucket.bytes(at: oldThumbKey))

            // Phase 2 — server-side copy old → new.
            try await bucket.copyThumbnail(
                bucket: drive.syncAnchor.bucket.name,
                fromKey: oldThumbKey,
                toKey: newThumbKey
            )

            // Cross-component pin #1 — new key has the SAME bytes as the
            // pre-copy old key (server-side copy is bytewise-identical).
            let copiedBytes = bucket.bytes(at: newThumbKey)
            XCTAssertEqual(
                copiedBytes, originalBytes,
                "copyThumbnail must produce a bytewise-identical destination"
            )

            // Phase 3 — delete the old thumbnail.
            try await bucket.deleteThumbnail(
                bucket: drive.syncAnchor.bucket.name, key: oldThumbKey
            )

            // Cross-component pin #2 — consume-path read on new key hits.
            let newFetched = try await bucket.getThumbnailBytes(
                bucket: drive.syncAnchor.bucket.name, key: newThumbKey
            )
            XCTAssertNotNil(
                newFetched,
                "consume-path read on the new thumbnail key must return bytes"
            )
            XCTAssertEqual(newFetched, originalBytes)

            // Cross-component pin #3 — consume-path read on old key returns
            // nil (silent-on-404 contract). The default UTType icon is what
            // Finder shows; no error surfaces.
            let oldFetched = try await bucket.getThumbnailBytes(
                bucket: drive.syncAnchor.bucket.name, key: oldThumbKey
            )
            XCTAssertNil(
                oldFetched,
                "deleted thumbnail key must return nil (silent-on-404)"
            )
        }

        // MARK: - Test 4: strike rule end-to-end (terminal + ETag reset)

        /// **Cross-component contract (Plans 13-04 + 13-05):**
        /// 1. Coordinator processes a row whose download payload doesn't
        ///    decode (renderer returns nil) — strike count goes 1.
        /// 2. Two more runBatch invocations bring count to 3 — row flips
        ///    terminal `.failed`.
        /// 3. Subsequent runBatch DOES NOT re-process the terminal row
        ///    (`fetchPendingThumbnails` excludes `.failed` per D-30).
        /// 4. Upserting the row with a new ETag resets count + status.
        /// 5. Next runBatch picks the row up again — proves the reset
        ///    re-arms the row (D-31).
        func testStrikeRuleEndToEnd() async throws {
            let drive = makeDrive()
            let originalKey = "photos/keeps-failing.jpg"
            try await seedItem(s3Key: originalKey, etag: "\"etag-v1\"")
            // Plant a stub original so getObject succeeds, but the
            // bucket's render-undecodable hook makes the render step
            // return nil — exercising the strike helper.
            bucket.seedOriginal(key: originalKey, payload: Data([0xff, 0xd8])) // bogus jpg
            bucket.renderUndecodableForKey = originalKey

            let coordinator = ThumbnailBackfillCoordinator(
                metadataStore: metadataStore,
                s3Client: bucket,
                drive: drive,
                thermalStateProvider: { .nominal },
                pauseProvider: { _ in false }
            )

            // Strike 1 — count 0 → 1, status stays .pending.
            _ = try await coordinator.runBatch(maxItems: 5)
            var state = try await metadataStore.thumbnailStateForTesting(
                s3Key: originalKey, driveId: driveId
            )
            XCTAssertEqual(state?.0, 1, "first failure must increment count to 1")
            XCTAssertEqual(
                state?.1, ThumbnailStatus.pending.rawValue,
                "below threshold the row must stay .pending so next BFS pass retries"
            )

            // Strike 2 + 3 — count climbs 2, 3.
            _ = try await coordinator.runBatch(maxItems: 5)
            _ = try await coordinator.runBatch(maxItems: 5)
            state = try await metadataStore.thumbnailStateForTesting(
                s3Key: originalKey, driveId: driveId
            )
            XCTAssertEqual(state?.0, 3, "third failure must bring count to 3")
            XCTAssertEqual(
                state?.1, ThumbnailStatus.failed.rawValue,
                "count >= 3 must transition to terminal .failed (Pitfall 10 boundary)"
            )

            // Subsequent runBatch must NOT re-process the terminal row.
            // The fetchPendingThumbnails predicate excludes .failed (D-30),
            // so the coordinator finds an empty queue.
            let postTerminalResult = try await coordinator.runBatch(maxItems: 5)
            XCTAssertEqual(
                postTerminalResult.processed, 0,
                "terminal .failed rows must not appear in fetchPendingThumbnails (D-30)"
            )

            // ETag-change reset (D-31) — re-upserting the row with a NEW
            // etag must reset count to 0 AND status to .pending.
            try await metadataStore.upsertItem(
                s3Key: originalKey, driveId: driveId, etag: "\"etag-v2\"",
                syncStatus: .synced, contentType: "image/jpeg", size: 1024
            )
            state = try await metadataStore.thumbnailStateForTesting(
                s3Key: originalKey, driveId: driveId
            )
            XCTAssertEqual(
                state?.0, 0,
                "ETag change must reset thumbnailFailCount to 0 (D-31 reset condition)"
            )
            XCTAssertEqual(
                state?.1, ThumbnailStatus.pending.rawValue,
                "ETag change must re-arm the row by transitioning back to .pending"
            )

            // Now that the row is .pending again, but the bucket is still
            // configured to write undecodable payload, the next runBatch
            // picks it up — proving the reset wired the row back into the
            // pending query. The strike count goes from 0 → 1 again.
            _ = try await coordinator.runBatch(maxItems: 5)
            state = try await metadataStore.thumbnailStateForTesting(
                s3Key: originalKey, driveId: driveId
            )
            XCTAssertEqual(
                state?.0, 1,
                "after reset, the row must be re-eligible — next failure increments count from 0 to 1"
            )
        }
    }
#endif
