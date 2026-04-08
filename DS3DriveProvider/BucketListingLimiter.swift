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

    private struct SlotState {
        var inFlight: Int = 0
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    init(maxConcurrent: Int = 4) {
        self.maxConcurrent = maxConcurrent
    }

    /// Runs the supplied body while holding a slot for the given bucket. The
    /// slot is released automatically on both success and throw paths.
    func withLimit<T>(bucket: String, _ body: () async throws -> T) async rethrows -> T {
        await acquire(bucket: bucket)
        do {
            let result = try await body()
            release(bucket: bucket)
            return result
        } catch {
            release(bucket: bucket)
            throw error
        }
    }

    private func acquire(bucket: String) async {
        var state = perBucket[bucket] ?? SlotState()

        if state.inFlight < maxConcurrent {
            state.inFlight += 1
            perBucket[bucket] = state
            return
        }

        // Enqueue as waiter; when resumed, the releaser has already incremented
        // inFlight on our behalf so we are safe to proceed.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            state.waiters.append(cont)
            perBucket[bucket] = state
        }
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
        next.resume()
    }
}
