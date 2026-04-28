import XCTest

/// Tests `ThumbnailFetchLimiter` (Phase 13, Plan 13-06).
///
/// Notes on integration: `ThumbnailFetchLimiter.swift` is compiled directly into
/// the test bundle via the DS3DriveProviderTests target's Sources phase (same
/// pattern as `BucketListingLimiter` / `S3Enumerator`), so no `@testable import`
/// is needed for an extension-owned source file.
final class ThumbnailFetchLimiterTests: XCTestCase {
    // MARK: - Test 1

    /// Below-cap acquires return immediately and increment `inFlight`.
    func testAcquireBelowMaxDoesNotBlock() async throws {
        let limiter = ThumbnailFetchLimiter(maxSlots: 4)
        try await limiter.acquire()
        try await limiter.acquire()
        try await limiter.acquire()
        let inFlight = await limiter.inFlightCount
        let waiters = await limiter.waiterCount
        XCTAssertEqual(inFlight, 3)
        XCTAssertEqual(waiters, 0)
    }

    // MARK: - Test 2

    /// At-cap acquire suspends; release wakes the suspended waiter.
    func testAcquireAtMaxBlocksUntilRelease() async throws {
        let limiter = ThumbnailFetchLimiter(maxSlots: 4)
        for _ in 0 ..< 4 {
            try await limiter.acquire()
        }

        // The 5th acquire must suspend.
        let signal = AsyncSignal()
        let waiterTask = Task {
            try? await limiter.acquire()
            await signal.fire()
        }

        // Yield long enough for `waiterTask` to suspend inside the limiter.
        try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
        var fired = await signal.didFire
        XCTAssertFalse(fired, "5th acquire must remain suspended while at cap")
        let waitersBeforeRelease = await limiter.waiterCount
        XCTAssertEqual(waitersBeforeRelease, 1)

        await limiter.release()

        // After release, waiter should resume.
        _ = await waiterTask.value
        fired = await signal.didFire
        XCTAssertTrue(fired, "Released slot should hand off to suspended waiter")

        // After hand-off: 4 in flight (the 5th took the slot), 0 waiters.
        let inFlight = await limiter.inFlightCount
        let waiters = await limiter.waiterCount
        XCTAssertEqual(inFlight, 4)
        XCTAssertEqual(waiters, 0)
    }

    // MARK: - Test 3

    /// 5 concurrent acquirers on a 4-slot limiter never run more than 4 at once.
    func testFiveConcurrentAcquiresOnFourSlotsSerializesOneWaiter() async {
        let limiter = ThumbnailFetchLimiter(maxSlots: 4)
        let counter = ConcurrencyCounter()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 5 {
                group.addTask {
                    try? await limiter.acquire()
                    await counter.enter()
                    try? await Task.sleep(nanoseconds: 30_000_000) // 30ms — keep slot
                    await counter.exit()
                    await limiter.release()
                }
            }
        }

        let observedMax = await counter.observedMax
        XCTAssertLessThanOrEqual(observedMax, 4, "Limiter must cap concurrency at 4")
        let finalInFlight = await limiter.inFlightCount
        XCTAssertEqual(finalInFlight, 0, "All slots released after group completes")
    }

    // MARK: - Test 4 — FIFO

    /// Waiters resume in enqueue order (FIFO). Pins `waiters.append + removeFirst`
    /// against any future refactor that switches to a Set, LIFO stack, or unsorted
    /// dictionary. Eight contenders saturate then queue four; release order MUST
    /// match enqueue order.
    func testFIFOOrderingAcrossEightContenders() async {
        let limiter = ThumbnailFetchLimiter(maxSlots: 4)
        let recorder = OrderRecorder()

        // 1. Saturate the limiter — 4 acquirers hold their slots until told to release.
        let holderReleaseGates: [AsyncOneShot] = (0 ..< 4).map { _ in AsyncOneShot() }
        var holderTasks: [Task<Void, Never>] = []
        for index in 0 ..< 4 {
            let gate = holderReleaseGates[index]
            let task = Task {
                try? await limiter.acquire()
                await gate.wait()
                await limiter.release()
            }
            holderTasks.append(task)
        }

        // Wait until all holders are in the limiter.
        try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
        let inFlightAfterHolders = await limiter.inFlightCount
        XCTAssertEqual(inFlightAfterHolders, 4, "Setup: 4 slots must be held")

        // 2. Enqueue 4 waiters in known order [W0, W1, W2, W3].
        //    Each records its enqueue index BEFORE calling acquire(), then records
        //    its resume index AFTER acquire() returns.
        var waiterTasks: [Task<Void, Never>] = []
        for index in 0 ..< 4 {
            await recorder.recordEnqueue(index)
            let task = Task {
                try? await limiter.acquire()
                await recorder.recordResume(index)
                await limiter.release()
            }
            waiterTasks.append(task)
            // Spacing ensures deterministic enqueue order — give each Task time
            // to actually start and call acquire() before the next one queues.
            try? await Task.sleep(nanoseconds: 20_000_000) // 20ms
        }

        // Sanity: 4 waiters now queued.
        let queuedWaiters = await limiter.waiterCount
        XCTAssertEqual(queuedWaiters, 4, "Setup: 4 waiters must be queued")

        // 3. Release the 4 holders one at a time, with a small gap so the resume
        //    completes before the next release.
        for gate in holderReleaseGates {
            await gate.fire()
            try? await Task.sleep(nanoseconds: 30_000_000) // 30ms
        }

        // Drain everything.
        for task in holderTasks {
            _ = await task.value
        }
        for task in waiterTasks {
            _ = await task.value
        }

        let enqueueOrder = await recorder.enqueueOrder
        let resumeOrder = await recorder.resumeOrder
        XCTAssertEqual(enqueueOrder, [0, 1, 2, 3], "Enqueue indices recorded in order")
        XCTAssertEqual(resumeOrder, [0, 1, 2, 3], "FIFO: waiters must resume in enqueue order")
    }
}

// MARK: - Test helpers

/// Tracks the maximum number of concurrent participants.
private actor ConcurrencyCounter {
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

/// One-shot signal that records when it has fired.
private actor AsyncSignal {
    private(set) var didFire: Bool = false

    func fire() {
        didFire = true
    }
}

/// Async one-shot gate — `wait()` suspends until `fire()` is called.
/// Multiple `wait()` callers all resume on the single `fire()`.
private actor AsyncOneShot {
    private var fired = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if fired { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            waiters.append(cont)
        }
    }

    func fire() {
        fired = true
        let pending = waiters
        waiters.removeAll()
        for cont in pending {
            cont.resume()
        }
    }
}

/// Records enqueue + resume indices in the order they happen.
private actor OrderRecorder {
    private(set) var enqueueOrder: [Int] = []
    private(set) var resumeOrder: [Int] = []

    func recordEnqueue(_ index: Int) {
        enqueueOrder.append(index)
    }
    func recordResume(_ index: Int) {
        resumeOrder.append(index)
    }
}
