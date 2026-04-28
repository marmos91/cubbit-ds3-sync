@testable import DS3Lib
import FileProvider
import Foundation
import XCTest

/// Tests the cache-first `consumeThumbnail` helper (Phase 13, Plan 13-06).
///
/// `consumeThumbnail` is a free function — testing it directly avoids needing
/// a real `FileProviderExtension` instance (which requires a domain, App Group
/// container, and a `DS3S3Client`). The fetch + mark-pending closures provide
/// dependency injection seams for the S3 client and metadata store.
final class FetchThumbnailsTests: XCTestCase {
    // MARK: - Test 1 — Raster HIT

    /// Cache HIT: bytes are returned via the per-item handler with no error.
    func testFetchThumbnailsRasterHitReturnsBytes() async {
        let drive = ProviderTestFixtures.makeDrive()
        let identifier = NSFileProviderItemIdentifier("prefix/photo.jpg")
        let payload = Data([0xFF, 0xD8, 0xFF, 0xE0]) // JPEG SOI marker (any non-empty Data works)
        let recorder = ResultRecorder()
        let pendingTracker = PendingTracker()

        let fetchBytes: ThumbnailByteFetcher = { _, _ in payload }
        let markPending: ThumbnailPendingMarker = { key, driveId in
            await pendingTracker.record(key: key, driveId: driveId)
        }

        await consumeThumbnail(
            identifier: identifier,
            drive: drive,
            fetchBytes: fetchBytes,
            markPending: markPending,
            perItemHandler: { id, data, error in
                Task { await recorder.record(id: id, data: data, error: error) }
            }
        )

        // Drain any pending Task work.
        try? await Task.sleep(nanoseconds: 30_000_000)

        let results = await recorder.results
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.identifier, identifier)
        XCTAssertEqual(results.first?.data, payload)
        XCTAssertNil(results.first?.error)
        let pendingCount = await pendingTracker.count
        XCTAssertEqual(pendingCount, 0, "HIT must not mark pending")
    }

    // MARK: - Test 2 — Raster MISS marks pending and returns .noSuchItem

    func testFetchThumbnailsRasterMissReturnsNoSuchItemAndMarksPending() async {
        let drive = ProviderTestFixtures.makeDrive()
        let identifier = NSFileProviderItemIdentifier("prefix/photo.jpg")
        let recorder = ResultRecorder()
        let pendingTracker = PendingTracker()

        let fetchBytes: ThumbnailByteFetcher = { _, _ in nil } // 404
        let markPending: ThumbnailPendingMarker = { key, driveId in
            await pendingTracker.record(key: key, driveId: driveId)
        }

        await consumeThumbnail(
            identifier: identifier,
            drive: drive,
            fetchBytes: fetchBytes,
            markPending: markPending,
            perItemHandler: { id, data, error in
                Task { await recorder.record(id: id, data: data, error: error) }
            }
        )

        try? await Task.sleep(nanoseconds: 30_000_000)

        let results = await recorder.results
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.identifier, identifier)
        XCTAssertNil(results.first?.data)
        let nsError = results.first?.error as NSError?
        XCTAssertNotNil(nsError)
        XCTAssertEqual(nsError?.domain, NSFileProviderErrorDomain)
        XCTAssertEqual(nsError?.code, NSFileProviderError(.noSuchItem).code.rawValue)

        let pending = await pendingTracker.entries
        XCTAssertEqual(pending.count, 1, "MISS must mark .pending exactly once")
        XCTAssertEqual(pending.first?.key, identifier.rawValue)
        XCTAssertEqual(pending.first?.driveId, drive.id)
    }

    // MARK: - Test 3 — Non-raster identifier returns (nil, nil) with no S3 call

    func testFetchThumbnailsNonRasterReturnsNilNoError() async {
        let drive = ProviderTestFixtures.makeDrive()
        let identifier = NSFileProviderItemIdentifier("prefix/document.pdf")
        let recorder = ResultRecorder()
        let pendingTracker = PendingTracker()
        let fetchCounter = CallCounter()

        let fetchBytes: ThumbnailByteFetcher = { _, _ in
            await fetchCounter.increment()
            return Data()
        }
        let markPending: ThumbnailPendingMarker = { key, driveId in
            await pendingTracker.record(key: key, driveId: driveId)
        }

        await consumeThumbnail(
            identifier: identifier,
            drive: drive,
            fetchBytes: fetchBytes,
            markPending: markPending,
            perItemHandler: { id, data, error in
                Task { await recorder.record(id: id, data: data, error: error) }
            }
        )

        try? await Task.sleep(nanoseconds: 30_000_000)

        let results = await recorder.results
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.identifier, identifier)
        XCTAssertNil(results.first?.data)
        XCTAssertNil(results.first?.error)
        let calls = await fetchCounter.count
        XCTAssertEqual(calls, 0, "Non-raster must not call fetchBytes")
        let pendingCount = await pendingTracker.count
        XCTAssertEqual(pendingCount, 0, "Non-raster must not mark .pending")
    }

    // MARK: - Test 4 — Folder identifier returns (nil, nil)

    func testFetchThumbnailsFolderIdentifierReturnsNilNoError() async {
        let drive = ProviderTestFixtures.makeDrive()
        let folderIdentifier = NSFileProviderItemIdentifier("prefix/folder/")
        let recorder = ResultRecorder()
        let pendingTracker = PendingTracker()
        let fetchCounter = CallCounter()

        let fetchBytes: ThumbnailByteFetcher = { _, _ in
            await fetchCounter.increment()
            return Data()
        }
        let markPending: ThumbnailPendingMarker = { key, driveId in
            await pendingTracker.record(key: key, driveId: driveId)
        }

        await consumeThumbnail(
            identifier: folderIdentifier,
            drive: drive,
            fetchBytes: fetchBytes,
            markPending: markPending,
            perItemHandler: { id, data, error in
                Task { await recorder.record(id: id, data: data, error: error) }
            }
        )

        // Also test root container.
        await consumeThumbnail(
            identifier: .rootContainer,
            drive: drive,
            fetchBytes: fetchBytes,
            markPending: markPending,
            perItemHandler: { id, data, error in
                Task { await recorder.record(id: id, data: data, error: error) }
            }
        )

        try? await Task.sleep(nanoseconds: 30_000_000)

        let results = await recorder.results
        XCTAssertEqual(results.count, 2)
        for result in results {
            XCTAssertNil(result.data)
            XCTAssertNil(result.error)
        }
        let calls = await fetchCounter.count
        XCTAssertEqual(calls, 0, "Folder/root must not call fetchBytes")
        let pendingCount = await pendingTracker.count
        XCTAssertEqual(pendingCount, 0, "Folder/root must not mark .pending")
    }

    // MARK: - Test 5 — Limiter caps concurrent S3 GETs at 4

    /// 8 concurrent consume invocations through a 4-slot limiter must never
    /// exceed 4 in-flight S3 GETs at once. The fetcher closure increments a
    /// counter on entry, sleeps, decrements on exit; the test asserts the
    /// observed maximum is exactly 4.
    func testFetchThumbnailsBoundedByLimiter() async {
        let drive = ProviderTestFixtures.makeDrive()
        let limiter = ThumbnailFetchLimiter(maxSlots: 4)
        let recorder = ResultRecorder()
        let pendingTracker = PendingTracker()
        let inFlight = ConcurrencyMaxObserver()

        let fetchBytes: ThumbnailByteFetcher = { _, _ in
            await inFlight.enter()
            try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
            await inFlight.exit()
            return Data([0xAA])
        }
        let markPending: ThumbnailPendingMarker = { key, driveId in
            await pendingTracker.record(key: key, driveId: driveId)
        }

        let identifiers: [NSFileProviderItemIdentifier] = (0 ..< 8).map { idx in
            NSFileProviderItemIdentifier("prefix/photo_\(idx).jpg")
        }

        await withTaskGroup(of: Void.self) { group in
            for identifier in identifiers {
                group.addTask {
                    do { try await limiter.acquire() } catch { return }
                    await consumeThumbnail(
                        identifier: identifier,
                        drive: drive,
                        fetchBytes: fetchBytes,
                        markPending: markPending,
                        perItemHandler: { id, data, error in
                            Task { await recorder.record(id: id, data: data, error: error) }
                        }
                    )
                    await limiter.release()
                }
            }
        }

        try? await Task.sleep(nanoseconds: 50_000_000)

        let observedMax = await inFlight.observedMax
        XCTAssertLessThanOrEqual(observedMax, 4, "Limiter must cap consume concurrency at 4")
        let results = await recorder.results
        XCTAssertEqual(results.count, 8)
    }

    // MARK: - Test 6 — Consume path NEVER renders

    /// We cannot directly mock the renderer (it's a concrete macOS type), but
    /// we can prove the consume path doesn't render by:
    ///   1. Asserting `consumeThumbnail` ONLY invokes `fetchBytes` (no other
    ///      injection point exists for downloading or rendering).
    ///   2. Asserting that on a HIT the bytes returned are EXACTLY the bytes
    ///      from `fetchBytes` (not re-encoded JPEG bytes from a renderer).
    /// If `consumeThumbnail` ever started downloading the original + rendering,
    /// a fresh DI seam would have to be added — this test would fail to compile,
    /// flagging the regression.
    func testFetchThumbnailsDoesNotInvokeRendererOnConsumePath() async {
        let drive = ProviderTestFixtures.makeDrive()
        let identifier = NSFileProviderItemIdentifier("prefix/photo.jpg")
        let sentinelBytes = Data("CACHE-SENTINEL-NOT-RENDERED".utf8)
        let recorder = ResultRecorder()
        let pendingTracker = PendingTracker()

        let fetchBytes: ThumbnailByteFetcher = { _, _ in sentinelBytes }
        let markPending: ThumbnailPendingMarker = { key, driveId in
            await pendingTracker.record(key: key, driveId: driveId)
        }

        await consumeThumbnail(
            identifier: identifier,
            drive: drive,
            fetchBytes: fetchBytes,
            markPending: markPending,
            perItemHandler: { id, data, error in
                Task { await recorder.record(id: id, data: data, error: error) }
            }
        )

        try? await Task.sleep(nanoseconds: 30_000_000)

        let results = await recorder.results
        XCTAssertEqual(
            results.first?.data,
            sentinelBytes,
            "Consume path must return EXACT cache bytes — any renderer re-encode would change the bytes"
        )
    }
}

// MARK: - Test recording helpers

struct RecordedThumbnailResult {
    let identifier: NSFileProviderItemIdentifier
    let data: Data?
    let error: Error?
}

actor ResultRecorder {
    private(set) var results: [RecordedThumbnailResult] = []

    func record(id: NSFileProviderItemIdentifier, data: Data?, error: Error?) {
        results.append(RecordedThumbnailResult(identifier: id, data: data, error: error))
    }
}

struct PendingEntry {
    let key: String
    let driveId: UUID
}

actor PendingTracker {
    private(set) var entries: [PendingEntry] = []

    func record(key: String, driveId: UUID) {
        entries.append(PendingEntry(key: key, driveId: driveId))
    }

    var count: Int {
        entries.count
    }
}

actor CallCounter {
    private(set) var count: Int = 0

    func increment() {
        count += 1
    }
}

actor ConcurrencyMaxObserver {
    private(set) var current: Int = 0
    private(set) var observedMax: Int = 0

    func enter() {
        current += 1
        if current > observedMax { observedMax = current }
    }

    func exit() {
        current -= 1
    }
}
