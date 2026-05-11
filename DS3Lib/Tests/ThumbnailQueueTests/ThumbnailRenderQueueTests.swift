import ThumbnailQueue
import XCTest

final class ThumbnailRenderQueueTests: XCTestCase {
    /// Test helper: temp queue JSON URL plus a cleanup closure that removes both
    /// the JSON file and its `.lock` sidecar. Centralizing this prevents the
    /// `*.json.lock` artifacts from polluting the temp directory across runs.
    private func makeTempQueueURL() -> (url: URL, cleanup: () -> Void) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("queue-\(UUID().uuidString).json")
        return (url, {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: url.appendingPathExtension("lock"))
        })
    }

    func testCrossProcessAppendIsVisibleToSecondInstance() async throws {
        let (url, cleanup) = makeTempQueueURL()
        defer { cleanup() }

        let producer = ThumbnailRenderQueue(testFileURL: url)
        let consumer = ThumbnailRenderQueue(testFileURL: url)

        // Consumer warms up its in-memory state with an empty queue.
        let initial = await consumer.dequeue(maxItems: 10)
        XCTAssertTrue(initial.isEmpty)

        // Producer (simulating extension) appends.
        let driveID = UUID()
        await producer.append(ThumbnailRenderQueueItem(driveID: driveID, s3Key: "Foo/bar.JPG"))

        // Consumer (simulating main app drain) must see the appended item even
        // though it already loaded once.
        let visible = await consumer.dequeue(maxItems: 10)
        XCTAssertEqual(visible.count, 1)
        XCTAssertEqual(visible.first?.s3Key, "Foo/bar.JPG")
    }

    func testAppendRevivesPoisonedItemAfterCooldown() async throws {
        let (url, cleanup) = makeTempQueueURL()
        defer { cleanup() }

        let queue = ThumbnailRenderQueue(testFileURL: url)
        let driveID = UUID()
        // Stamp `addedAt` more than the cooldown ago so the next append revives.
        let pastDate = Date(timeIntervalSinceNow: -ThumbnailRenderQueue.revivalCooldownSeconds - 60)
        let item = ThumbnailRenderQueueItem(driveID: driveID, s3Key: "Foo/poison.JPG", addedAt: pastDate)
        await queue.append(item)
        for _ in 0..<ThumbnailRenderQueue.maxAttempts {
            await queue.fail(item)
        }
        let beforeRevive = await queue.dequeue(maxItems: 10)
        XCTAssertTrue(beforeRevive.isEmpty)

        await queue.append(item)
        let afterRevive = await queue.dequeue(maxItems: 10)
        XCTAssertEqual(afterRevive.count, 1)
        XCTAssertEqual(afterRevive.first?.attempts, 0)
    }

    func testAppendDoesNotRevivePoisonedItemWithinCooldown() async throws {
        let (url, cleanup) = makeTempQueueURL()
        defer { cleanup() }

        let queue = ThumbnailRenderQueue(testFileURL: url)
        let driveID = UUID()
        // Fresh `addedAt` — within cooldown, revival must be a no-op.
        let item = ThumbnailRenderQueueItem(driveID: driveID, s3Key: "Foo/recent-fail.JPG")
        await queue.append(item)
        for _ in 0..<ThumbnailRenderQueue.maxAttempts {
            await queue.fail(item)
        }

        await queue.append(item)
        let dequeued = await queue.dequeue(maxItems: 10)
        XCTAssertTrue(dequeued.isEmpty, "poisoned item still within cooldown should remain poisoned")
    }

    /// Regression for #152: extension's stale in-memory snapshot must not
    /// resurrect an item the main app already completed.
    ///
    /// Before the flock fix, this sequence would leave A in the queue:
    ///   ext.loadIfNeeded() -> [A]
    ///   app.complete(A)    -> [] on disk
    ///   ext.append(B)      -> persists [A, B] from stale snapshot
    ///
    /// Single-shot `async let` only proves the lock holds for one scheduling
    /// outcome. Loop the race many times so a regression that depends on
    /// scheduler luck is forced to manifest.
    func testAppendDoesNotResurrectCompletedItem() async throws {
        let iterations = 100
        for _ in 0..<iterations {
            let (url, cleanup) = makeTempQueueURL()
            defer { cleanup() }

            let ext = ThumbnailRenderQueue(testFileURL: url)
            let app = ThumbnailRenderQueue(testFileURL: url)
            let driveID = UUID()
            let itemA = ThumbnailRenderQueueItem(driveID: driveID, s3Key: "Foo/a.JPG")
            let itemB = ThumbnailRenderQueueItem(driveID: driveID, s3Key: "Foo/b.JPG")

            // Seed disk with [A] and warm both instances' in-memory state.
            await ext.append(itemA)
            _ = await ext.dequeue(maxItems: 10)
            _ = await app.dequeue(maxItems: 10)

            // Race: main app completes A, extension appends B concurrently.
            async let completeTask: Void = app.complete(itemA)
            async let appendTask: Void = ext.append(itemB)
            _ = await (completeTask, appendTask)

            // Final state on disk must be [B]. A fresh instance ensures we read
            // the on-disk JSON, not a cached `items` snapshot.
            let verifier = ThumbnailRenderQueue(testFileURL: url)
            let final = await verifier.dequeue(maxItems: 10).map(\.s3Key).sorted()
            XCTAssertEqual(final, ["Foo/b.JPG"], "completed item must not be resurrected")
        }
    }

    func testCompleteFromOneInstanceVisibleToOther() async throws {
        let (url, cleanup) = makeTempQueueURL()
        defer { cleanup() }

        let a = ThumbnailRenderQueue(testFileURL: url)
        let b = ThumbnailRenderQueue(testFileURL: url)

        let driveID = UUID()
        let item = ThumbnailRenderQueueItem(driveID: driveID, s3Key: "Foo/baz.JPG")
        await a.append(item)

        let beforeComplete = await b.dequeue(maxItems: 10)
        XCTAssertEqual(beforeComplete.count, 1)

        await a.complete(item)

        let afterComplete = await b.dequeue(maxItems: 10)
        XCTAssertTrue(afterComplete.isEmpty)
    }
}
