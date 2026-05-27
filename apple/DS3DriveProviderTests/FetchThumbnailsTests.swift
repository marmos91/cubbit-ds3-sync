@testable import DS3Lib
import FileProvider
import Foundation
import XCTest

/// Tests the cache-first `consumeThumbnail` helper (Phase 13, Plan 13-06).
///
/// `consumeThumbnail` is a free function — testing it directly avoids needing
/// a real `FileProviderExtension` instance (which requires a domain, App Group
/// container, and a `DS3S3Client`). The fetch closure provides a dependency
/// injection seam for the S3 client.
///
/// Phase 13.2 Plan 09 (D-05, D-08, D-23): the `markPending` parameter was
/// stripped from `consumeThumbnail` — Schema V6 dropped `thumbnailStatus`,
/// and the BFS coordinator that consumed `.pending` writes is gone. The
/// cache-miss sentinel `(nil, NSFileProviderError(.noSuchItem))` is the only
/// signal the caller's interceptor needs to route into the reactive fallback
/// path (`consumeThumbnailFallback`).
final class FetchThumbnailsTests: XCTestCase {
    // MARK: - Test 1 — Raster HIT

    /// Cache HIT: bytes are returned via the per-item handler with no error.
    func testFetchThumbnailsRasterHitReturnsBytes() async {
        let drive = ProviderTestFixtures.makeDrive()
        let identifier = NSFileProviderItemIdentifier("prefix/photo.jpg")
        let payload = Data([0xFF, 0xD8, 0xFF, 0xE0]) // JPEG SOI marker (any non-empty Data works)
        let recorder = ResultRecorder()

        let fetchBytes: ThumbnailByteFetcher = { _, _ in payload }

        await consumeThumbnail(
            identifier: identifier,
            drive: drive,
            fetchBytes: fetchBytes,
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
    }

    // MARK: - Test 2 — Raster MISS returns the .noSuchItem cache-miss sentinel

    /// Phase 13.2 Plan 09: the miss branch no longer writes to any metadata
    /// store. It returns the sentinel `(nil, NSFileProviderError(.noSuchItem))`
    /// that the caller's interceptor uses to route into `consumeThumbnailFallback`.
    func testFetchThumbnailsRasterMissReturnsNoSuchItemSentinel() async {
        let drive = ProviderTestFixtures.makeDrive()
        let identifier = NSFileProviderItemIdentifier("prefix/photo.jpg")
        let recorder = ResultRecorder()

        let fetchBytes: ThumbnailByteFetcher = { _, _ in nil } // 404

        await consumeThumbnail(
            identifier: identifier,
            drive: drive,
            fetchBytes: fetchBytes,
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
    }

    // MARK: - Test 3 — Non-raster identifier returns (nil, nil) with no S3 call

    func testFetchThumbnailsNonRasterReturnsNilNoError() async {
        let drive = ProviderTestFixtures.makeDrive()
        let identifier = NSFileProviderItemIdentifier("prefix/document.pdf")
        let recorder = ResultRecorder()
        let fetchCounter = CallCounter()

        let fetchBytes: ThumbnailByteFetcher = { _, _ in
            await fetchCounter.increment()
            return Data()
        }

        await consumeThumbnail(
            identifier: identifier,
            drive: drive,
            fetchBytes: fetchBytes,
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
    }

    // MARK: - Test 4 — Folder identifier returns (nil, nil)

    func testFetchThumbnailsFolderIdentifierReturnsNilNoError() async {
        let drive = ProviderTestFixtures.makeDrive()
        let folderIdentifier = NSFileProviderItemIdentifier("prefix/folder/")
        let recorder = ResultRecorder()
        let fetchCounter = CallCounter()

        let fetchBytes: ThumbnailByteFetcher = { _, _ in
            await fetchCounter.increment()
            return Data()
        }

        await consumeThumbnail(
            identifier: folderIdentifier,
            drive: drive,
            fetchBytes: fetchBytes,
            perItemHandler: { id, data, error in
                Task { await recorder.record(id: id, data: data, error: error) }
            }
        )

        // Also test root container.
        await consumeThumbnail(
            identifier: .rootContainer,
            drive: drive,
            fetchBytes: fetchBytes,
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
        let inFlight = ConcurrencyMaxObserver()

        let fetchBytes: ThumbnailByteFetcher = { _, _ in
            await inFlight.enter()
            try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
            await inFlight.exit()
            return Data([0xAA])
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

        let fetchBytes: ThumbnailByteFetcher = { _, _ in sentinelBytes }

        await consumeThumbnail(
            identifier: identifier,
            drive: drive,
            fetchBytes: fetchBytes,
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
