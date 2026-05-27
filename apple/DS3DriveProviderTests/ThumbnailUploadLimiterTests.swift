import XCTest

/// Tests `ThumbnailUploadLimiter` (issue #141, Phase 2).
///
/// `ThumbnailUploadLimiter.swift` is compiled directly into the test bundle
/// via the DS3DriveProviderTests target's Sources phase (same pattern as
/// `ThumbnailFallbackLimiter` / `ThumbnailFetchLimiter`).
final class ThumbnailUploadLimiterTests: XCTestCase {
    // MARK: - Slot mechanics (mirrors ThumbnailFallbackLimiterTests)

    func testAcquireBelowMaxDoesNotBlock() async throws {
        let limiter = ThumbnailUploadLimiter(maxSlots: 2)
        try await limiter.acquire()
        let inFlight = await limiter.inFlightCount
        XCTAssertEqual(inFlight, 1)
    }

    /// Polls `waiterCount` against an expected value. Mirrors the helper in
    /// `ThumbnailFallbackLimiterTests` — under CI scheduler pressure a spawned
    /// waiter Task may not have reached its `withCheckedThrowingContinuation`
    /// within a fixed sleep window, so polling is more robust than a bare sleep.
    private func waitForWaiterCount(
        _ expected: Int,
        on limiter: ThumbnailUploadLimiter,
        timeout: TimeInterval = 2.0,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let count = await limiter.waiterCount
            if count == expected { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let final = await limiter.waiterCount
        XCTAssertEqual(
            final, expected,
            "Timed out waiting for waiterCount == \(expected) (got \(final))",
            file: file, line: line
        )
    }

    func testTwoAcquireAtMaxBlocksThird() async throws {
        let limiter = ThumbnailUploadLimiter(maxSlots: 2)
        try await limiter.acquire()
        try await limiter.acquire()
        let blockedTask = Task { try await limiter.acquire() }
        try await waitForWaiterCount(1, on: limiter)
        await limiter.release()
        _ = try await blockedTask.value
    }

    func testFIFOOrderPreservedAcrossWaiters() async throws {
        actor OrderRecorder {
            private var values: [String] = []
            func record(_ value: String) {
                values.append(value)
            }
            func snapshot() -> [String] {
                values
            }
        }
        let limiter = ThumbnailUploadLimiter(maxSlots: 1)
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
        let recorded = await order.snapshot()
        XCTAssertEqual(recorded, ["A", "B"])
    }

    func testCancellationDuringWaitRemovesWaiter() async throws {
        let limiter = ThumbnailUploadLimiter(maxSlots: 1)
        try await limiter.acquire()
        let cancelTask = Task { try await limiter.acquire() }
        try await waitForWaiterCount(1, on: limiter)
        cancelTask.cancel()
        do {
            _ = try await cancelTask.value
            XCTFail("expected CancellationError")
        } catch is CancellationError {
            // ok
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        try await waitForWaiterCount(0, on: limiter)
    }

    // MARK: - Soft cap (NEW behavior unique to ThumbnailUploadLimiter)

    func testSoftCapFalseWhenWaitersBelowCap() async throws {
        let limiter = ThumbnailUploadLimiter(maxSlots: 1, softMaxWaiters: 4)
        try await limiter.acquire()
        let isAt = await limiter.isAtSoftCap
        XCTAssertFalse(isAt)
    }

    func testSoftCapTrueWhenWaitersAtOrAboveCap() async throws {
        let limiter = ThumbnailUploadLimiter(maxSlots: 1, softMaxWaiters: 2)
        try await limiter.acquire() // 1 in flight, 0 waiters
        let t1 = Task { try await limiter.acquire() } // 1 in flight, 1 waiter
        try await waitForWaiterCount(1, on: limiter)
        let t2 = Task { try await limiter.acquire() } // 1 in flight, 2 waiters → at cap
        try await waitForWaiterCount(2, on: limiter)
        let isAt = await limiter.isAtSoftCap
        XCTAssertTrue(isAt)
        await limiter.release()
        await limiter.release()
        _ = try await t1.value
        _ = try await t2.value
    }
}
