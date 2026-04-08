import Foundation

/// Actor-based per-bucket concurrency limiter for S3 ListObjectsV2 requests.
///
/// On fresh mount, BreadthFirstIndexer, S3Enumerator, and TrashS3Enumerator all
/// call `listObjectsV2` concurrently against the bucket root. S3 responds with
/// HTTP 503 `SlowDown` when too many listings hit the same bucket at once, and
/// the enumerator-level fallback path would silently drop folders (Gap 28).
///
/// This actor caps concurrent listings per bucket to a small constant (default 4),
/// forcing excess callers to await a fair FIFO slot. Combined with
/// `listWithRetries` in `S3Lib.swift`, it keeps the provider well under the
/// server's throttling threshold while remaining responsive.
actor BucketListingLimiter {
    /// Shared instance used by all listing call sites in the extension.
    static let shared = BucketListingLimiter()

    private let maxConcurrent: Int
    private var perBucket: [String: SlotState] = [:]

    private struct Waiter {
        let id: UUID
        let cont: CheckedContinuation<Void, any Error>
    }

    private struct SlotState {
        var inFlight: Int = 0
        var waiters: [Waiter] = []
    }

    init(maxConcurrent: Int = 4) {
        self.maxConcurrent = maxConcurrent
    }

    /// Runs the supplied body while holding a slot for the given bucket. The
    /// slot is released automatically on both success and throw paths, and
    /// the wait is cancellation-aware: a task cancelled while queued is
    /// removed from the waiter list and throws `CancellationError` without
    /// running `body`.
    func withLimit<T>(bucket: String, _ body: () async throws -> T) async throws -> T {
        try await acquire(bucket: bucket)
        do {
            let result = try await body()
            release(bucket: bucket)
            return result
        } catch {
            release(bucket: bucket)
            throw error
        }
    }

    private func acquire(bucket: String) async throws {
        var state = perBucket[bucket] ?? SlotState()

        if state.inFlight < maxConcurrent {
            state.inFlight += 1
            perBucket[bucket] = state
            return
        }

        let waiterId = UUID()

        // Wrap the wait in `withTaskCancellationHandler` so cancellation
        // mid-wait removes the waiter from the queue and throws, instead
        // of leaking a slot (see Copilot review on `withCheckedContinuation`).
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
                state.waiters.append(Waiter(id: waiterId, cont: cont))
                perBucket[bucket] = state
            }
        } onCancel: {
            Task { [weak self] in
                await self?.cancelWaiter(bucket: bucket, id: waiterId)
            }
        }

        // If a releaser handed us the slot just as this task was cancelled,
        // release it back into the pool and propagate the cancellation so
        // `body` never runs with a cancelled parent task.
        if Task.isCancelled {
            release(bucket: bucket)
            throw CancellationError()
        }
    }

    private func cancelWaiter(bucket: String, id: UUID) {
        guard var state = perBucket[bucket] else { return }
        guard let index = state.waiters.firstIndex(where: { $0.id == id }) else {
            // Already handed the slot; the post-resume cancellation check
            // in `acquire` will release it.
            return
        }
        let waiter = state.waiters.remove(at: index)
        perBucket[bucket] = state
        waiter.cont.resume(throwing: CancellationError())
    }

    private func release(bucket: String) {
        guard var state = perBucket[bucket] else { return }

        if state.waiters.isEmpty {
            state.inFlight -= 1
            if state.inFlight <= 0 {
                perBucket.removeValue(forKey: bucket)
            } else {
                perBucket[bucket] = state
            }
            return
        }

        // Hand the slot directly to the next waiter — keeps inFlight stable.
        let next = state.waiters.removeFirst()
        perBucket[bucket] = state
        next.cont.resume()
    }
}
