@testable import DS3Lib
import Foundation
import os
import XCTest

/// Tests for the silent launch-time thumbnail rollout (Phase 13 D-01, D-02, D-03;
/// THUMB-23; Plan 13-10).
///
/// `ThumbnailRollout` runs once per drive on extension launch:
///   • If `SharedData.hasThumbnailSettings(forDrive:)` returns true → no-op (D-02).
///   • Otherwise call `inspectThumbnailPrefix`:
///       - `.empty` / `.matchesOurs` → persist `enabled = true`
///       - `.conflicting` → persist `enabled = false`
///   • Errors from `inspectThumbnailPrefix` are logged + swallowed (D-03);
///     no settings file is written, so the next launch retries.
///
/// We exercise the rollout against an in-process `RolloutMockS3Client` and
/// `RolloutMockSettingsStore` (a tiny seam mirroring `SharedData`'s relevant
/// methods) — the production `SharedData` reads/writes the App Group container
/// which isn't available in the SPM test runner. The persistence contract is
/// covered by `SharedDataThumbnailSettingsTests`.
final class ThumbnailRolloutTests: XCTestCase {
    // MARK: - Helpers

    private func makeLogger() -> os.Logger {
        os.Logger(subsystem: "io.cubbit.DS3Drive.tests", category: "rollout")
    }

    private func makeDrive(prefix: String? = "prefix/") -> DS3Drive {
        ProviderTestFixtures.makeDrive(prefix: prefix)
    }

    // MARK: - Test 4 — first launch, .empty → enabled = true persisted

    func testFirstLaunchEnablesDriveOnEmptyPrefix() async {
        let drive = makeDrive()
        let mock = RolloutMockS3Client()
        mock.inspectResult = .empty
        let store = RolloutMockSettingsStore()

        let rollout = ThumbnailRollout(
            s3Client: mock, settingsStore: store, logger: makeLogger()
        )
        await rollout.runIfNeeded(forDrive: drive)

        XCTAssertEqual(mock.inspectInvocations, 1, "First launch must call inspectThumbnailPrefix once")
        let saved = store.savedSettings(forDrive: drive.id)
        XCTAssertNotNil(saved, ".empty must persist a settings entry")
        XCTAssertEqual(saved?.enabled, true, ".empty → enabled = true (D-01)")
    }

    // MARK: - Test 5 — first launch, .matchesOurs → enabled = true persisted

    func testFirstLaunchEnablesDriveOnMatchesOurs() async {
        let drive = makeDrive()
        let mock = RolloutMockS3Client()
        mock.inspectResult = .matchesOurs
        let store = RolloutMockSettingsStore()

        let rollout = ThumbnailRollout(
            s3Client: mock, settingsStore: store, logger: makeLogger()
        )
        await rollout.runIfNeeded(forDrive: drive)

        XCTAssertEqual(mock.inspectInvocations, 1)
        XCTAssertEqual(
            store.savedSettings(forDrive: drive.id)?.enabled, true,
            ".matchesOurs → enabled = true (D-01)"
        )
    }

    // MARK: - Test 6 — first launch, .conflicting → enabled = false persisted

    func testFirstLaunchDisablesDriveOnConflicting() async {
        let drive = makeDrive()
        let mock = RolloutMockS3Client()
        mock.inspectResult = .conflicting(sampleKey: "prefix/.thumbnails/foreign.bin")
        let store = RolloutMockSettingsStore()

        let rollout = ThumbnailRollout(
            s3Client: mock, settingsStore: store, logger: makeLogger()
        )
        await rollout.runIfNeeded(forDrive: drive)

        XCTAssertEqual(mock.inspectInvocations, 1)
        let saved = store.savedSettings(forDrive: drive.id)
        XCTAssertNotNil(saved, ".conflicting must STILL persist (so subsequent launches skip re-check)")
        XCTAssertEqual(saved?.enabled, false, ".conflicting → enabled = false (D-01)")
    }

    // MARK: - Test 7 — already persisted → re-check skipped

    func testSecondLaunchSkipsRecheckIfAlreadyPersisted() async {
        let drive = makeDrive()
        let mock = RolloutMockS3Client()
        mock.inspectResult = .empty // would enable if invoked
        let store = RolloutMockSettingsStore()

        // Pre-persist a settings entry — simulating a prior launch.
        store.preSeed(driveId: drive.id, settings: ThumbnailSettings(enabled: false))

        let rollout = ThumbnailRollout(
            s3Client: mock, settingsStore: store, logger: makeLogger()
        )
        await rollout.runIfNeeded(forDrive: drive)

        XCTAssertEqual(
            mock.inspectInvocations, 0,
            "Already-persisted drive MUST NOT re-call inspectThumbnailPrefix (D-02 once-per-drive guard)"
        )
        XCTAssertEqual(
            store.savedSettings(forDrive: drive.id)?.enabled, false,
            "Pre-existing entry must not be overwritten"
        )
    }

    // MARK: - Test 8 — multiple drives, all-new → each gets its own rollout

    func testRolloutHandlesMultipleDrives() async {
        let driveA = makeDrive(prefix: "a/")
        let driveB = makeDrive(prefix: "b/")
        let driveC = makeDrive(prefix: "c/")
        let mock = RolloutMockS3Client()
        mock.inspectResult = .empty
        let store = RolloutMockSettingsStore()
        let rollout = ThumbnailRollout(
            s3Client: mock, settingsStore: store, logger: makeLogger()
        )

        await rollout.runIfNeeded(forDrive: driveA)
        await rollout.runIfNeeded(forDrive: driveB)
        await rollout.runIfNeeded(forDrive: driveC)

        XCTAssertEqual(mock.inspectInvocations, 3, "One inspect per drive")
        XCTAssertEqual(store.savedSettings(forDrive: driveA.id)?.enabled, true)
        XCTAssertEqual(store.savedSettings(forDrive: driveB.id)?.enabled, true)
        XCTAssertEqual(store.savedSettings(forDrive: driveC.id)?.enabled, true)
    }

    // MARK: - Test 9 — error path: no file written, retry next launch

    func testRolloutSwallowsInspectThumbnailPrefixError() async {
        let driveA = makeDrive(prefix: "a/")
        let driveB = makeDrive(prefix: "b/")
        let mockA = RolloutMockS3Client()
        mockA.inspectError = NSError(domain: "TestNetwork", code: -1, userInfo: nil)
        let mockB = RolloutMockS3Client()
        mockB.inspectResult = .empty

        let store = RolloutMockSettingsStore()

        let rolloutA = ThumbnailRollout(
            s3Client: mockA, settingsStore: store, logger: makeLogger()
        )
        let rolloutB = ThumbnailRollout(
            s3Client: mockB, settingsStore: store, logger: makeLogger()
        )

        await rolloutA.runIfNeeded(forDrive: driveA)
        await rolloutB.runIfNeeded(forDrive: driveB)

        XCTAssertNil(
            store.savedSettings(forDrive: driveA.id),
            "Drive A error → NO settings file written (will retry next launch)"
        )
        XCTAssertEqual(
            store.savedSettings(forDrive: driveB.id)?.enabled, true,
            "Drive B succeeds independently"
        )
    }

    // MARK: - Test 10 — launch-time invocation does not block (background Task)

    /// `runIfNeeded` is a regular async function — the FileProviderExtension+Lifecycle
    /// hook wraps it in `Task.detached` so the launch path doesn't await it. This
    /// test asserts the lifecycle invariant by simulating the wrap-and-return pattern:
    /// the surrounding sync function MUST return promptly even when the rollout's
    /// `inspectThumbnailPrefix` is artificially slow.
    func testRolloutRunsInBackgroundDoesNotBlockLaunch() async {
        let drive = makeDrive()
        let mock = RolloutMockS3Client()
        mock.inspectResult = .empty
        mock.inspectDelayNanos = 500_000_000 // 500ms — would block synchronous launch
        let store = RolloutMockSettingsStore()
        let rollout = ThumbnailRollout(
            s3Client: mock, settingsStore: store, logger: makeLogger()
        )

        // Mirror the lifecycle hook's pattern: spawn detached, return immediately.
        let start = DispatchTime.now()
        let detached: Task<Void, Never> = Task.detached {
            await rollout.runIfNeeded(forDrive: drive)
        }
        let elapsedNanos = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds

        // The lifecycle caller must complete in well under 50ms even with a 500ms inspect.
        XCTAssertLessThan(
            elapsedNanos, 50_000_000,
            "Lifecycle hook MUST spawn-and-return — never block launch on inspectThumbnailPrefix latency (D-01 background)"
        )

        // Drain so subsequent assertions see the persisted state.
        await detached.value
        XCTAssertEqual(store.savedSettings(forDrive: drive.id)?.enabled, true)
    }
}

// MARK: - RolloutMockS3Client

/// Mock `DS3S3ClientProtocol` for rollout tests. Only the methods that matter for
/// `inspectThumbnailPrefix` (which dispatches via `listObjects`) need real behavior;
/// the others are no-op stubs. We inject canned `ThumbnailPrefixState` values via
/// the `inspectResult` knob, which the mock returns from `listObjects` shaped to
/// match what `inspectThumbnailPrefix` expects.
final class RolloutMockS3Client: DS3S3ClientProtocol, @unchecked Sendable {
    private struct State {
        var inspectInvocations: Int = 0
    }

    private let stateLock = OSAllocatedUnfairLock(initialState: State())

    /// Recorded number of `listObjects` calls under a `.thumbnails/` prefix
    /// (these are what `inspectThumbnailPrefix` issues).
    var inspectInvocations: Int {
        stateLock.withLock { $0.inspectInvocations }
    }

    /// Canned outcome to be translated into a `listObjects` response.
    var inspectResult: ThumbnailPrefixState = .empty

    /// If set, `listObjects` throws this. Used to test the swallow-and-skip path.
    var inspectError: Error?

    /// Artificial latency on `listObjects` to simulate slow networks.
    var inspectDelayNanos: UInt64 = 0

    func listBuckets() async throws -> [(name: String, creationDate: Date?)] {
        []
    }

    func listObjects(
        bucket _: String,
        prefix: String?,
        delimiter _: String?,
        maxKeys _: Int?,
        continuationToken _: String?
    ) async throws -> S3ListingResult {
        // Only count calls whose prefix targets `.thumbnails/` — that's what
        // inspectThumbnailPrefix issues. Other paths shouldn't happen in these
        // tests, but guarding keeps the assertion precise.
        if let prefix, prefix.contains(".thumbnails/") {
            stateLock.withLock { $0.inspectInvocations += 1 }
        }

        if inspectDelayNanos > 0 {
            try? await Task.sleep(nanoseconds: inspectDelayNanos)
        }
        if let inspectError {
            throw inspectError
        }

        switch inspectResult {
        case .empty:
            return S3ListingResult(
                objects: [], commonPrefixes: [], nextContinuationToken: nil, isTruncated: false
            )
        case .matchesOurs:
            // Return one object that matches the DS3Drive thumbnail layout
            // (`<prefix>.thumbnails/foo.jpg.jpg`) so inspectThumbnailPrefix's
            // suffix + extension allow-list returns .matchesOurs.
            let key = (prefix ?? "") + "image.jpg.jpg"
            return S3ListingResult(
                objects: [
                    S3ObjectSummary(key: key, etag: "etag", lastModified: Date(), size: 1234)
                ],
                commonPrefixes: [],
                nextContinuationToken: nil,
                isTruncated: false
            )
        case .conflicting:
            // Return an object that violates the DS3Drive layout: lacks the
            // `.jpg` suffix entirely (a foreign tool wrote it).
            let key = (prefix ?? "") + "foreign.bin"
            return S3ListingResult(
                objects: [
                    S3ObjectSummary(key: key, etag: "etag", lastModified: Date(), size: 1234)
                ],
                commonPrefixes: [],
                nextContinuationToken: nil,
                isTruncated: false
            )
        }
    }

    func headObject(bucket _: String, key _: String) async throws -> S3ObjectMetadata {
        throw DS3ClientError.parseError
    }

    func deleteObject(bucket _: String, key _: String) async throws {
        // No-op stub — rollout tests don't observe delete.
    }

    func deleteObjects(bucket _: String, keys _: [String]) async throws -> Int {
        0
    }

    func copyObject(
        bucket _: String, sourceKey _: String,
        destinationKey _: String, metadata _: [String: String]?
    ) async throws {
        // No-op stub — rollout tests don't observe copy.
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
        nil
    }

    func putObjectData(
        bucket _: String, key _: String,
        data _: Data, metadata _: [String: String]?
    ) async throws -> String? {
        nil
    }

    func createMultipartUpload(bucket _: String, key _: String) async throws -> String {
        "id"
    }

    func uploadPart(
        bucket _: String, key _: String, uploadId _: String,
        partNumber: Int, data _: Data
    ) async throws -> CompletedPartResult {
        CompletedPartResult(partNumber: partNumber, etag: "e")
    }

    func completeMultipartUpload(
        bucket _: String, key _: String, uploadId _: String,
        parts _: [(partNumber: Int, etag: String)]
    ) async throws -> MultipartCompleteResult {
        MultipartCompleteResult(etag: "e")
    }

    func abortMultipartUpload(bucket _: String, key _: String, uploadId _: String) async throws {
        // No-op stub — rollout tests don't observe multipart.
    }

    func shutdown() throws {
        // No-op stub — mock has no resources to release.
    }
}

// MARK: - RolloutMockSettingsStore

/// In-memory mock that mirrors the `ThumbnailSettings` persistence surface
/// `ThumbnailRollout` consumes. Production injects a real `SharedData`; tests
/// inject this so the rollout can be exercised without an App Group container.
final class RolloutMockSettingsStore: ThumbnailSettingsStoring, @unchecked Sendable {
    private struct State {
        var settingsByDriveId: [UUID: ThumbnailSettings] = [:]
    }

    private let stateLock = OSAllocatedUnfairLock(initialState: State())

    func preSeed(driveId: UUID, settings: ThumbnailSettings) {
        stateLock.withLock { $0.settingsByDriveId[driveId] = settings }
    }

    func savedSettings(forDrive driveId: UUID) -> ThumbnailSettings? {
        stateLock.withLock { $0.settingsByDriveId[driveId] }
    }

    // MARK: ThumbnailSettingsStoring

    func hasThumbnailSettings(forDrive driveId: UUID) -> Bool {
        stateLock.withLock { $0.settingsByDriveId[driveId] != nil }
    }

    func saveThumbnailSettings(forDrive driveId: UUID, settings: ThumbnailSettings) throws {
        stateLock.withLock { $0.settingsByDriveId[driveId] = settings }
    }
}
