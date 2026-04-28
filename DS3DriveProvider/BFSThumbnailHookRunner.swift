import DS3Lib
import Foundation
import os.log

// MARK: - BFS pass-tail thumbnail hook runner (Phase 13 D-16, D-17, D-20, D-25, D-27)

//
// Carries the per-drive state that survives across BFS passes:
//  • Lazy-built `ThumbnailBackfillCoordinator` (one per drive, D-16).
//  • Lazy-built `OrphanSweeper` (one per drive).
//  • A handle to the in-flight backfill `Task` so a subsequent pause-flip can
//    cancel it (D-20 cooperation; coordinator's own cancellation observation
//    handles the partial-batch graceful exit).
//
// Designed as a separate type (not inlined into `BreadthFirstIndexer`) so the
// hook logic is testable WITHOUT standing up a real BFS pass. Tests inject
// mock conformers of `ThumbnailBackfillRunning` + `OrphanSweeping`; the
// indexer wires the production conformers (the real coordinator + sweeper).

// MARK: - Protocols (testability seams)

/// Test-injection seam for `ThumbnailBackfillCoordinator`. The production
/// coordinator conforms via the conformance below.
protocol ThumbnailBackfillRunning: Sendable {
    func runBatch(maxItems: Int) async throws -> ThumbnailBackfillCoordinator.BatchResult
}

extension ThumbnailBackfillCoordinator: ThumbnailBackfillRunning {}

/// Test-injection seam for `OrphanSweeper`.
protocol OrphanSweeping: Sendable {
    func sweep(
        bucket: String,
        drivePrefix: String?,
        enumeratedKeys: Set<String>
    ) async -> Int
}

// Conformance is declared in OrphanSweeper.swift (same file as the type) to
// satisfy Swift 6 strict concurrency's same-file Sendable requirement.

// MARK: - Runner

/// Per-drive runner owning the backfill coordinator + sweeper plus the
/// in-flight backfill Task handle. Hooked once per BFS pass tail.
///
/// **Concurrency posture (D-17):** `runHooks` opens TWO `Task`s — one for the
/// coordinator's `runBatch`, one for the sweeper. Both Tasks execute fire-and-
/// forget; `runHooks` returns as soon as the Tasks are spawned, so the BFS
/// pass-tail block never waits on backfill or sweep latency.
///
/// **Pause cooperation (D-20):** when the BFS observes a pause flip, it calls
/// `cancelInFlightBackfill()`. The runner cancels the stored Task handle; the
/// coordinator observes Swift Concurrency's structured cancellation at its
/// per-iteration `Task.checkCancellation()` and exits cleanly.
final class BFSThumbnailHookRunner: @unchecked Sendable {
    // MARK: Test introspection

    /// Snapshot of the most recently spawned tasks (read-only). Tests await
    /// these to assert behavior without racing the spawn → execute boundary.
    struct LastSpawnedTasks {
        let backfill: Task<Void, Never>?
        let sweep: Task<Void, Never>?
    }

    private let lock = NSLock()
    private var inFlightBackfillTask: Task<Void, Never>?
    private var lastBackfillTask: Task<Void, Never>?
    private var lastSweepTask: Task<Void, Never>?

    private let logger = os.Logger(
        subsystem: LogSubsystem.provider,
        category: LogCategory.thumbnail.rawValue
    )

    // MARK: Public API

    /// Spawn the pass-tail hooks. Returns immediately; both Tasks run
    /// fire-and-forget. Caller MUST gate on `thumbnailEnabled`+ `!isPaused`
    /// before calling — runner does NOT re-check; this keeps the policy
    /// (read SharedData / drive.status) at the call site, which owns those
    /// concerns.
    @discardableResult
    func runHooks(
        coordinator: any ThumbnailBackfillRunning,
        sweeper: any OrphanSweeping,
        bucket: String,
        drivePrefix: String?,
        enumeratedKeys: Set<String>
    ) -> LastSpawnedTasks {
        // Cancel any prior backfill BEFORE spawning a new one — defensive
        // hygiene if a previous pass overlapped with this one (rare, but
        // possible if the coordinator stalled).
        cancelInFlightBackfill()

        let log = logger
        // Yield once at the top of the spawned Task so that the synchronous
        // `inFlightBackfillTask = backfillTask` assignment below always lands
        // BEFORE the body runs. Without this gate a fast-completing Task
        // could finish, call `clearInFlight(matching: nil)` while the slot
        // is still empty, and then overwrite a NEWLY-stored handle with the
        // finished one — making subsequent `cancelInFlightBackfill()` calls
        // unable to cancel a genuinely in-flight earlier batch (Reviewer 8).
        let backfillTask = Task { [weak self] in
            await Task.yield()
            do {
                _ = try await coordinator.runBatch(
                    maxItems: DefaultSettings.Thumbnail.backfillBatchSize
                )
            } catch is CancellationError {
                // Pause-flip cancellation is expected — no log noise.
            } catch {
                log.error(
                    "BFS-tail backfill failed: \(DS3S3Client.describeSotoError(error), privacy: .public)"
                )
            }
            // Clear the handle once we're done so subsequent cancel calls
            // don't try to cancel a finished task. Pass `self?.lastBackfillTask`
            // path is irrelevant — we only clear if we still own the slot.
            self?.clearInFlightIfCurrent()
        }

        let sweepTask = Task {
            _ = await sweeper.sweep(
                bucket: bucket, drivePrefix: drivePrefix, enumeratedKeys: enumeratedKeys
            )
        }

        lock.lock()
        inFlightBackfillTask = backfillTask
        lastBackfillTask = backfillTask
        lastSweepTask = sweepTask
        lock.unlock()

        return LastSpawnedTasks(backfill: backfillTask, sweep: sweepTask)
    }

    /// Cancel the in-flight backfill Task if any. Called by the BFS indexer
    /// when it observes a drive-pause flip (D-20). The coordinator observes
    /// Swift Concurrency's structured cancellation signal at its per-iteration
    /// `Task.checkCancellation()` boundary.
    func cancelInFlightBackfill() {
        lock.lock()
        let task = inFlightBackfillTask
        inFlightBackfillTask = nil
        lock.unlock()
        task?.cancel()
    }

    // MARK: Test introspection

    /// Returns the last spawned tasks (or nil if `runHooks` has not been
    /// called). Test-only.
    var lastSpawned: LastSpawnedTasks {
        lock.lock()
        defer { lock.unlock() }
        return LastSpawnedTasks(backfill: lastBackfillTask, sweep: lastSweepTask)
    }

    // MARK: Internals

    private func clearInFlight(matching task: Task<Void, Never>?) {
        lock.lock()
        defer { lock.unlock() }
        if task == nil || inFlightBackfillTask == task {
            inFlightBackfillTask = nil
        }
    }

    /// Clears `inFlightBackfillTask` only if it still equals `lastBackfillTask`
    /// — the handle most recently spawned. The Task body calls this on
    /// completion. Combined with the `Task.yield()` gate at the top of the
    /// body, this guarantees we never clear a NEWER handle that a subsequent
    /// `runHooks` call has already stored.
    private func clearInFlightIfCurrent() {
        lock.lock()
        defer { lock.unlock() }
        if inFlightBackfillTask == lastBackfillTask {
            inFlightBackfillTask = nil
        }
    }
}
