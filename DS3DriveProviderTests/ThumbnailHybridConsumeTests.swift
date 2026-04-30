@testable import DS3Lib
import FileProvider
import Foundation
import os.log
import XCTest

/// Tests the Phase 13.2 cache-miss fallback fork in `fetchThumbnails`
/// (D-01..D-04, D-12, D-19, D-20, D-24, THUMB-15, THUMB-21).
///
/// Test strategy: `consumeThumbnailFallback` is a free function with closure-
/// based dependency injection (mirrors the cache-only `consumeThumbnail` test
/// pattern in `FetchThumbnailsTests.swift`). Each test wires fake closures for
/// the original-download, render, S3 PUT, pause-gate, and signalEnumerator
/// seams; assertions check that bytes flow to Finder, the detached PUT fires
/// after the per-item handler, the parent container is signalled, and the
/// pause/poison short-circuits skip download+render entirely.
///
/// Production code in `+Thumbnails.swift` wires these closures to the real
/// `S3Lib.downloadS3Item`, `ThumbnailRenderer.renderJPEG`, `s3Client.putThumbnail`,
/// `manager.signalEnumerator(for:)`.
final class ThumbnailHybridConsumeTests: XCTestCase {
    // MARK: - Test 1 — Cache miss → render → bytes to Finder → background PUT

    /// D-01 lane 2 + lane 3 + D-04: the bytes returned to Finder are the SAME
    /// bytes PUT to S3. Single render, no re-encode.
    func test_cacheMiss_rendersOriginal_returnsBytes_thenPutsToS3() async throws {
        let drive = ProviderTestFixtures.makeDrive()
        let identifier = NSFileProviderItemIdentifier("prefix/photo.heic")
        let renderedBytes = Data("RENDERED-JPEG-BYTES".utf8)
        let recorder = ResultRecorder()
        let putRecorder = PutRecorder()
        let signalRecorder = SignalRecorder()
        let sourceETag = "\"abc123etag\""

        let downloadURL = try Self.makeFakeDownloadFile()
        defer { try? FileManager.default.removeItem(at: downloadURL) }

        let context = Self.makeContext(
            download: { _, _ in (downloadURL, sourceETag) },
            render: { _ in .success(renderedBytes) },
            putThumbnail: { bucket, key, data, etag in
                await putRecorder.record(bucket: bucket, key: key, data: data, etag: etag)
            },
            signalParentContainer: { id in
                Task { await signalRecorder.record(id) }
            }
        )

        await consumeThumbnailFallback(
            identifier: identifier,
            drive: drive,
            context: context,
            perItemHandler: { id, data, error in
                Task { await recorder.record(id: id, data: data, error: error) }
            }
        )

        // Drain the per-item handler Task and the detached PUT Task.
        try await Self.drainBackgroundTasks()

        let results = await recorder.results
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.identifier, identifier)
        XCTAssertEqual(
            results.first?.data,
            renderedBytes,
            "D-04: bytes returned to Finder must equal rendered bytes"
        )
        XCTAssertNil(results.first?.error)

        let puts = await putRecorder.entries
        XCTAssertEqual(puts.count, 1, "Lane 3: exactly one detached PUT")
        XCTAssertEqual(puts.first?.bucket, drive.syncAnchor.bucket.name)
        XCTAssertEqual(
            puts.first?.data,
            renderedBytes,
            "D-04: bytes PUT to S3 must equal bytes returned to Finder"
        )
        XCTAssertEqual(puts.first?.etag, sourceETag)
    }

    // MARK: - Test 2 — Post-PUT signalEnumerator(for: parentContainer) (D-12)

    func test_postPutSignalsEnumerator() async throws {
        let drive = ProviderTestFixtures.makeDrive(prefix: "drive/")
        let identifier = NSFileProviderItemIdentifier("drive/folder/photo.jpg")
        let renderedBytes = Data([0xFF, 0xD8, 0xFF])
        let recorder = ResultRecorder()
        let signalRecorder = SignalRecorder()
        let downloadURL = try Self.makeFakeDownloadFile()
        defer { try? FileManager.default.removeItem(at: downloadURL) }

        let context = Self.makeContext(
            download: { _, _ in (downloadURL, "etag") },
            render: { _ in .success(renderedBytes) },
            signalParentContainer: { id in
                Task { await signalRecorder.record(id) }
            }
        )

        await consumeThumbnailFallback(
            identifier: identifier,
            drive: drive,
            context: context,
            perItemHandler: { id, data, error in
                Task { await recorder.record(id: id, data: data, error: error) }
            }
        )

        try await Self.drainBackgroundTasks()

        let signalled = await signalRecorder.identifiers
        XCTAssertEqual(signalled.count, 1, "D-12: exactly one signalEnumerator after successful PUT")
        // Parent of "drive/folder/photo.jpg" with prefix "drive/" is "drive/folder/".
        XCTAssertEqual(signalled.first?.rawValue, "drive/folder/")
    }

    // MARK: - Test 4 — Poisoned key short-circuits before slot acquisition

    /// D-19, D-20: a poisoned key skips download + render entirely. Returns
    /// (nil, nil) so Finder draws the default icon.
    func test_poisonedKeySkipsFallback() async throws {
        let drive = ProviderTestFixtures.makeDrive()
        let identifier = NSFileProviderItemIdentifier("prefix/poisoned.heic")
        let recorder = ResultRecorder()
        let downloadCounter = CallCounter()
        let limiter = ThumbnailFallbackLimiter()

        // Poison the key (3 strikes).
        await limiter.recordFailure(identifier.rawValue)
        await limiter.recordFailure(identifier.rawValue)
        await limiter.recordFailure(identifier.rawValue)
        let isPoisoned = await limiter.isPoisoned(identifier.rawValue)
        XCTAssertTrue(isPoisoned, "precondition: 3 strikes must poison key")

        let context = Self.makeContext(
            limiter: limiter,
            download: { _, _ in
                await downloadCounter.increment()
                return (URL(fileURLWithPath: "/tmp/never"), nil)
            },
            render: { _ in .success(Data()) }
        )

        await consumeThumbnailFallback(
            identifier: identifier,
            drive: drive,
            context: context,
            perItemHandler: { id, data, error in
                Task { await recorder.record(id: id, data: data, error: error) }
            }
        )

        try await Self.drainBackgroundTasks()

        let results = await recorder.results
        XCTAssertEqual(results.count, 1)
        XCTAssertNil(results.first?.data)
        XCTAssertNil(results.first?.error, "Poisoned key must surface (nil, nil)")
        let downloads = await downloadCounter.count
        XCTAssertEqual(downloads, 0, "Poisoned key must not download")

        let inFlight = await limiter.inFlightCount
        XCTAssertEqual(inFlight, 0, "Poisoned key must not acquire a slot")
    }

    // MARK: - Test 5 — Three render failures poison the key

    /// D-19, D-20: render returning nil increments the strike counter; after
    /// the third strike the key is in the poison set and the next call
    /// short-circuits.
    func test_threeRenderFailures_poisonsKey() async throws {
        let drive = ProviderTestFixtures.makeDrive()
        let identifier = NSFileProviderItemIdentifier("prefix/corrupt.heic")
        let limiter = ThumbnailFallbackLimiter()
        let downloadCounter = CallCounter()
        let downloadURL = try Self.makeFakeDownloadFile()
        defer { try? FileManager.default.removeItem(at: downloadURL) }

        // Run three fallback attempts; each renders nil → records a strike.
        let strikeContext = Self.makeContext(
            limiter: limiter,
            download: { _, _ in
                await downloadCounter.increment()
                return (downloadURL, nil)
            },
            render: { _ in .failure(.thumbnailCreate) } // unsupported / corrupt
        )
        for _ in 0 ..< 3 {
            await consumeThumbnailFallback(
                identifier: identifier,
                drive: drive,
                context: strikeContext,
                perItemHandler: { _, _, _ in
                    // Test 5 only inspects the limiter's strike + poison state.
                }
            )
        }

        try await Self.drainBackgroundTasks()
        let countAfterThreeStrikes = await downloadCounter.count
        XCTAssertEqual(countAfterThreeStrikes, 3, "Three strikes require three downloads")

        let isPoisoned = await limiter.isPoisoned(identifier.rawValue)
        XCTAssertTrue(isPoisoned, "Third render failure must poison the key")

        // Fourth attempt: must short-circuit BEFORE download.
        let postPoisonContext = Self.makeContext(
            limiter: limiter,
            download: { _, _ in
                await downloadCounter.increment()
                return (downloadURL, nil)
            },
            render: { _ in .success(Data()) }
        )
        await consumeThumbnailFallback(
            identifier: identifier,
            drive: drive,
            context: postPoisonContext,
            perItemHandler: { _, _, _ in
                // Test 5 only verifies the download counter remains stable.
            }
        )

        try await Self.drainBackgroundTasks()
        let finalCount = await downloadCounter.count
        XCTAssertEqual(finalCount, 3, "Fourth attempt must short-circuit before download")
    }

    // MARK: - Test 6 — Failed PUT does NOT record a strike

    /// PUT failures are non-fatal — the user already saw a thumbnail. The
    /// failure is logged via `describeSotoError` (verified indirectly: the
    /// test passes a closure that throws, the function does not crash, and
    /// the strike counter remains at 0 because `recordFailure` is only called
    /// when the render fails — never when the detached PUT fails).
    func test_putFailure_doesNotRecordStrike() async throws {
        let drive = ProviderTestFixtures.makeDrive()
        let identifier = NSFileProviderItemIdentifier("prefix/photo.jpg")
        let renderedBytes = Data([0xAA, 0xBB])
        let recorder = ResultRecorder()
        let limiter = ThumbnailFallbackLimiter()
        let downloadURL = try Self.makeFakeDownloadFile()
        defer { try? FileManager.default.removeItem(at: downloadURL) }

        struct PutNetworkError: Error {}

        let context = Self.makeContext(
            limiter: limiter,
            download: { _, _ in (downloadURL, "etag") },
            render: { _ in .success(renderedBytes) },
            putThumbnail: { _, _, _, _ in throw PutNetworkError() }
        )
        await consumeThumbnailFallback(
            identifier: identifier,
            drive: drive,
            context: context,
            perItemHandler: { id, data, error in
                Task { await recorder.record(id: id, data: data, error: error) }
            }
        )

        try await Self.drainBackgroundTasks()

        // Per-item handler still received bytes (lane 2 fired before the PUT).
        let results = await recorder.results
        XCTAssertEqual(
            results.first?.data,
            renderedBytes,
            "Lane 2 byte delivery must precede lane 3 PUT failure"
        )

        // Strike counter must NOT have advanced — render succeeded, only PUT failed.
        let strikes = await limiter.strikeCountForTest(identifier.rawValue)
        XCTAssertEqual(strikes, 0, "Failed PUT must NOT record a strike (user already saw thumbnail)")
        let isPoisoned = await limiter.isPoisoned(identifier.rawValue)
        XCTAssertFalse(isPoisoned)
    }

    // MARK: - Test 7 — Errors returned to handler are NSFileProviderErrorDomain only

    /// THUMB-13: every error crossing the FP boundary must be in
    /// `NSFileProviderErrorDomain` or `NSCocoaErrorDomain`. Custom error types
    /// (e.g., Soto's) trigger `Provider returned error 0 from domain ... which
    /// is unsupported`. Verified by routing a download failure through the
    /// fallback path and asserting on the `.domain` of the returned NSError.
    func test_errorsReturnedAreNSFileProviderErrorDomainOnly() async throws {
        let drive = ProviderTestFixtures.makeDrive()
        let identifier = NSFileProviderItemIdentifier("prefix/photo.jpg")
        let recorder = ResultRecorder()

        struct CustomDomainError: Error {}

        let context = Self.makeContext(
            download: { _, _ in throw CustomDomainError() }, // download fails
            render: { _ in .success(Data()) }
        )
        await consumeThumbnailFallback(
            identifier: identifier,
            drive: drive,
            context: context,
            perItemHandler: { id, data, error in
                Task { await recorder.record(id: id, data: data, error: error) }
            }
        )

        try await Self.drainBackgroundTasks()

        let results = await recorder.results
        XCTAssertEqual(results.count, 1)
        XCTAssertNil(results.first?.data)
        let nsError = results.first?.error as NSError?
        XCTAssertNotNil(nsError)
        let domain = nsError?.domain ?? ""
        XCTAssertTrue(
            domain == NSFileProviderErrorDomain || domain == NSCocoaErrorDomain,
            "THUMB-13: returned error must be NSFileProviderErrorDomain or NSCocoaErrorDomain, got \(domain)"
        )
    }

    // MARK: - Helpers

    private static let testLogger = Logger(
        subsystem: "io.cubbit.DS3Drive.tests",
        category: "ThumbnailHybridConsumeTests"
    )

    /// Creates a non-empty temp file. The fallback path's `defer` removes it
    /// after the render closure runs, so each test must create its own.
    private static func makeFakeDownloadFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hybrid-test-\(UUID().uuidString).bin")
        try Data([0x00, 0x01, 0x02]).write(to: url)
        return url
    }

    /// Awaits any in-flight `Task { ... }` recorder writes and the detached
    /// PUT Task. 100ms is empirically enough for the test workloads above.
    private static func drainBackgroundTasks() async throws {
        try await Task.sleep(nanoseconds: 100_000_000)
    }

    /// Builder for `ThumbnailFallbackContext` with sensible defaults so each
    /// test only overrides the closures it cares about.
    fileprivate static func makeContext(
        limiter: ThumbnailFallbackLimiter = ThumbnailFallbackLimiter(),
        download: @escaping ThumbnailOriginalDownloader = { _, _ in
            throw NSFileProviderError(.cannotSynchronize)
        },
        render: @escaping ThumbnailRendererFn = { _ in .failure(.thumbnailCreate) },
        putThumbnail: @escaping ThumbnailFallbackPutter = { _, _, _, _ in
            // Default: succeed silently. Tests that care override this.
        },
        signalParentContainer: @escaping ThumbnailSignalContainer = { _ in
            // Default: no-op. Tests that care override this.
        }
    ) -> ThumbnailFallbackContext {
        ThumbnailFallbackContext(
            limiter: limiter,
            download: download,
            render: render,
            putThumbnail: putThumbnail,
            signalParentContainer: signalParentContainer,
            logger: testLogger
        )
    }
}

// MARK: - Test recording helpers (file-scoped to avoid clashing with FetchThumbnailsTests)

actor PutRecorder {
    struct Entry {
        let bucket: String
        let key: String
        let data: Data
        let etag: String
    }

    private(set) var entries: [Entry] = []

    func record(bucket: String, key: String, data: Data, etag: String) {
        entries.append(Entry(bucket: bucket, key: key, data: data, etag: etag))
    }
}

actor SignalRecorder {
    private(set) var identifiers: [NSFileProviderItemIdentifier] = []

    func record(_ id: NSFileProviderItemIdentifier) {
        identifiers.append(id)
    }
}
