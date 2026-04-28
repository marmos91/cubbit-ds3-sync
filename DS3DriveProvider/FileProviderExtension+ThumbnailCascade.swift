import DS3Lib
@preconcurrency import FileProvider
import Foundation
import os.log

// MARK: - Delete + rename/move thumbnail cascade hooks (Phase 13 D-21, D-22, D-24; THUMB-17, THUMB-18)

// Free-function entry points called from `deleteItem` (post-original-delete) and
// `modifyItem` (rename/move branch, when content has NOT also changed) to fan out
// thumbnail cleanup work as fire-and-forget detached Tasks.
//
// Plan 13-08 design notes:
// - Free functions (NOT methods on `FileProviderExtension`) so the call site captures
//   only sendable values — the FP extension subclass inherits from `NSObject` and is
//   NOT `Sendable` under Swift 6 strict concurrency. Mirrors Plan 13-07's
//   `enqueueThumbnailUpload` pattern (Pitfall 1 in 13-RESEARCH.md).
// - `Task.detached` opens a fresh isolation domain decoupled from the user-visible
//   delete/rename completion handlers (D-06 lifecycle decoupling). The handler returns
//   success BEFORE the detached Task runs any cascade work.
// - Pre-filter via `S3PathUtils.isRasterExtension`: non-raster originals never schedule
//   any cascade work (D-08 — the `.thumbnails/` namespace only ever held a key for them
//   if a previous render existed; the rare orphan is reclaimed by Plan 13-09's sweep).
// - Errors inside the detached Tasks are logged at `.error` / `.warning` and SWALLOWED —
//   they never propagate to the user-visible delete/rename contracts. THUMB-06 / THUMB-17
//   / THUMB-18 mandate this lifecycle decoupling.
//
// **NEVER capture `self` inside the detached Task** — pass sendable locals only:
// `s3Client` (Sendable), `metadataStore` (`@ModelActor`), `drive` (`@unchecked Sendable`),
// strings, and the logger.

// MARK: Delete cascade (D-21, THUMB-17)

/// Fire-and-forget delete cascade after the original-file S3 delete succeeds.
///
/// Calls `s3Client.deleteThumbnail(bucket:key:)` with the thumbnail key derived
/// via `S3PathUtils.thumbnailKey(...)`. 404s are silent (Phase 12 D-14 contract).
/// Other failures are logged + swallowed; orphan sweep (Plan 13-09) is the backstop.
///
/// Per Phase 13 D-21.
@Sendable
func enqueueThumbnailDeleteCascade(
    originalKey: String,
    drive: DS3Drive,
    s3Client: any DS3S3ClientProtocol,
    logger: os.Logger
) {
    let pathExtension = (originalKey as NSString).pathExtension
    guard S3PathUtils.isRasterExtension(pathExtension) else { return }

    // Capture sendable locals before opening the detached Task. NEVER capture `self`.
    let bucket = drive.syncAnchor.bucket.name
    let drivePrefix = drive.syncAnchor.prefix
    let key = originalKey

    Task.detached(priority: .background) {
        let thumbKey = S3PathUtils.thumbnailKey(forOriginalKey: key, drivePrefix: drivePrefix)
        do {
            try await s3Client.deleteThumbnail(bucket: bucket, key: thumbKey)
        } catch {
            // D-21: errors NEVER propagate to the user-visible delete contract — log + swallow.
            // Orphan sweep (Plan 13-09) reclaims the leaked thumb on the next pass.
            //
            // Phase 13.1 Finding 5 (D-07): demote NoSuchKey to .info — the thumbnail
            // is already gone (orphan sweep / prior cascade beat us), which is the
            // success post-condition of this very call. Logging at .error creates noise.
            if DS3S3Client.isNotFoundError(error) {
                logger.info(
                    "Delete cascade: thumbnail already absent (NoSuchKey) for \(thumbKey, privacy: .public)"
                )
            } else {
                logger.error(
                    "Delete cascade failed for \(thumbKey, privacy: .public): \(DS3S3Client.describeSotoError(error), privacy: .public)"
                )
            }
        }
    }
}

// MARK: Rename / move cascade (D-22, D-24, THUMB-18)

/// Fire-and-forget rename/move cascade after the original-file rename/move completes.
///
/// Server-side `copyThumbnail(old → new)` preserves the source-ETag metadata
/// (Plan 13-03 D-23) so the consume path's freshness check still validates against
/// the original after the rename. Then `deleteThumbnail(old)` reclaims the old key.
///
/// Failure modes (D-22):
/// - Copy failure → mark new originalKey `.pending` so backfill (Plan 13-05 / 13-09)
///   regenerates the thumbnail from the new original. We do NOT call deleteThumbnail
///   on the old key in this path: the old thumbnail is the only surviving fresh copy
///   until backfill completes; orphan sweep will reclaim it once the new is uploaded.
/// - Delete-old failure → swallowed (orphan sweep is the backstop).
///
/// Per Phase 13 D-22, D-24.
///
/// **Call-site contract (enforced in `+Modify.swift`):** when `modifyItem` receives
/// both `.contents` AND a rename/move, the rename cascade is SUPPRESSED — Plan 13-07's
/// content-change hook already wrote a fresh thumb at the new key; copying the old over
/// it would overwrite the fresh render with a stale one. See Test 11 in CascadeRenameTests.
@Sendable
func enqueueThumbnailRenameCascade(
    oldOriginalKey: String,
    newOriginalKey: String,
    drive: DS3Drive,
    s3Client: any DS3S3ClientProtocol,
    metadataStore: MetadataStore,
    logger: os.Logger
) {
    let pathExtension = (newOriginalKey as NSString).pathExtension
    guard S3PathUtils.isRasterExtension(pathExtension) else { return }

    // Capture sendable locals before opening the detached Task. NEVER capture `self`.
    let bucket = drive.syncAnchor.bucket.name
    let drivePrefix = drive.syncAnchor.prefix
    let driveId = drive.id
    let oldKey = oldOriginalKey
    let newKey = newOriginalKey

    Task.detached(priority: .background) {
        let oldThumbKey = S3PathUtils.thumbnailKey(forOriginalKey: oldKey, drivePrefix: drivePrefix)
        let newThumbKey = S3PathUtils.thumbnailKey(forOriginalKey: newKey, drivePrefix: drivePrefix)

        // 1. Server-side copy old → new (preserves x-amz-meta-source-etag per D-23).
        do {
            try await s3Client.copyThumbnail(
                bucket: bucket, fromKey: oldThumbKey, toKey: newThumbKey
            )
        } catch {
            // D-22 fallback: mark NEW originalKey .pending so backfill regenerates.
            // We do NOT call deleteThumbnail(old) here — the old thumb is the only
            // surviving fresh copy; orphan sweep will reclaim it after backfill writes
            // the new thumb. Per Pitfall 5.
            //
            // Phase 13.1 Finding 5 (D-07): NoSuchKey here means the source thumbnail
            // was already swept (post-Finding-4 fix this is rare; pre-fix it was
            // common — Finding 4 false-positive deletes). The .pending fallback
            // (D-08) still fires as defense-in-depth so backfill regenerates from
            // the new original. Log at .info — this is an expected race, not an
            // error worth alerting on.
            if DS3S3Client.isNotFoundError(error) {
                logger.info(
                    """
                    Rename cascade: source thumbnail already absent (NoSuchKey); \
                    marking new key .pending: \(newThumbKey, privacy: .public)
                    """
                )
            } else {
                logger.error(
                    """
                    Rename cascade copy failed; marking new key .pending for backfill: \
                    \(newThumbKey, privacy: .public): \(DS3S3Client.describeSotoError(error), privacy: .public)
                    """
                )
            }
            try? await metadataStore.setThumbnailStatus(
                s3Key: newKey, driveId: driveId, status: .pending
            )
            return
        }

        // 2. Delete old thumbnail. Failures are swallowed (orphan sweep cleans up).
        do {
            try await s3Client.deleteThumbnail(bucket: bucket, key: oldThumbKey)
        } catch {
            // Phase 13.1 Finding 5 (D-07): NoSuchKey here means the old thumbnail
            // is already gone — concurrent cascade or orphan sweep beat us. That is
            // the success post-condition of this very delete; demote to .info.
            if DS3S3Client.isNotFoundError(error) {
                logger.info(
                    "Rename cascade: old thumbnail already absent (NoSuchKey) for \(oldThumbKey, privacy: .public)"
                )
            } else {
                logger.warning(
                    """
                    Rename cascade delete-old failed (orphan sweep will reclaim): \
                    \(oldThumbKey, privacy: .public): \(DS3S3Client.describeSotoError(error), privacy: .public)
                    """
                )
            }
        }
    }
}
