import DS3Lib
@preconcurrency import FileProvider
import Foundation
import os.log
#if os(iOS)
    import ThumbnailQueue
#elseif os(macOS)
    import ThumbnailRendering
#endif

// MARK: - Cache-first thumbnail consume helpers (Phase 13 D-11, D-13)

/// Async closure type used by `consumeThumbnail` to fetch thumbnail bytes.
/// Returning `nil` denotes a 404 cache miss (silent contract from
/// `DS3S3ClientProtocol.getThumbnailBytes`). Throwing surfaces network /
/// auth / 5xx / SlowDown errors that `mapThumbnailFetchError` translates into
/// `NSFileProviderError`.
typealias ThumbnailByteFetcher = @Sendable (_ bucket: String, _ key: String) async throws -> Data?

/// Per-thumbnail completion handler signature mirroring `NSFileProviderThumbnailing`.
typealias PerThumbnailCompletionHandler =
    @Sendable (NSFileProviderItemIdentifier, Data?, Error?) -> Void

/// Cache-first consume implementation for a single thumbnail (Phase 13, Plan 13-06, D-11).
///
/// Pipeline:
/// 1. Folder / root container / non-raster identifier → `(id, nil, nil)` and return.
///    Finder draws the default UTType icon; no S3 call; no metadata write.
/// 2. Compute `thumbKey` via `S3PathUtils.thumbnailKey(...)`.
/// 3. `await fetchBytes(bucket, thumbKey)`.
///    - HIT (non-nil Data): `(id, data, nil)`.
///    - MISS (nil): `(id, nil, NSFileProviderError(.noSuchItem))` — the unique
///      cache-miss sentinel that the caller's interceptor uses to route into
///      `consumeThumbnailFallback` for reactive render+PUT (Phase 13.2 Plan 02).
///    - THROW: route through `mapThumbnailFetchError` and pass the mapped
///      `NSFileProviderError` / `NSCocoaError` (CLAUDE.md mandate).
///
/// This consume path NEVER renders, NEVER downloads the original. THUMB-23.
///
/// Phase 13.2 Plan 09 (D-05, D-08, D-23): the `markPending` parameter was
/// stripped — Schema V6 removed `thumbnailStatus` and the BFS coordinator
/// that consumed it is gone. The cache-miss sentinel is the only thing the
/// caller needs to route into the reactive fallback path.
@Sendable
func consumeThumbnail(
    identifier: NSFileProviderItemIdentifier,
    drive: DS3Drive,
    fetchBytes: ThumbnailByteFetcher,
    perItemHandler: PerThumbnailCompletionHandler
) async {
    // 1. Folders / root container — no thumbnail; default icon is the right answer.
    if identifier == .rootContainer
        || identifier == .trashContainer
        || identifier == .workingSet
        || identifier.rawValue.hasSuffix(String(DefaultSettings.S3.delimiter)) {
        perItemHandler(identifier, nil, nil)
        return
    }

    // 2. Non-raster pre-filter — skip S3 round-trip; Finder will use UTType icon.
    let filename = String(identifier.rawValue.split(separator: "/").last ?? "")
    let pathExtension = (filename as NSString).pathExtension
    guard S3PathUtils.isRasterExtension(pathExtension) else {
        perItemHandler(identifier, nil, nil)
        return
    }

    // 3. Compute the cache key and fetch bytes.
    let thumbKey = S3PathUtils.thumbnailKey(
        forOriginalKey: identifier.rawValue,
        drivePrefix: drive.syncAnchor.prefix
    )
    let bucket = drive.syncAnchor.bucket.name

    do {
        let bytes = try await fetchBytes(bucket, thumbKey)
        if let bytes {
            // Cache HIT — return bytes, no error. (D-11)
            perItemHandler(identifier, bytes, nil)
        } else {
            // Cache MISS (404) — return the unique sentinel
            // `NSFileProviderError(.noSuchItem)` so the caller's interceptor
            // can route into `consumeThumbnailFallback` (Phase 13.2 Plan 02).
            // `mapThumbnailFetchError` never returns `.noSuchItem`, so this
            // sentinel is unambiguous.
            #if os(iOS)
                // Phase 14 Part 2: enqueue for background rendering in the main app.
                // Synchronous: extension can be reaped immediately after responding
                // to fetchThumbnails, so a detached Task would lose its work. We're
                // already in async context, the append is a small file write, and
                // perItemHandler still fires before this function returns.
                await ThumbnailRenderQueue.shared.append(
                    ThumbnailRenderQueueItem(driveID: drive.id, s3Key: identifier.rawValue)
                )
                DarwinNotificationCenter.shared.post(name: DarwinNotificationCenter.thumbnailRenderRequest)
            #endif
            perItemHandler(identifier, nil, NSFileProviderError(.noSuchItem) as NSError)
        }
    } catch {
        // 4. Map the below-the-seam error to one of the THREE allowed
        //    NSFileProviderError codes — strictly NSFileProviderErrorDomain
        //    or NSCocoaErrorDomain. (D-13, CLAUDE.md, MEMORY.md)
        let mapped = mapThumbnailFetchError(error)
        perItemHandler(identifier, nil, mapped)
    }
}

/// Translates a below-the-seam error from the consume path into one of the
/// allowed `NSFileProviderError` codes (`.noSuchItem`, `.serverUnreachable`,
/// `.cannotSynchronize`, `.notAuthenticated`). Per Phase 13 D-13:
///
/// - Recoverable auth errors (`isRecoverableAuthError`: expired tokens,
///   bad signatures) → `.cannotSynchronize` (drive enters error state via
///   existing UX; credential rotation may resolve).
/// - Permanent permission denials (`AccessDenied`, `AllAccessDisabled`) →
///   `.notAuthenticated` (credential rotation can NOT fix bucket-policy
///   denials — surface a distinct UX so the user sees the auth boundary).
/// - S3 throttling / 5xx (`s3ErrorCode` ∈ {`SlowDown`, `RequestTimeout`,
///   `ServiceUnavailable`, `InternalError`}) → `.serverUnreachable`
///   (Finder retries naturally; D-14: NO inline retry here).
/// - URLError network failures → `.serverUnreachable`.
/// - Unknown errors → `.cannotSynchronize` (conservative default).
///
/// CRITICAL: the returned `NSError`'s `domain` MUST be either
/// `NSFileProviderErrorDomain` or `NSCocoaErrorDomain`. A custom domain
/// (e.g. SotoCore's) crossing the boundary triggers
/// `Provider returned error 0 from domain ... which is unsupported`
/// — see MEMORY.md.
func mapThumbnailFetchError(_ error: Error) -> NSError {
    // Order matters: check recoverable auth FIRST so a 403/401-from-S3 with a
    // recoverable code doesn't get caught by the "unknown" fallback.
    if DS3S3Client.isRecoverableAuthError(error) {
        return NSFileProviderError(.cannotSynchronize) as NSError
    }

    // Inspect the S3 error code once and route by category.
    if let code = DS3S3Client.s3ErrorCode(from: error) {
        // Permanent permission denials — credential rotation can't fix
        // bucket-policy denials, so map to .notAuthenticated rather than
        // .cannotSynchronize (which would trigger pointless retries).
        if permanentPermissionDeniedS3Codes.contains(code) {
            return NSFileProviderError(.notAuthenticated) as NSError
        }
        // S3 throttling / transient server errors — Finder retries naturally.
        if throttlingS3ErrorCodes.contains(code) {
            return NSFileProviderError(.serverUnreachable) as NSError
        }
    }

    // Network-layer failures (URLError) also map to serverUnreachable.
    if let urlError = error as? URLError {
        switch urlError.code {
        case .notConnectedToInternet,
             .timedOut,
             .networkConnectionLost,
             .cannotConnectToHost,
             .dnsLookupFailed,
             .cannotFindHost,
             .resourceUnavailable:
            return NSFileProviderError(.serverUnreachable) as NSError
        default:
            // Other URLError codes (e.g. cancelled) are unusual on this path —
            // fall through to cannotSynchronize.
            break
        }
    }

    // Unknown error — surface drive-level error UX. Conservative default.
    return NSFileProviderError(.cannotSynchronize) as NSError
}

/// S3 error codes that indicate a permanent permission denial (bucket policy /
/// IAM denial) where credential rotation will NOT recover access. Mapped to
/// `.notAuthenticated` rather than `.cannotSynchronize`.
let permanentPermissionDeniedS3Codes: Set<String> = [
    "AccessDenied",
    "AllAccessDisabled"
]

/// S3 error codes that indicate a transient server / throttling condition.
/// Per Phase 13 D-13, D-14: these map to `.serverUnreachable`, NEVER trigger
/// inline retry inside the limiter slot.
let throttlingS3ErrorCodes: Set<String> = [
    "SlowDown",
    "RequestTimeout",
    "ServiceUnavailable",
    "InternalError"
]

// MARK: - Phase 13.2 cache-miss fallback fork (D-01..D-04, D-12, D-19, D-20, D-24)

/// Closure that downloads the original S3 object backing `identifier` to a
/// local file URL and returns `(fileURL, sourceETag?)`. Production wires this
/// to `S3Lib.downloadS3Item`; tests inject a stub.
///
/// Cross-platform: also referenced by the upload-hook (`+ThumbnailUploadHook.swift`),
/// whose signature compiles on iOS even though its body is macOS-only.
typealias ThumbnailOriginalDownloader =
    @Sendable (NSFileProviderItemIdentifier, DS3Drive) async throws -> (URL, String?)

#if os(macOS)
    /// Closure that renders a JPEG thumbnail from a local original. Returns
    /// `.failure(RenderFailure)` when the bytes don't decode (corrupt file,
    /// unsupported UTI, etc.) — the failure case names the specific reason
    /// (see `RenderFailure` in `ThumbnailRendering`). Production wires this to
    /// `ThumbnailRenderer().renderJPEG(from:)`.
    typealias ThumbnailRendererFn = @Sendable (URL) -> Result<Data, RenderFailure>

    /// Closure that PUTs the rendered JPEG to S3. Production wires this to
    /// `s3Client.putThumbnail(bucket:key:data:sourceETag:)`.
    typealias ThumbnailFallbackPutter =
        @Sendable (_ bucket: String, _ key: String, _ data: Data, _ sourceETag: String) async throws -> Void

    /// Closure that signals a parent container to re-enumerate (D-12). Production
    /// wires this to `NSFileProviderManager(for: domain).signalEnumerator(for:)`.
    typealias ThumbnailSignalContainer = @Sendable (NSFileProviderItemIdentifier) -> Void

    /// Bundle of closure-based dependencies for `consumeThumbnailFallback`.
    /// Keeps the function under the SwiftLint parameter-count limit and keeps
    /// the production wiring (in `+Thumbnails.swift`) explicit + Sendable.
    struct ThumbnailFallbackContext {
        let limiter: ThumbnailFallbackLimiter
        let download: ThumbnailOriginalDownloader
        let render: ThumbnailRendererFn
        let putThumbnail: ThumbnailFallbackPutter
        let signalParentContainer: ThumbnailSignalContainer
        let logger: os.Logger
    }

    /// Cache-miss fallback for `fetchThumbnails` (Phase 13.2, D-01..D-04, D-12,
    /// D-19, D-20, THUMB-15).
    ///
    /// Sequence (each step is a hard precondition for the next):
    /// 1. **Poison check (D-19, D-20):** if `limiter.isPoisoned(key)` → return nil
    ///    immediately. No download, no render, no slot acquired.
    /// 2. **Acquire** a slot from the 2-slot `ThumbnailFallbackLimiter` (D-02).
    ///    Cancellation maps to `NSUserCancelledError`.
    /// 3. **Download** original via the `download` closure. On throw → record
    ///    strike, map error via `mapThumbnailFetchError`, return mapped error.
    /// 4. **Render** via the `render` closure. `.failure(...)` → record strike,
    ///    return `.noSuchItem`.
    /// 5. **Lane 2 (D-01 lane 2, D-04):** invoke `perItemHandler` with rendered
    ///    bytes BEFORE issuing the PUT — the user sees the thumbnail immediately.
    /// 6. **Lane 3 (D-01 lane 3, D-04, D-12):** fire-and-forget `Task.detached`
    ///    that PUTs the SAME bytes to `.thumbnails/<key>.jpg` then calls
    ///    `signalParentContainer(parentId)`. PUT failures are logged via
    ///    `describeSotoError` but do NOT record a strike (the user already saw
    ///    the thumbnail; failed PUT just means the next visit re-renders).
    ///
    /// **Sendable rules (Pitfall 1):** Free function, NOT a method on
    /// `FileProviderExtension`. Never captures `self`. All closure parameters are
    /// `@Sendable`. The detached `Task` captures only sendable locals.
    ///
    /// **Error handling (THUMB-13):** All errors crossing the per-item handler
    /// boundary are mapped through `mapThumbnailFetchError` to
    /// `NSFileProviderErrorDomain` or `NSCocoaErrorDomain` only.
    @Sendable
    func consumeThumbnailFallback(
        identifier: NSFileProviderItemIdentifier,
        drive: DS3Drive,
        context: ThumbnailFallbackContext,
        perItemHandler: PerThumbnailCompletionHandler
    ) async {
        let key = identifier.rawValue
        let limiter = context.limiter
        let logger = context.logger

        // Step 1 — Poison check (D-19, D-20). Skip everything for poisoned keys.
        if await limiter.isPoisoned(key) {
            logger.info("Fallback: skipping poisoned key \(key, privacy: .public)")
            perItemHandler(identifier, nil, nil)
            return
        }

        // Step 2 — Acquire a slot (D-02). Cancellation maps to NSUserCancelledError.
        do {
            try await limiter.acquire()
        } catch is CancellationError {
            perItemHandler(
                identifier,
                nil,
                NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)
            )
            return
        } catch {
            perItemHandler(identifier, nil, mapThumbnailFetchError(error))
            return
        }

        // Steps 3–6 — Download → render → return bytes → fire-and-forget PUT.
        // Code review Fix 2 (Phase 13.2): release explicitly on every exit path
        // rather than via `defer { Task { await release } }`. Spawning an
        // unstructured Task to return the slot delays the hand-off by an extra
        // task hop and risks slot leaks under teardown if the spawned Task is
        // never scheduled. Explicit `await limiter.release()` before each return
        // guarantees the slot is returned synchronously within this Task.
        do {
            let (fileURL, sourceETag) = try await context.download(identifier, drive)
            defer { try? FileManager.default.removeItem(at: fileURL) }

            // Step 4 — Render. A failure records a strike but is NOT an error
            // surfaced to Finder beyond `.noSuchItem` (Finder draws default icon).
            let renderResult = context.render(fileURL)
            let jpegBytes: Data
            switch renderResult {
            case let .success(bytes):
                jpegBytes = bytes
            case let .failure(reason):
                await limiter.recordFailure(key)
                logger.info(
                    "Fallback: render failed for \(key, privacy: .public) — reason=\(reason.rawValue, privacy: .public)"
                )
                perItemHandler(identifier, nil, NSFileProviderError(.noSuchItem) as NSError)
                await limiter.release()
                return
            }

            // Step 5 — Lane 2 (D-04): bytes returned to Finder are the same bytes
            // PUT to S3. Single render. The success callback to the limiter
            // resets the strike counter for this key.
            perItemHandler(identifier, jpegBytes, nil)
            await limiter.recordSuccess(key)

            // Step 6 — Lane 3 (D-12): fire-and-forget PUT + signalEnumerator.
            // Detached so the per-item handler ordering contract is not violated
            // by network latency. PUT failures are logged + swallowed.
            let bucket = drive.syncAnchor.bucket.name
            let drivePrefix = drive.syncAnchor.prefix
            let parentKeyOpt = S3PathUtils.parentKey(forKey: key, drivePrefix: drivePrefix)
            let parentId: NSFileProviderItemIdentifier =
                parentKeyOpt.map { NSFileProviderItemIdentifier($0) } ?? .rootContainer
            let thumbKey = S3PathUtils.thumbnailKey(
                forOriginalKey: key, drivePrefix: drivePrefix
            )
            // Capture the source ETag (or empty string if S3 didn't surface one).
            // `putThumbnail` requires a non-optional sourceETag for the
            // `x-amz-meta-source-etag` header; downstream cascades observe an
            // empty value and treat it as "unknown source" — same semantic as
            // a fresh upload via `enqueueThumbnailUpload` when the ETag races.
            let etagForPut = sourceETag ?? ""
            let putFn = context.putThumbnail
            let signalFn = context.signalParentContainer

            Task.detached(priority: .background) {
                do {
                    try await putFn(bucket, thumbKey, jpegBytes, etagForPut)
                    logger.info("Fallback: PUT succeeded for \(thumbKey, privacy: .public)")
                    // D-12: signal the parent so Apple re-enumerates and the
                    // next fetchThumbnails hits the now-warm cache.
                    signalFn(parentId)
                } catch {
                    logger.error(
                        "Fallback PUT failed for \(thumbKey, privacy: .public): \(DS3S3Client.describeSotoError(error), privacy: .public)"
                    )
                    // No recordFailure here — the bytes already reached Finder;
                    // the user saw a thumbnail. Failed PUT just means the next
                    // visit re-renders.
                }
            }
            await limiter.release()
        } catch {
            await limiter.recordFailure(key)
            logger.error(
                "Fallback render failed for \(key, privacy: .public): \(DS3S3Client.describeSotoError(error), privacy: .public)"
            )
            perItemHandler(identifier, nil, mapThumbnailFetchError(error))
            await limiter.release()
        }
    }
#endif
