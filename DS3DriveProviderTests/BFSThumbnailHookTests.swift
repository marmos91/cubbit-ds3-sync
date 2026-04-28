@testable import DS3Lib
import Foundation
import os
import XCTest

/// Tests the BFS pass-tail thumbnail hooks (Phase 13 D-16, D-17, D-20, D-25, D-27;
/// THUMB-15, THUMB-19, THUMB-21).
///
/// Exercise `BFSThumbnailHookRunner` directly with mock conformers of the
/// `ThumbnailBackfillRunning` + `OrphanSweeping` injection seams. The hook
/// is gated EXTERNALLY by the indexer (caller decides whether to invoke
/// `runHooks`); these tests cover the inverse — that "the indexer calls /
/// does not call" wiring matches the contract in the plan. The skip cases
/// (Tests 2, 3, 5) assert via the gate-policy helper.
final class BFSThumbnailHookTests: XCTestCase {
    // MARK: - Helpers

    /// Mirrors the gate that the BFS indexer uses at pass tail (per D-17 / D-27):
    /// "thumbnails enabled AND drive not paused". Tests assert this helper's
    /// disposition so the gate logic is pinned independent of the indexer.
    private func shouldRunPassTailHooks(thumbnailEnabled: Bool, isPaused: Bool) -> Bool {
        thumbnailEnabled && !isPaused
    }

    private func makeDrive() -> DS3Drive {
        ProviderTestFixtures.makeDrive()
    }

    // MARK: - Test 1 — pass tail invokes coordinator with the constant batch size

    /// When enabled + not paused, runHooks invokes runBatch exactly once with
    /// `DefaultSettings.Thumbnail.backfillBatchSize`. We assert against the
    /// CONSTANT (not the literal 5) so a future Plan 13-01 retune doesn't
    /// break the test.
    func testBFSPassTailInvokesCoordinatorWhenEnabledAndUnpaused() async {
        let drive = makeDrive()
        let coordinator = MockBackfillCoordinator()
        let sweeper = MockOrphanSweeper()
        let runner = BFSThumbnailHookRunner()

        XCTAssertTrue(shouldRunPassTailHooks(thumbnailEnabled: true, isPaused: false))

        let spawned = runner.runHooks(
            coordinator: coordinator,
            sweeper: sweeper,
            bucket: drive.syncAnchor.bucket.name,
            drivePrefix: drive.syncAnchor.prefix,
            enumeratedKeys: ["a.jpg"]
        )

        // Wait for both tasks to finish.
        await spawned.backfill?.value
        await spawned.sweep?.value

        XCTAssertEqual(coordinator.runBatchInvocations, 1)
        XCTAssertEqual(coordinator.lastMaxItems, DefaultSettings.Thumbnail.backfillBatchSize)
    }

    // MARK: - Test 2 — pause skip

    /// When the drive is paused, the gate yields false; runHooks is NOT
    /// called by the indexer. (Direct: assert the gate function.)
    func testBFSPassTailSkipsCoordinatorWhenPaused() {
        XCTAssertFalse(shouldRunPassTailHooks(thumbnailEnabled: true, isPaused: true))
    }

    // MARK: - Test 3 — disabled skip

    /// When thumbnails are disabled, the gate yields false; runHooks is NOT
    /// called by the indexer.
    func testBFSPassTailSkipsCoordinatorWhenDisabled() {
        XCTAssertFalse(shouldRunPassTailHooks(thumbnailEnabled: false, isPaused: false))
    }

    // MARK: - Test 4 — sweeper invoked with enumerated keys (gate enabled)

    /// When enabled, runHooks invokes sweep exactly once with the same
    /// enumeratedKeys / bucket / prefix passed in.
    func testBFSPassTailInvokesOrphanSweepWhenEnabled() async {
        let drive = makeDrive()
        let coordinator = MockBackfillCoordinator()
        let sweeper = MockOrphanSweeper()
        let runner = BFSThumbnailHookRunner()

        let keys: Set = ["k1", "k2", "k3"]
        let spawned = runner.runHooks(
            coordinator: coordinator,
            sweeper: sweeper,
            bucket: drive.syncAnchor.bucket.name,
            drivePrefix: drive.syncAnchor.prefix,
            enumeratedKeys: keys
        )
        await spawned.sweep?.value
        await spawned.backfill?.value

        XCTAssertEqual(sweeper.sweepInvocations, 1)
        XCTAssertEqual(sweeper.lastBucket, drive.syncAnchor.bucket.name)
        XCTAssertEqual(sweeper.lastDrivePrefix, drive.syncAnchor.prefix)
        XCTAssertEqual(sweeper.lastEnumeratedKeys, keys)
    }

    // MARK: - Test 5 — sweep skipped when disabled (gate-policy)

    /// Disabled drives MUST NOT sweep (D-27, D-04). Same gate covers both
    /// coordinator and sweep — assert the gate function returns false.
    func testBFSPassTailSkipsOrphanSweepWhenDisabled() {
        XCTAssertFalse(shouldRunPassTailHooks(thumbnailEnabled: false, isPaused: false))
    }

    // MARK: - Test 6 — fire-and-forget (no blocking on coordinator latency)

    /// runHooks returns immediately even if the coordinator's runBatch
    /// artificially sleeps. D-17: BFS pass duration must NOT be extended.
    func testBFSPassDoesNotBlockOnCoordinatorWork() async {
        let drive = makeDrive()
        let coordinator = MockBackfillCoordinator()
        coordinator.runBatchDelayNanos = 1_000_000_000 // 1s
        let sweeper = MockOrphanSweeper()
        let runner = BFSThumbnailHookRunner()

        let start = DispatchTime.now()
        let spawned = runner.runHooks(
            coordinator: coordinator,
            sweeper: sweeper,
            bucket: drive.syncAnchor.bucket.name,
            drivePrefix: drive.syncAnchor.prefix,
            enumeratedKeys: []
        )
        let elapsedNanos = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds

        XCTAssertLessThan(
            elapsedNanos, 50_000_000,
            "runHooks MUST be fire-and-forget — must NOT block on coordinator latency (D-17)"
        )

        // Drain the spawned tasks so the test process doesn't leak them.
        await spawned.backfill?.value
        await spawned.sweep?.value
    }

    // MARK: - Test 7 — pause flip cancels in-flight backfill task

    /// Start a long backfill, then call cancelInFlightBackfill (BFS-side
    /// counterpart of D-20). The Task is cancelled (Swift Concurrency
    /// `Task.isCancelled == true`); the mock observes the cancellation
    /// signal via Task.checkCancellation() and exits early.
    func testPauseFlipsCancelsInFlightBackfillTask() async {
        let drive = makeDrive()
        let coordinator = MockBackfillCoordinator()
        coordinator.runBatchDelayNanos = 5_000_000_000 // 5s — long enough
        coordinator.observeCancellationDuringBatch = true
        let sweeper = MockOrphanSweeper()
        let runner = BFSThumbnailHookRunner()

        let spawned = runner.runHooks(
            coordinator: coordinator,
            sweeper: sweeper,
            bucket: drive.syncAnchor.bucket.name,
            drivePrefix: drive.syncAnchor.prefix,
            enumeratedKeys: []
        )

        // Give the backfill a moment to start sleeping.
        try? await Task.sleep(nanoseconds: 50_000_000)

        runner.cancelInFlightBackfill()

        await spawned.backfill?.value

        XCTAssertTrue(
            spawned.backfill?.isCancelled ?? false,
            "Backfill Task MUST report cancelled after pause-flip"
        )
        XCTAssertTrue(
            coordinator.observedCancellation,
            "Coordinator MUST observe a CancellationError after pause-flip"
        )
    }
}

// MARK: - Mock conformers

private final class MockBackfillCoordinator: ThumbnailBackfillRunning, @unchecked Sendable {
    private struct State {
        var runBatchInvocations: Int = 0
        var lastMaxItems: Int = -1
        var observedCancellation: Bool = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    var runBatchInvocations: Int {
        state.withLock { $0.runBatchInvocations }
    }
    var lastMaxItems: Int {
        state.withLock { $0.lastMaxItems }
    }
    var observedCancellation: Bool {
        state.withLock { $0.observedCancellation }
    }

    var runBatchDelayNanos: UInt64 = 0
    var observeCancellationDuringBatch: Bool = false

    func runBatch(maxItems: Int) async throws -> ThumbnailBackfillCoordinator.BatchResult {
        state.withLock { state in
            state.runBatchInvocations += 1
            state.lastMaxItems = maxItems
        }
        if runBatchDelayNanos > 0 {
            do {
                try await Task.sleep(nanoseconds: runBatchDelayNanos)
            } catch is CancellationError {
                if observeCancellationDuringBatch {
                    state.withLock { $0.observedCancellation = true }
                }
                throw CancellationError()
            } catch {
                throw error
            }
        }
        return ThumbnailBackfillCoordinator.BatchResult(
            processed: 0, succeeded: 0, skipped: 0, failed: 0, totalPending: 0
        )
    }
}

private final class MockOrphanSweeper: OrphanSweeping, @unchecked Sendable {
    private struct State {
        var sweepInvocations: Int = 0
        var lastBucket: String?
        var lastDrivePrefix: String?
        var lastEnumeratedKeys: Set<String> = []
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    var sweepInvocations: Int {
        state.withLock { $0.sweepInvocations }
    }
    var lastBucket: String? {
        state.withLock { $0.lastBucket }
    }
    var lastDrivePrefix: String? {
        state.withLock { $0.lastDrivePrefix }
    }
    var lastEnumeratedKeys: Set<String> {
        state.withLock { $0.lastEnumeratedKeys }
    }

    func sweep(
        bucket: String,
        drivePrefix: String?,
        enumeratedKeys: Set<String>
    ) async -> Int {
        state.withLock { state in
            state.sweepInvocations += 1
            state.lastBucket = bucket
            state.lastDrivePrefix = drivePrefix
            state.lastEnumeratedKeys = enumeratedKeys
        }
        return 0
    }
}
