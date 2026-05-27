import Foundation

/// Caps concurrent S3 GET requests for thumbnail consumption (`fetchThumbnails`)
/// to avoid S3 SlowDown under bursty Finder folder-open fanout.
///
/// Slots = 4 on macOS (Phase 13 D-12, THUMB-14). The upload-path generator and the
/// backfill coordinator have their own concurrency lanes — they MUST NOT route
/// through this limiter (Pitfall 4: cross-lane contention).
///
/// Lifecycle: `ThumbnailFetchLimiter` is owned by `FileProviderExtension`
/// (held as `private let`). The extension instance lives for the entire extension
/// process lifetime — `fileproviderd` only releases it on process exit. Therefore
/// deinit-while-waiters-are-suspended is structurally impossible in production:
/// by the time the limiter would deinit, the process is exiting and any suspended
/// continuations are torn down with the process. We do NOT need a deinit hook to
/// resume orphan continuations.
///
/// FIFO ordering is guaranteed: waiters are queued via `append` and dequeued via
/// `removeFirst`. Test 4 in `ThumbnailFetchLimiterTests` pins this guarantee
/// against future refactors.
///
/// Cancellation: a task cancelled while queued is removed from the waiter list
/// via `withTaskCancellationHandler` and resumed with `CancellationError`. A
/// task that is handed a slot just as it is cancelled checks `Task.isCancelled`
/// after resume and returns the slot to the pool before throwing.
actor ThumbnailFetchLimiter {
    private struct Waiter {
        let id: UUID
        let cont: CheckedContinuation<Void, any Error>
    }

    private let maxSlots: Int
    private var inFlight = 0
    private var waiters: [Waiter] = []

    init(maxSlots: Int) {
        self.maxSlots = maxSlots
    }

    /// Acquires a slot. Suspends in FIFO order if all slots are taken.
    /// Throws `CancellationError` if the calling Task is cancelled — either
    /// before suspending (early-detect path), while suspended
    /// (`withTaskCancellationHandler` removes the waiter and throws), or
    /// immediately after resume (the post-resume `Task.isCancelled` check
    /// returns the handed-off slot to the pool before throwing).
    ///
    /// Cancellation propagation is REQUIRED so `fetchThumbnails` can satisfy
    /// `NSFileProviderThumbnailing`'s ordering contract: every per-item
    /// handler must fire BEFORE `completeFinal` does. With a non-throwing
    /// continuation a cancelled child Task could resume after `completeFinal`
    /// has already returned, violating the contract.
    func acquire() async throws {
        if Task.isCancelled {
            throw CancellationError()
        }
        if inFlight < maxSlots {
            inFlight += 1
            return
        }

        let waiterId = UUID()

        // Wrap the wait in `withTaskCancellationHandler` so cancellation
        // mid-wait removes the waiter from the queue and throws, instead
        // of leaving the continuation suspended forever (mirrors
        // `BucketListingLimiter` — same Copilot review pattern).
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
                waiters.append(Waiter(id: waiterId, cont: cont))
            }
        } onCancel: {
            Task { [weak self] in
                await self?.cancelWaiter(id: waiterId)
            }
        }

        // If a releaser handed us the slot just as this task was cancelled,
        // release it back into the pool and propagate the cancellation so
        // the caller (consumeThumbnail's per-item path) doesn't run after
        // `completeFinal` has already fired in `fetchThumbnails`.
        if Task.isCancelled {
            release()
            throw CancellationError()
        }
        // After resume, the slot was already counted by `release()` (it hands the
        // slot directly to the next waiter, keeping `inFlight` stable across the
        // hand-off). DO NOT increment `inFlight` here.
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            // Already handed the slot; the post-resume `Task.isCancelled`
            // check in `acquire` will release it.
            return
        }
        let waiter = waiters.remove(at: index)
        waiter.cont.resume(throwing: CancellationError())
    }

    /// Releases a slot. If a waiter is queued, hands the slot directly to it
    /// (keeps `inFlight` stable across the hand-off).
    func release() {
        if !waiters.isEmpty {
            let next = waiters.removeFirst()
            next.cont.resume()
        } else {
            inFlight -= 1
        }
    }

    // MARK: - Test introspection

    /// Number of slots currently held. Test-only; do not use in production code.
    var inFlightCount: Int {
        inFlight
    }

    /// Number of waiters currently suspended. Test-only.
    var waiterCount: Int {
        waiters.count
    }
}
