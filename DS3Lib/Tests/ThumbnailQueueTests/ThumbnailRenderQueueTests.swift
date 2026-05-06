import DS3Lib
@testable import ThumbnailQueue
import XCTest

final class ThumbnailRenderQueueTests: XCTestCase {
    func testCrossProcessAppendIsVisibleToSecondInstance() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("queue-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

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
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("queue-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

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
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("queue-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

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

    func testCompleteFromOneInstanceVisibleToOther() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("queue-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

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
