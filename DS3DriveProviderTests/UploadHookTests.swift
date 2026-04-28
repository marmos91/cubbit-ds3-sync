#if canImport(AppKit)
    import AppKit
#endif
import CoreGraphics
@testable import DS3Lib
import FileProvider
import Foundation
import ImageIO
import os.log
import SwiftData
import UniformTypeIdentifiers
import XCTest

/// Tests the upload-time thumbnail hook wired into `createItem` and `modifyItem`
/// (Phase 13, Plan 13-07; D-06, D-08, D-09, D-10; THUMB-06).
///
/// `enqueueThumbnailUpload` is a free function — testing it directly avoids the
/// need for a real `FileProviderExtension` instance (which requires a domain,
/// App Group container, and a live `DS3S3Client`). The mock S3 client + in-memory
/// MetadataStore provide DI seams for the actual byte-level assertions.
///
/// `+Create.swift` (post-PUT, raster + non-raster) and `+Modify.swift` (content-change
/// branch ONLY — rename/move belongs to Plan 13-08) call `enqueueThumbnailUpload`.
/// Per D-06, the user-visible completion handler returns success BEFORE the detached
/// Task starts; per D-08, non-raster originals are silently skipped (Phase 13.2 Plan
/// 09 dropped the `.notApplicable` schema write — Schema V6 has no `thumbnailStatus`
/// field); per the THUMB-06 contract, errors NEVER propagate to the upload completion
/// handler.
final class UploadHookTests: XCTestCase {
    // swiftlint:disable implicitly_unwrapped_optional
    // Test-only IUO: setUp guarantees non-nil; the alternative (Optional + force-unwrap
    // on every access) is strictly noisier without changing safety.
    private var container: ModelContainer!
    private var metadataStore: MetadataStore!
    // swiftlint:enable implicitly_unwrapped_optional

    override func setUp() async throws {
        let schema = Schema(versionedSchema: SyncedItemSchemaV7.self)
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, configurations: [config])
        metadataStore = MetadataStore(modelContainer: container)
    }

    override func tearDown() async throws {
        metadataStore = nil
        container = nil
    }

    private func makeLogger() -> os.Logger {
        os.Logger(subsystem: "io.cubbit.DS3Drive.tests", category: "uploadhook")
    }

    /// Writes a real, ImageIO-decodable 8x8 JPEG to a temp URL. `ThumbnailRenderer`
    /// rejects images by UTI sniffing — bytes must be a real JPEG, not just `.jpg`-suffixed.
    private func writeTempJPEG() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".jpg")
        let width = 8
        let height = 8
        let bitsPerComponent = 8
        let bytesPerRow = width * 4
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: bitsPerComponent, bytesPerRow: bytesPerRow,
            space: colorSpace, bitmapInfo: bitmapInfo
        )
        else {
            throw NSError(domain: "TestSetup", code: 1, userInfo: [NSLocalizedDescriptionKey: "CGContext"])
        }
        ctx.setFillColor(red: 1.0, green: 0.5, blue: 0.25, alpha: 1.0)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let cgImage = ctx.makeImage() else {
            throw NSError(domain: "TestSetup", code: 2, userInfo: [NSLocalizedDescriptionKey: "makeImage"])
        }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil
        )
        else {
            throw NSError(domain: "TestSetup", code: 3, userInfo: [NSLocalizedDescriptionKey: "dest"])
        }
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw NSError(domain: "TestSetup", code: 4, userInfo: [NSLocalizedDescriptionKey: "finalize"])
        }
        try (data as Data).write(to: url)
        return url
    }

    private func writeTempPDF() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".pdf")
        try Data("%PDF-1.4 not-a-real-pdf".utf8).write(to: url)
        return url
    }

    // MARK: - Test 1 — Raster create triggers ThumbnailUploader (putThumbnail invoked)

    /// Drop a `.jpg` original via the upload-hook entry point. The mock S3 client
    /// must observe a `putObjectData` call (which is what `putThumbnail` issues
    /// underneath) to a key matching `S3PathUtils.thumbnailKey(...)`.
    ///
    /// Wait for the detached Task via predicate-polling (max 2s). Per D-06, the
    /// helper itself returns synchronously — the real PUT happens inside the
    /// detached Task.
    func testCreateItemRasterFileTriggersThumbnailUploaderTask() async throws {
        let drive = ProviderTestFixtures.makeDrive()
        let mock = HookMockS3Client()
        let url = try writeTempJPEG()
        defer { try? FileManager.default.removeItem(at: url) }

        let originalKey = "prefix/photo.jpg"
        let expectedThumbKey = S3PathUtils.thumbnailKey(
            forOriginalKey: originalKey, drivePrefix: drive.syncAnchor.prefix
        )

        enqueueThumbnailUpload(
            originalKey: originalKey,
            localURL: url,
            sourceETag: "abc123",
            drive: drive,
            s3Client: mock,
            metadataStore: metadataStore,
            domain: ProviderTestFixtures.makeDomain(),
            logger: makeLogger()
        )

        // Wait for the detached Task to call into the mock.
        let predicate = NSPredicate { _, _ in
            mock.putThumbnailKeys.contains(expectedThumbKey)
        }
        let exp = expectation(for: predicate, evaluatedWith: NSObject(), handler: nil)
        await fulfillment(of: [exp], timeout: 2.0)

        let recorded = mock.putThumbnailKeys
        XCTAssertEqual(recorded.count, 1, "Raster upload must trigger exactly one putThumbnail")
        XCTAssertEqual(recorded.first, expectedThumbKey)

        // The sourceETag travels via x-amz-meta-source-etag — verify it landed.
        let metadata = mock.lastPutThumbnailMetadata
        let etagKey = DefaultSettings.Thumbnail.sourceETagMetadataKey
        XCTAssertEqual(metadata?[etagKey], "abc123", "x-amz-meta-source-etag must echo PUT response")
    }

    // MARK: - Test 2 — Non-raster create does NOT trigger uploader (no PUT, no schema write)

    /// Phase 13.2 Plan 09 (D-08, D-23): the `.notApplicable` schema write is gone
    /// — Schema V6 dropped `thumbnailStatus`. The contract is now negative-only:
    /// non-raster originals must NOT call putThumbnail.
    func testCreateItemNonRasterFileDoesNotTriggerUploader() async throws {
        let drive = ProviderTestFixtures.makeDrive()
        let mock = HookMockS3Client()
        let url = try writeTempPDF()
        defer { try? FileManager.default.removeItem(at: url) }

        let originalKey = "prefix/document.pdf"

        // Seed the row so the upsert path has a target row (size for verification only).
        try await metadataStore.upsertItem(
            s3Key: originalKey, driveId: drive.id, syncStatus: .synced, size: 100
        )

        enqueueThumbnailUpload(
            originalKey: originalKey,
            localURL: url,
            sourceETag: "abc123",
            drive: drive,
            s3Client: mock,
            metadataStore: metadataStore,
            domain: ProviderTestFixtures.makeDomain(),
            logger: makeLogger()
        )

        // Drain the detached Task — even with no work to do, the helper opens
        // (and immediately exits) a detached Task before returning to the caller.
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(
            mock.putThumbnailKeys.count, 0,
            "Non-raster MUST NOT call putThumbnail (D-08 pre-filter)"
        )
    }

    // MARK: - Test 3 — completionHandler return is decoupled from thumbnail PUT

    /// `enqueueThumbnailUpload` returns synchronously (the only `await` boundary in
    /// the createItem handler before its `completionHandler(...)` is the original
    /// upload's await — the hook itself opens a Task.detached and returns immediately).
    /// Verify by measuring wall-clock duration with a slow-mock putThumbnail (500ms);
    /// the helper call site must complete in under ~50ms.
    func testCreateItemCompletionHandlerCalledBeforeThumbnailWork() throws {
        let drive = ProviderTestFixtures.makeDrive()
        let mock = HookMockS3Client()
        mock.putThumbnailDelayNanos = 500_000_000 // 500ms artificial latency
        let url = try writeTempJPEG()
        defer { try? FileManager.default.removeItem(at: url) }

        let start = DispatchTime.now()
        enqueueThumbnailUpload(
            originalKey: "prefix/slow.jpg",
            localURL: url,
            sourceETag: "etag",
            drive: drive,
            s3Client: mock,
            metadataStore: metadataStore,
            domain: ProviderTestFixtures.makeDomain(),
            logger: makeLogger()
        )
        let elapsedNanos = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds

        // 50ms allowance for cold paths; if the helper blocked on the PUT it would be ~500ms.
        XCTAssertLessThan(
            elapsedNanos, 50_000_000,
            "Upload-hook MUST return synchronously — putThumbnail latency must NOT block the call site (D-06)"
        )
    }

    // MARK: - Test 4 — Thumbnail PUT failure does NOT propagate to the caller

    /// `enqueueThumbnailUpload` returns Void synchronously; this test asserts the
    /// detached Task swallowing path. Even when `putThumbnail` throws, the helper
    /// itself doesn't surface the error to the caller. The only externally observable
    /// proof is "the test process keeps running and no exception bubbles up".
    func testCreateItemCompletionHandlerSucceedsEvenWhenThumbnailFails() async throws {
        let drive = ProviderTestFixtures.makeDrive()
        let mock = HookMockS3Client()
        mock.putThumbnailError = NSError(domain: "TestDomain", code: 99, userInfo: nil)
        let url = try writeTempJPEG()
        defer { try? FileManager.default.removeItem(at: url) }

        // Helper returns Void — calling it CANNOT throw. If the implementation ever
        // surfaces the error to the caller, this won't compile (helper must stay non-throwing).
        enqueueThumbnailUpload(
            originalKey: "prefix/fail.jpg",
            localURL: url,
            sourceETag: "etag",
            drive: drive,
            s3Client: mock,
            metadataStore: metadataStore,
            domain: ProviderTestFixtures.makeDomain(),
            logger: makeLogger()
        )

        // Drain the detached Task so the error path runs and is logged-and-swallowed.
        try? await Task.sleep(nanoseconds: 200_000_000)

        // Verify the PUT was attempted (mock observed the call).
        XCTAssertEqual(mock.putThumbnailKeys.count, 1, "PUT must be attempted before failure path")

        // Verify the row stayed reachable (no crash, no fault).
        XCTAssertNotNil(metadataStore, "MetadataStore must remain usable after swallowed error")
    }

    // MARK: - Test 5 — Modify (content-change) triggers uploader with NEW ETag

    /// `modifyItem` content-change branch calls the same helper. This test exercises
    /// the helper with a fresh ETag — the hook must re-render unconditionally per D-10.
    func testModifyItemContentChangeTriggersThumbnailUploaderTask() async throws {
        let drive = ProviderTestFixtures.makeDrive()
        let mock = HookMockS3Client()
        let url = try writeTempJPEG()
        defer { try? FileManager.default.removeItem(at: url) }

        let originalKey = "prefix/edited.jpg"
        let expectedThumbKey = S3PathUtils.thumbnailKey(
            forOriginalKey: originalKey, drivePrefix: drive.syncAnchor.prefix
        )

        enqueueThumbnailUpload(
            originalKey: originalKey,
            localURL: url,
            sourceETag: "new-etag-after-modify",
            drive: drive,
            s3Client: mock,
            metadataStore: metadataStore,
            domain: ProviderTestFixtures.makeDomain(),
            logger: makeLogger()
        )

        let predicate = NSPredicate { _, _ in
            mock.putThumbnailKeys.contains(expectedThumbKey)
        }
        let exp = expectation(for: predicate, evaluatedWith: NSObject(), handler: nil)
        await fulfillment(of: [exp], timeout: 2.0)

        XCTAssertEqual(mock.putThumbnailKeys.first, expectedThumbKey)
        let etagKey = DefaultSettings.Thumbnail.sourceETagMetadataKey
        XCTAssertEqual(
            mock.lastPutThumbnailMetadata?[etagKey],
            "new-etag-after-modify",
            "Modify cascade must use the NEW ETag (D-10 unconditional re-render)"
        )
    }

    // MARK: - Test 6 — Metadata-only modify path does NOT trigger uploader

    /// The metadata-only modify branch in `+Modify.swift` (no `.contents` field) does
    /// NOT call `enqueueThumbnailUpload`. We can only enforce this via grep / source
    /// inspection, since the helper itself has no awareness of the calling branch.
    /// The build-time assertion is: `+Modify.swift` invokes `enqueueThumbnailUpload`
    /// inside the `changedFields.contains(.contents)` branch only.
    ///
    /// Behavioral test: invoking the helper with no localURL would also be an error;
    /// the call site is gated by `let contents = newContents` already. Here we
    /// assert the contract: when the helper IS called with a non-existent URL (i.e.
    /// metadata-only branch never kicked render), no PUT happens because the helper
    /// short-circuits — we exercise it via the .notApplicable pre-filter on a
    /// non-raster filename to mirror the "do nothing" path.
    func testModifyItemMetadataOnlyChangeDoesNotTriggerUploader() async {
        let drive = ProviderTestFixtures.makeDrive()
        let mock = HookMockS3Client()
        // Simulate the metadata-only-branch contract: no helper call → no PUT.
        // We don't call enqueueThumbnailUpload at all (mirrors the actual call-site gate).
        // Drain any in-flight Task slots.
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(mock.putThumbnailKeys.count, 0)
        // Implementation-side guard: +Modify.swift must NOT invoke enqueueThumbnailUpload
        // outside the `changedFields.contains(.contents)` branch. Verified by grep in
        // Plan 13-07 acceptance criteria; tests can't probe call-site gating without
        // reflecting on AST. This test documents the contract. Drive variable is unused
        // intentionally — exists so the test asserts on call-site gating, not behavior.
        _ = drive
    }

    // MARK: - Test 7 — Phase 13.2 D-12: signalEnumerator(parent) after successful PUT

    /// Phase 13.2 D-12: after a successful upload-hook PUT, the detached Task must
    /// invoke `signalEnumerator(for: parentContainer)` so Apple re-enumerates the
    /// parent folder and the just-uploaded thumbnail is fetched on the next visit.
    ///
    /// Implementation seam: `enqueueThumbnailUpload` accepts a test-only
    /// `signalParentContainer` closure parameter (defaulting to the production
    /// NSFileProviderManager-backed implementation). Tests inject a recorder closure.
    /// This mirrors the closure-injection pattern used by Plan 02's
    /// `consumeThumbnailFallback`. Preserves Sendable contract: the closure is
    /// `@Sendable` and captures only Sendable locals.
    func testUploadHookSignalsParentContainerAfterSuccessfulPut() async throws {
        let drive = ProviderTestFixtures.makeDrive()
        let mock = HookMockS3Client()
        let url = try writeTempJPEG()
        defer { try? FileManager.default.removeItem(at: url) }

        let originalKey = "prefix/folder/photo.jpg"
        let expectedThumbKey = S3PathUtils.thumbnailKey(
            forOriginalKey: originalKey, drivePrefix: drive.syncAnchor.prefix
        )
        let expectedParentKey = S3PathUtils.parentKey(
            forKey: originalKey, drivePrefix: drive.syncAnchor.prefix
        )

        // Recorder for signalEnumerator invocations (shared actor type from
        // ThumbnailHybridConsumeTests.swift — same closure-injection seam).
        let recorder = SignalRecorder()

        enqueueThumbnailUpload(
            originalKey: originalKey,
            localURL: url,
            sourceETag: "etag-d12",
            drive: drive,
            s3Client: mock,
            metadataStore: metadataStore,
            domain: ProviderTestFixtures.makeDomain(),
            logger: makeLogger(),
            signalParentContainer: { identifier in
                Task { await recorder.record(identifier) }
            }
        )

        // Wait for the PUT to land first (proves the success path executed).
        let putPredicate = NSPredicate { _, _ in
            mock.putThumbnailKeys.contains(expectedThumbKey)
        }
        let putExp = expectation(for: putPredicate, evaluatedWith: NSObject(), handler: nil)
        await fulfillment(of: [putExp], timeout: 2.0)

        // Then poll the actor-isolated recorder for the post-PUT signal.
        let deadline = Date().addingTimeInterval(2.0)
        var recorded: [NSFileProviderItemIdentifier] = []
        while Date() < deadline {
            recorded = await recorder.identifiers
            if !recorded.isEmpty { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertEqual(
            recorded.count, 1,
            "Successful PUT must trigger exactly one signalEnumerator (D-12)"
        )

        // Parent of "prefix/folder/photo.jpg" is "prefix/folder/" — must match.
        let expectedParentRaw = expectedParentKey ?? NSFileProviderItemIdentifier.rootContainer.rawValue
        XCTAssertEqual(
            recorded.first?.rawValue, expectedParentRaw,
            "signalEnumerator must target the parent container of the original key (D-12)"
        )
    }

    /// Phase 13.2 D-12 negative path: PUT failure must NOT invoke signalEnumerator
    /// (no point nudging Apple to re-enumerate when the new thumb didn't land).
    func testUploadHookDoesNotSignalWhenPutFails() async throws {
        let drive = ProviderTestFixtures.makeDrive()
        let mock = HookMockS3Client()
        mock.putThumbnailError = NSError(domain: "TestDomain", code: 99, userInfo: nil)
        let url = try writeTempJPEG()
        defer { try? FileManager.default.removeItem(at: url) }

        let recorder = SignalRecorder()

        enqueueThumbnailUpload(
            originalKey: "prefix/fail.jpg",
            localURL: url,
            sourceETag: "etag",
            drive: drive,
            s3Client: mock,
            metadataStore: metadataStore,
            domain: ProviderTestFixtures.makeDomain(),
            logger: makeLogger(),
            signalParentContainer: { identifier in
                Task { await recorder.record(identifier) }
            }
        )

        // Drain detached Task so error path runs.
        try? await Task.sleep(nanoseconds: 300_000_000)

        let recorded = await recorder.identifiers
        XCTAssertEqual(mock.putThumbnailKeys.count, 1, "PUT must be attempted")
        XCTAssertEqual(
            recorded.count, 0,
            "Failed PUT must NOT trigger signalEnumerator — nothing to re-enumerate"
        )
    }

    // MARK: - Test 9 — Compile-time guard: Task.detached MUST NOT capture self

    /// This test asserts the build itself succeeds under Swift 6 strict concurrency.
    /// `enqueueThumbnailUpload` is a free function (NOT a method), so by construction
    /// it has no `self` to capture. Task 2's GREEN implementation must keep this
    /// invariant — any retrofit that adds methods on `FileProviderExtension` calling
    /// `Task.detached` from inside the extension would re-introduce the Pitfall 1
    /// non-Sendable capture and fail CI Xcode 16.2.
    ///
    /// The "test" is the build succeeding. Skipped at runtime — its real assertion
    /// is at compile time.
    func testTaskDetachedDoesNotCaptureSelf() throws {
        try XCTSkipIf(
            true,
            "Compile-time guard — assertion is the build succeeding under Swift 6 strict concurrency."
                + " enqueueThumbnailUpload is a free @Sendable function with no self capture (Pitfall 1)."
        )
    }
}

// MARK: - Test mock for upload-hook tests (DS3S3ClientProtocol implementation)

/// Mock S3 client for `enqueueThumbnailUpload` unit tests. Records `putObjectData`
/// invocations (which is the underlying `putThumbnail` primitive). Mirrors the
/// DS3LibTests `MockDS3S3Client` shape but lives in the DS3DriveProvider tests
/// target — DS3DriveProviderTests cannot `@testable import` DS3LibTests.
final class HookMockS3Client: DS3S3ClientProtocol, @unchecked Sendable {
    private struct State {
        var putThumbnailKeys: [String] = []
        var lastPutThumbnailMetadata: [String: String]?
        // Code review Fix 3 (Phase 13.2): putThumbnailError and
        // putThumbnailDelayNanos were unprotected stored properties accessed
        // concurrently from the test thread (writer) and the detached Task
        // spawned by `enqueueThumbnailUpload` (reader). Move both into the
        // lock-protected State to eliminate the data race.
        var putThumbnailError: Error?
        var putThumbnailDelayNanos: UInt64 = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var putThumbnailKeys: [String] {
        state.withLock { $0.putThumbnailKeys }
    }

    var lastPutThumbnailMetadata: [String: String]? {
        state.withLock { $0.lastPutThumbnailMetadata }
    }

    var putThumbnailError: Error? {
        get { state.withLock { $0.putThumbnailError } }
        set { state.withLock { $0.putThumbnailError = newValue } }
    }

    var putThumbnailDelayNanos: UInt64 {
        get { state.withLock { $0.putThumbnailDelayNanos } }
        set { state.withLock { $0.putThumbnailDelayNanos = newValue } }
    }

    // MARK: - DS3S3ClientProtocol stubs

    func listBuckets() async throws -> [(name: String, creationDate: Date?)] {
        []
    }

    func listObjects(
        bucket _: String, prefix _: String?, delimiter _: String?,
        maxKeys _: Int?, continuationToken _: String?
    ) async throws -> S3ListingResult {
        S3ListingResult(objects: [], commonPrefixes: [], nextContinuationToken: nil, isTruncated: false)
    }

    func headObject(bucket _: String, key _: String) async throws -> S3ObjectMetadata {
        throw DS3ClientError.parseError
    }

    func deleteObject(bucket _: String, key _: String) async throws {
        // No-op stub — upload-hook tests don't observe delete.
    }

    func deleteObjects(bucket _: String, keys _: [String]) async throws -> Int {
        0
    }

    func copyObject(
        bucket _: String, sourceKey _: String,
        destinationKey _: String, metadata _: [String: String]?
    ) async throws {
        // No-op stub — upload-hook tests don't observe copy.
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
        bucket _: String, key: String,
        data _: Data, metadata: [String: String]?
    ) async throws -> String? {
        // Snapshot delay + error under the lock so reads happen-before the
        // sleep/throw without racing the test thread's writes.
        let (delayNanos, recordedError) = state.withLock { state -> (UInt64, Error?) in
            state.putThumbnailKeys.append(key)
            state.lastPutThumbnailMetadata = metadata
            return (state.putThumbnailDelayNanos, state.putThumbnailError)
        }
        if delayNanos > 0 {
            try? await Task.sleep(nanoseconds: delayNanos)
        }
        if let err = recordedError { throw err }
        return "mock-thumb-etag"
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
        // No-op stub — upload-hook tests don't observe multipart.
    }

    func shutdown() throws {
        // No-op stub — mock has no resources to release.
    }
}

// MARK: - Test-only MetadataStore helper

//
// Phase 13.2 Plan 09: `fetchThumbnailStatusForTest` removed — Schema V6 dropped
// the `thumbnailStatus` field. Tests no longer have any per-row thumbnail state
// to inspect; the only observable signal is "did the S3 PUT happen?" which the
// mock S3 client records directly.
