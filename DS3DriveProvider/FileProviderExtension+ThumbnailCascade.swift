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
/// Other failures are logged + swallowed; the cascade is the sole orphan-prevention
/// mechanism (Phase 13.2 D-25 deleted the orphan sweeper). A failed delete leaves
/// an orphan thumb on S3; recovery is the next user-initiated original-key delete.
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
            // Phase 13.2 D-25: orphan sweeper deleted; a failed delete leaks the thumb
            // on S3 until the next user-initiated original-key delete reclaims it.
            //
            // Phase 13.1 Finding 5 (D-07): demote NoSuchKey to .info — the thumbnail
            // is already gone (prior cascade beat us), which is the success
            // post-condition of this very call. Logging at .error creates noise.
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
/// - Copy failure → leave the new key without a thumbnail; the next user open of
///   the new key triggers the reactive fallback render path (Phase 13.2 Plan 02)
///   which renders + PUTs from the new original. We do NOT call deleteThumbnail
///   on the old key in this path: the old thumbnail is the only surviving fresh
///   copy until the new key has its own thumb. The leaked old thumb is permanent
///   (Phase 13.2 D-25 deleted the orphan sweeper).
///   Phase 13.2 Plan 09 / Schema V6 dropped `thumbnailStatus`, so there is no
///   longer a `.pending` write to perform — the absence of `.thumbnails/<newKey>.jpg`
///   in S3 is now the sole signal that triggers the consume-path fallback.
/// - Delete-old failure → swallowed; orphan thumb accumulates on S3 (no sweeper).
///
/// Per Phase 13 D-22, D-24.
///
/// **Call-site contract (enforced in `+Modify.swift`):** when `modifyItem` receives
/// both `.contents` AND a rename/move, the rename cascade is SUPPRESSED — Plan 13-07's
/// content-change hook already wrote a fresh thumb at the new key; copying the old over
/// it would overwrite the fresh render with a stale one. See Test 11 in CascadeRenameTests.
extension FileProviderExtension {
    /// Dispatches the post-rename/move thumbnail cascade if all preconditions hold.
    /// Centralizes the gate logic shared by `modifyItem`'s rename, rename+move, and
    /// move-only branches: skip when content was also changed (Plan 13-07's hook
    /// already wrote a fresh thumb at the new key), when the item is a folder, or
    /// when `s3Client` / `metadataStore` are unavailable. macOS only — iOS lacks
    /// the upload-side renderer wired in Phase 13.2.
    func dispatchRenameCascade(
        oldKey: String,
        newKey: String,
        drive: DS3Drive,
        s3Item: S3Item,
        changedFields: NSFileProviderItemFields,
        contextLabel: String
    ) {
        #if os(macOS)
            guard !changedFields.contains(.contents), !s3Item.isFolder, self.s3Client != nil else {
                return
            }
            guard let s3Client = self.s3Client, let metadataStore = self.metadataStore else {
                self.logger.debug(
                    "\(contextLabel, privacy: .public) thumbnail cascade skipped — metadataStore unavailable for \(oldKey, privacy: .public)"
                )
                return
            }
            enqueueThumbnailRenameCascade(
                oldOriginalKey: oldKey,
                newOriginalKey: newKey,
                drive: drive,
                s3Client: s3Client,
                metadataStore: metadataStore,
                logger: self.logger
            )
        #endif
    }
}

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

    // metadataStore is retained on the public signature for API stability and
    // future use; Phase 13.2 Plan 09 dropped the `thumbnailStatus` writes that
    // previously consumed it. Silence the unused-variable warning on iOS-style
    // strict builds.
    _ = (metadataStore, driveId)

    Task.detached(priority: .background) {
        let oldThumbKey = S3PathUtils.thumbnailKey(forOriginalKey: oldKey, drivePrefix: drivePrefix)
        let newThumbKey = S3PathUtils.thumbnailKey(forOriginalKey: newKey, drivePrefix: drivePrefix)

        // 1. Server-side copy old → new (preserves x-amz-meta-source-etag per D-23).
        do {
            try await s3Client.copyThumbnail(
                bucket: bucket, fromKey: oldThumbKey, toKey: newThumbKey
            )
        } catch {
            // D-22 fallback: leave the new key without a thumbnail. The next
            // user-visible open of the new key triggers the reactive fallback
            // render path (Phase 13.2 Plan 02), which renders + PUTs from the
            // new original. We do NOT call deleteThumbnail(old) here — the old
            // thumb is the only surviving fresh copy and the orphan sweeper is
            // gone (Phase 13.2 D-25); the leaked old thumb stays on S3
            // permanently unless a future cascade overwrites/deletes it.
            //
            // Phase 13.2 Plan 09 / Schema V6: no `.pending` write — the field
            // is gone. The absence of `.thumbnails/<newKey>.jpg` in S3 is now
            // the sole signal that triggers the consume-path fallback.
            //
            // Phase 13.1 Finding 5 (D-07): NoSuchKey here means the source
            // thumbnail was missing at copy time (concurrent cascade or never
            // existed). Log at .info — this is an expected race, not an error
            // worth alerting on.
            if DS3S3Client.isNotFoundError(error) {
                logger.info(
                    """
                    Rename cascade: source thumbnail already absent (NoSuchKey); \
                    new key will be re-rendered on next visit: \(newThumbKey, privacy: .public)
                    """
                )
            } else {
                logger.error(
                    """
                    Rename cascade copy failed; new key will be re-rendered on next visit: \
                    \(newThumbKey, privacy: .public): \(DS3S3Client.describeSotoError(error), privacy: .public)
                    """
                )
            }
            return
        }

        // 2. Delete old thumbnail. Failures are swallowed; the cascade is the
        // sole orphan-prevention mechanism (Phase 13.2 D-25). A failed delete
        // leaks the old thumb on S3 permanently.
        do {
            try await s3Client.deleteThumbnail(bucket: bucket, key: oldThumbKey)
        } catch {
            // Phase 13.1 Finding 5 (D-07): NoSuchKey here means the old thumbnail
            // is already gone — concurrent cascade beat us. That is the success
            // post-condition of this very delete; demote to .info.
            if DS3S3Client.isNotFoundError(error) {
                logger.info(
                    "Rename cascade: old thumbnail already absent (NoSuchKey) for \(oldThumbKey, privacy: .public)"
                )
            } else {
                logger.warning(
                    """
                    Rename cascade delete-old failed (orphan thumb leaked, no sweeper): \
                    \(oldThumbKey, privacy: .public): \(DS3S3Client.describeSotoError(error), privacy: .public)
                    """
                )
            }
        }
    }
}
