import DS3Lib
@preconcurrency import FileProvider
import Foundation
import os.log

// MARK: - Upload-time thumbnail hook (Phase 13 D-06, D-08, D-09, D-10; THUMB-06)

/// Free-function entry point that `createItem` (post-PUT) and `modifyItem` (content-change branch)
/// call to enqueue a fire-and-forget thumbnail render+PUT for the just-uploaded original.
///
/// Plan 13-07 design notes:
/// - Free function (NOT a method on `FileProviderExtension`) so the call site captures only
///   sendable values — the FP extension subclass inherits from `NSObject` and is NOT `Sendable`
///   under Swift 6 strict concurrency (Pitfall 1 in 13-RESEARCH.md).
/// - `Task.detached(priority: .background)` opens a fresh isolation domain decoupled from the
///   user-visible upload completion handler (D-06). The handler returns success BEFORE this
///   detached Task runs any work.
/// - Pre-filter via `S3PathUtils.isRasterExtension`: non-raster originals silently mark
///   `thumbnailStatus = .notApplicable` and return without scheduling render work (D-08).
/// - Errors inside the detached Task are logged and SWALLOWED (`try?`) — they never propagate
///   to the user-visible upload contract. THUMB-06 mandates this lifecycle decoupling.
///
/// **NEVER capture `self` inside the detached Task** — pass sendable locals only:
/// `s3Client` (Sendable), `metadataStore` (`@ModelActor`), `drive` (Sendable struct), strings,
/// and the logger.
///
/// Sendable parameter bundle for `enqueueThumbnailUpload`. Bundling keeps the function
/// signature under SwiftLint's `function_parameter_count` limit AND ensures every captured
/// value is checked Sendable-clean at construction time.
struct ThumbnailUploadHookContext {
    let originalKey: String
    let localURL: URL
    let sourceETag: String?
    let drive: DS3Drive
    let s3Client: any DS3S3ClientProtocol
    let metadataStore: MetadataStore?
    let logger: os.Logger
}

/// Per-platform upload hook. macOS spawns a detached Task that runs `ThumbnailUploader.generateAndUpload`;
/// iOS marks the row `.pending` for Phase 14's foreground driver to pick up. Errors are SWALLOWED
/// inside the detached Task per D-06 — they NEVER propagate to the user-visible upload contract.
@Sendable
func enqueueThumbnailUpload(_ context: ThumbnailUploadHookContext) {
    // (a) Pre-filter at the call boundary: non-raster originals never schedule render work.
    //     We mark `.notApplicable` from a separate detached Task so even the metadata write is
    //     off the user-visible path. Per D-08.
    let pathExtension = (context.originalKey as NSString).pathExtension
    guard S3PathUtils.isRasterExtension(pathExtension) else {
        if let metadataStore = context.metadataStore {
            let driveId = context.drive.id
            let key = context.originalKey
            Task.detached(priority: .background) {
                try? await metadataStore.setThumbnailStatus(
                    s3Key: key, driveId: driveId, status: .notApplicable
                )
            }
        }
        return
    }

    // (b) Raster path. We require BOTH a normalized sourceETag AND a metadata store — without
    //     the store we have no way to record .uploaded / .failed transitions, so skip silently.
    guard let metadataStore = context.metadataStore,
          let sourceETag = context.sourceETag,
          !sourceETag.isEmpty
    else {
        context.logger.debug(
            "Upload-hook: skipping \(context.originalKey, privacy: .public) — missing metadataStore or empty sourceETag"
        )
        return
    }

    // (c) Capture sendable locals before opening the detached Task. NEVER capture `self`
    //     (this is a free function — the FileProviderExtension subclass is non-Sendable per
    //     Pitfall 1 in 13-RESEARCH.md). All seven values below are Sendable by construction.
    let s3Client = context.s3Client
    let drive = context.drive
    let originalKey = context.originalKey
    let localURL = context.localURL
    let logger = context.logger

    Task.detached(priority: .background) {
        #if os(macOS)
            do {
                let uploader = ThumbnailUploader(
                    s3Client: s3Client, metadataStore: metadataStore
                )
                try await uploader.generateAndUpload(
                    localURL: localURL,
                    drive: drive,
                    sourceETag: sourceETag,
                    originalKey: originalKey
                )
            } catch {
                // D-06: errors NEVER propagate to the user-visible upload contract — log + swallow.
                logger.error(
                    "Upload-hook: thumbnail upload failed for \(originalKey, privacy: .public): \(DS3S3Client.describeSotoError(error), privacy: .public)"
                )
            }
        #else
            // iOS path — Phase 14 will wire the foreground backfill driver. Until then, leave
            // the row `.pending` (it's the schema default) so the future iOS render pass picks
            // it up. We re-mark explicitly to defend against a regression that flipped it earlier.
            try? await metadataStore.setThumbnailStatus(
                s3Key: originalKey, driveId: drive.id, status: .pending
            )
            _ = (s3Client, sourceETag, localURL, logger) // silence unused-variable warnings on iOS
        #endif
    }
}

// swiftlint:disable function_parameter_count
/// Convenience overload mirroring the call-site readability of named parameters.
/// Forwards into the `ThumbnailUploadHookContext` bundle to keep the per-call-site
/// invocation under SwiftLint's `function_parameter_count` limit transparently.
@Sendable
func enqueueThumbnailUpload(
    originalKey: String,
    localURL: URL,
    sourceETag: String?,
    drive: DS3Drive,
    s3Client: any DS3S3ClientProtocol,
    metadataStore: MetadataStore?,
    logger: os.Logger
) {
    enqueueThumbnailUpload(ThumbnailUploadHookContext(
        originalKey: originalKey,
        localURL: localURL,
        sourceETag: sourceETag,
        drive: drive,
        s3Client: s3Client,
        metadataStore: metadataStore,
        logger: logger
    ))
}

// swiftlint:enable function_parameter_count
