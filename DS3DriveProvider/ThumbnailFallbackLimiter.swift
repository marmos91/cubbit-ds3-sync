import Foundation

/// Bounds concurrent thumbnail-fallback renders to a small number of slots.
///
/// Phase 13.2 (D-02): the cache-miss fallback path downloads the original
/// from S3 and runs `ThumbnailRenderer` locally. Originals can be 30-50 MB
/// HEIC files; the macOS extension memory ceiling is ~50 MB. This limiter
/// caps concurrent heavy renders at 2 — strict separation from the 4-slot
/// `ThumbnailFetchLimiter` (which gates the cheap cached-thumb GET path).
///
/// In-memory strike counter (D-19, D-20, D-21) replaces the dying
/// Schema V4 `thumbnailFailCount` field. State resets on extension restart.
/// Acceptable because the macOS extension is long-lived (hours-days) and
/// real poison files are deterministic decode failures, not transient.
///
/// FIFO ordering, cancellation handling, and slot hand-off semantics mirror
/// `ThumbnailFetchLimiter` verbatim — the pattern is battle-tested.
actor ThumbnailFallbackLimiter {
    private struct Waiter {
        let id: UUID
        let cont: CheckedContinuation<Void, any Error>
    }

    private let maxSlots: Int
    private var inFlight = 0
    private var waiters: [Waiter] = []

    // D-19: per-S3-key strike counter, reset only on extension restart.
    private var strikeCount: [String: Int] = [:]
    // D-19: poison-key set; once added, fallback path skips entirely.
    private var poisonKeys: Set<String> = []

    private static let maxStrikes = 3

    init(maxSlots: Int = 2) {
        self.maxSlots = maxSlots
    }

    // MARK: - FIFO acquire/release (analog of ThumbnailFetchLimiter)

    /// Acquires a slot. Suspends in FIFO order if all slots are taken.
    /// Throws `CancellationError` if the calling Task is cancelled — either
    /// while suspended (`withTaskCancellationHandler` removes the waiter and
    /// throws) or immediately after resume (the post-resume `Task.isCancelled`
    /// check returns the handed-off slot to the pool before throwing).
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
            // Code review Fix 5 (Phase 13.2): the limiter is system-level
            // infrastructure retained by `FileProviderExtension` for the
            // process lifetime. A `[weak self]` capture here is misleading:
            // `self` cannot deinit while a waiter is suspended on its
            // continuation, and a weak capture would silently swallow the
            // cancel-resume if it ever did. Strong capture is correct.
            Task { [self] in
                await self.cancelWaiter(id: waiterId)
            }
        }

        if Task.isCancelled {
            release()
            throw CancellationError()
        }
    }

    /// Releases a slot. If a waiter is queued, hands the slot directly to it
    /// (keeps `inFlight` stable across the hand-off).
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

    // MARK: - Strike counter + poison set (D-19, D-20)

    /// Returns true if this key is poisoned and the caller should skip
    /// download + render entirely (return nil to perThumbnailCompletionHandler).
    func isPoisoned(_ key: String) -> Bool {
        poisonKeys.contains(key)
    }

    /// Increment counter; on 3rd strike, move into poison set and clear
    /// the counter entry. Idempotent for already-poisoned keys.
    func recordFailure(_ key: String) {
        if poisonKeys.contains(key) { return }
        let next = (strikeCount[key] ?? 0) + 1
        if next >= Self.maxStrikes {
            strikeCount.removeValue(forKey: key)
            poisonKeys.insert(key)
        } else {
            strikeCount[key] = next
        }
    }

    /// Reset strike counter for `key` after a successful render+PUT cycle.
    /// Keeps the counter from accumulating for transient errors that
    /// eventually resolve (network blip → retry succeeds).
    func recordSuccess(_ key: String) {
        strikeCount.removeValue(forKey: key)
    }

    // MARK: - Test introspection

    /// Number of slots currently held. Test-only.
    var inFlightCount: Int {
        inFlight
    }

    /// Number of waiters currently suspended. Test-only.
    var waiterCount: Int {
        waiters.count
    }

    /// Strike count for a given key (0 if unknown). Test-only.
    func strikeCountForTest(_ key: String) -> Int {
        strikeCount[key] ?? 0
    }

    /// Number of keys currently in the poison set. Test-only.
    var poisonCount: Int {
        poisonKeys.count
    }
}
