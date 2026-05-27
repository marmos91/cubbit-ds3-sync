import Foundation

/// Admission-gate for the upload-time (eager) thumbnail generator.
///
/// Issue #141: bulk uploads spawned unbounded `Task.detached(priority: .background)`
/// calls into `ThumbnailRenderer`, racing into ImageIO under concurrent decode
/// pressure (silent nil returns) AND reading the FileProvider temp URL after it
/// could be invalidated. This limiter caps concurrent render+PUT to `maxSlots`
/// and drops new work past `softMaxWaiters` so very large imports degrade
/// gracefully — overflow falls through to the consume-path fallback on first
/// view.
///
/// Slots = 2 by default — same as `ThumbnailFallbackLimiter`. The eager path
/// now downloads the original from S3 (same bytes-source as the fallback), so
/// the same slot count is appropriate. Separate instance keeps the eager and
/// lazy paths from starving each other.
///
/// Soft cap = 64 waiters by default. Pending jobs are suspended Tasks (no
/// bytes, no disk), but unbounded waiter accumulation under huge imports is
/// still pathological. 64 covers the issue's 15-file repro with ~4× headroom.
///
/// Lifecycle / FIFO / cancellation semantics mirror `ThumbnailFetchLimiter`
/// verbatim (the pattern is battle-tested). NO strike counter, NO poison set
/// — those are consume-path concerns and stay in `ThumbnailFallbackLimiter`.
actor ThumbnailUploadLimiter {
    private struct Waiter {
        let id: UUID
        let cont: CheckedContinuation<Void, any Error>
    }

    private let maxSlots: Int
    private let softMaxWaiters: Int
    private var inFlight = 0
    private var waiters: [Waiter] = []

    init(maxSlots: Int = 2, softMaxWaiters: Int = 64) {
        self.maxSlots = maxSlots
        self.softMaxWaiters = softMaxWaiters
    }

    /// Returns true if the limiter's WAITER queue is at or above
    /// `softMaxWaiters`. Callers use this BEFORE spawning a detached Task
    /// so they can drop overflow work without blocking. Soft because we
    /// never block the producer; we just log and skip.
    ///
    /// Counts only suspended waiters, not in-flight slots — so the
    /// effective ceiling on concurrent in-progress work is
    /// `softMaxWaiters + maxSlots` (66 with the defaults). Treat the
    /// value as an order-of-magnitude ceiling, not a precise capacity.
    var isAtSoftCap: Bool {
        waiters.count >= softMaxWaiters
    }

    /// Acquires a slot. Suspends FIFO if all slots are taken. Throws
    /// `CancellationError` if the calling Task is cancelled.
    /// See `ThumbnailFetchLimiter.acquire()` for cancellation rationale.
    func acquire() async throws {
        if Task.isCancelled {
            throw CancellationError()
        }
        if inFlight < maxSlots {
            inFlight += 1
            return
        }

        let waiterId = UUID()

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
                waiters.append(Waiter(id: waiterId, cont: cont))
            }
        } onCancel: {
            // The limiter is system-level infrastructure retained by
            // `FileProviderExtension` for the process lifetime. A `[weak self]`
            // capture here is misleading: `self` cannot deinit while a waiter
            // is suspended on its continuation, and a weak capture would
            // silently swallow the cancel-resume if it ever did, leaving the
            // continuation orphaned and leaking the slot. Strong capture is
            // correct. (Mirrors `ThumbnailFallbackLimiter` Code review Fix 5.)
            Task { [self] in
                await self.cancelWaiter(id: waiterId)
            }
        }

        if Task.isCancelled {
            release()
            throw CancellationError()
        }
    }

    /// Releases a slot. Hands directly to the next waiter if any.
    func release() {
        if !waiters.isEmpty {
            let next = waiters.removeFirst()
            next.cont.resume()
        } else {
            inFlight = max(0, inFlight - 1)
        }
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        let waiter = waiters.remove(at: index)
        waiter.cont.resume(throwing: CancellationError())
    }

    // MARK: - Test introspection

    var inFlightCount: Int {
        inFlight
    }
    var waiterCount: Int {
        waiters.count
    }
}
