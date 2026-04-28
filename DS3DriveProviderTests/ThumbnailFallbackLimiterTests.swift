import XCTest

/// Tests `ThumbnailFallbackLimiter` (Phase 13.2, D-02, D-19, D-20, D-21).
///
/// `ThumbnailFallbackLimiter.swift` is compiled directly into the test bundle
/// via the DS3DriveProviderTests target's Sources phase (same pattern as
/// `ThumbnailFetchLimiter` / `BucketListingLimiter`).
final class ThumbnailFallbackLimiterTests: XCTestCase {
    // MARK: - FIFO + cancellation semantics (analog of ThumbnailFetchLimiterTests)

    func testAcquireBelowMaxDoesNotBlock() async throws {
        let limiter = ThumbnailFallbackLimiter(maxSlots: 2)
        try await limiter.acquire()
        let inFlight = await limiter.inFlightCount
        XCTAssertEqual(inFlight, 1)
    }

    /// Code review Fix 4 (Phase 13.2): replace fixed `Task.sleep` synchronization
    /// with deadline-bounded polling against the actor's `waiterCount`. Under CI
    /// scheduler pressure the spawned waiter Task may not have reached its
    /// `withCheckedThrowingContinuation` within a 30/50ms window, producing
    /// flaky assertions on `waiterCount`. Polling tolerates scheduler latency
    /// while keeping the failure mode (timeout) explicit.
    private func waitForWaiterCount(
        _ expected: Int,
        on limiter: ThumbnailFallbackLimiter,
        timeout: TimeInterval = 2.0,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let count = await limiter.waiterCount
            if count == expected { return }
            try await Task.sleep(nanoseconds: 5_000_000) // 5ms poll
        }
        let final = await limiter.waiterCount
        XCTAssertEqual(
            final, expected,
            "Timed out waiting for waiterCount == \(expected) (got \(final))",
            file: file, line: line
        )
    }

    func testTwoAcquireAtMaxBlocksThird() async throws {
        let limiter = ThumbnailFallbackLimiter(maxSlots: 2)
        try await limiter.acquire()
        try await limiter.acquire()
        let blockedTask = Task { try await limiter.acquire() }
        try await waitForWaiterCount(1, on: limiter)
        await limiter.release()
        _ = try await blockedTask.value
    }

    func testFIFOOrderPreservedAcrossWaiters() async throws {
        let limiter = ThumbnailFallbackLimiter(maxSlots: 1)
        try await limiter.acquire()
        let order = OrderRecorder()
        let taskA = Task {
            try await limiter.acquire()
            await order.record("A")
            await limiter.release()
        }
        try await waitForWaiterCount(1, on: limiter)
        let taskB = Task {
            try await limiter.acquire()
            await order.record("B")
            await limiter.release()
        }
        try await waitForWaiterCount(2, on: limiter)
        await limiter.release()
        _ = try await taskA.value
        _ = try await taskB.value
        let recorded = await order.values
        XCTAssertEqual(recorded, ["A", "B"])
    }

    func testCancellationDuringWaitRemovesWaiter() async throws {
        let limiter = ThumbnailFallbackLimiter(maxSlots: 1)
        try await limiter.acquire()
        let waiter = Task { try await limiter.acquire() }
        try await waitForWaiterCount(1, on: limiter)
        waiter.cancel()
        do {
            _ = try await waiter.value
            XCTFail("expected CancellationError")
        } catch is CancellationError {
            // expected
        }
        // Wait for the onCancel handler's Task to drain (waiter removed from queue).
        try await waitForWaiterCount(0, on: limiter)
        await limiter.release()
    }

    // MARK: - Strike counter + poison set (D-19, D-20)

    func testRecordFailureIncrementsCounter() async {
        let limiter = ThumbnailFallbackLimiter(maxSlots: 2)
        let key = "drive/photo.heic"
        await limiter.recordFailure(key)
        await limiter.recordFailure(key)
        let count = await limiter.strikeCountForTest(key)
        let poisoned = await limiter.isPoisoned(key)
        XCTAssertEqual(count, 2)
        XCTAssertFalse(poisoned)
    }

    func testThirdStrikeMovesKeyToPoison() async {
        let limiter = ThumbnailFallbackLimiter(maxSlots: 2)
        let key = "drive/photo.heic"
        await limiter.recordFailure(key)
        await limiter.recordFailure(key)
        await limiter.recordFailure(key)
        let poisoned = await limiter.isPoisoned(key)
        let count = await limiter.strikeCountForTest(key)
        XCTAssertTrue(poisoned, "Third strike must poison the key")
        XCTAssertEqual(count, 0, "Counter must be cleared once key is poisoned")
    }

    func testRecordSuccessClearsCounter() async {
        let limiter = ThumbnailFallbackLimiter(maxSlots: 2)
        let key = "drive/photo.heic"
        await limiter.recordFailure(key)
        await limiter.recordFailure(key)
        await limiter.recordSuccess(key)
        await limiter.recordFailure(key)
        let count = await limiter.strikeCountForTest(key)
        let poisoned = await limiter.isPoisoned(key)
        XCTAssertEqual(count, 1)
        XCTAssertFalse(poisoned)
    }

    func testPoisonedKeyStaysPoisonedOnSubsequentFailures() async {
        let limiter = ThumbnailFallbackLimiter(maxSlots: 2)
        let key = "drive/photo.heic"
        await limiter.recordFailure(key)
        await limiter.recordFailure(key)
        await limiter.recordFailure(key)
        await limiter.recordFailure(key) // 4th call — must be idempotent
        let poisoned = await limiter.isPoisoned(key)
        XCTAssertTrue(poisoned)
    }

    func testSeparateKeysHaveSeparateCounters() async {
        let limiter = ThumbnailFallbackLimiter(maxSlots: 2)
        await limiter.recordFailure("a/x.jpg")
        await limiter.recordFailure("a/x.jpg")
        await limiter.recordFailure("a/x.jpg")
        let xPoisoned = await limiter.isPoisoned("a/x.jpg")
        let yPoisoned = await limiter.isPoisoned("a/y.jpg")
        XCTAssertTrue(xPoisoned)
        XCTAssertFalse(yPoisoned)
    }
}

private actor OrderRecorder {
    private(set) var values: [String] = []
    func record(_ value: String) {
        values.append(value)
    }
}
