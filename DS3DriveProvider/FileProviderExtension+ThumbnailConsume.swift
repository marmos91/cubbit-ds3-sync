import DS3Lib
@preconcurrency import FileProvider
import Foundation
import os.log

// MARK: - Cache-first thumbnail consume helpers (Phase 13 D-11, D-13)

/// Async closure type used by `consumeThumbnail` to fetch thumbnail bytes.
/// Returning `nil` denotes a 404 cache miss (silent contract from
/// `DS3S3ClientProtocol.getThumbnailBytes`). Throwing surfaces network /
/// auth / 5xx / SlowDown errors that `mapThumbnailFetchError` translates into
/// `NSFileProviderError`.
typealias ThumbnailByteFetcher = @Sendable (_ bucket: String, _ key: String) async throws -> Data?

/// Async closure type used by `consumeThumbnail` to mark an item `.pending`
/// after a 404 cache miss. Errors are silently swallowed by the caller —
/// failing to mark the item is non-fatal (the next BFS pass will reconcile).
typealias ThumbnailPendingMarker = @Sendable (_ s3Key: String, _ driveId: UUID) async -> Void

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
///    - MISS (nil): mark item `.pending` via `markPending`, then
///      `(id, nil, NSFileProviderError(.noSuchItem))` so Finder retries on
///      next browse (BFS picks up the `.pending` row in the next pass).
///    - THROW: route through `mapThumbnailFetchError` and pass the mapped
///      `NSFileProviderError` / `NSCocoaError` (CLAUDE.md mandate).
///
/// This consume path NEVER renders, NEVER downloads the original. THUMB-23.
@Sendable
func consumeThumbnail(
    identifier: NSFileProviderItemIdentifier,
    drive: DS3Drive,
    fetchBytes: ThumbnailByteFetcher,
    markPending: ThumbnailPendingMarker,
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
            // Cache MISS (404) — mark pending so the next BFS pass picks it up,
            // then tell Finder there's nothing right now. Finder draws the default
            // UTType icon and will re-ask on its next browse. (D-11)
            await markPending(identifier.rawValue, drive.id)
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
