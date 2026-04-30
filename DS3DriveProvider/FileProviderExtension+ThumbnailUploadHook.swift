import DS3Lib
@preconcurrency import FileProvider
import Foundation
import os.log

// MARK: - Upload-time thumbnail hook (Phase 13 D-06, D-08, D-09, D-10; THUMB-06; #141)

// swiftformat:disable redundantSendable
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
/// - Pre-filter via `S3PathUtils.isRasterExtension`: non-raster originals are skipped
///   silently — no render work scheduled (D-08). Phase 13.2 Plan 09 / Schema V6 dropped
///   the `thumbnailStatus` field, so the hook no longer marks `.notApplicable`.
/// - Errors inside the detached Task are logged and SWALLOWED (`try?`) — they never propagate
///   to the user-visible upload contract. THUMB-06 mandates this lifecycle decoupling.
///
/// Issue #141 (Task 4): the eager path no longer reads the FileProvider temp URL.
/// FileProvider may invalidate `localURL` the moment the createItem completionHandler
/// returns; the detached Task could race that invalidation under bulk load. The hook
/// now downloads the original from S3 (same bytes-source as the consume-path fallback)
/// after the original PUT completes, gated through `ThumbnailUploadLimiter` for
/// admission control.
///
/// **NEVER capture `self` inside the detached Task** — pass sendable locals only:
/// `s3Client` (Sendable), `metadataStore` (`@ModelActor`), `drive` (Sendable struct), strings,
/// and the logger.
///
/// Sendable parameter bundle for `enqueueThumbnailUpload`. Bundling keeps the function
/// signature under SwiftLint's `function_parameter_count` limit AND ensures every captured
/// value is checked Sendable-clean at construction time.
///
/// Phase 13.2 (D-12): added `domain: NSFileProviderDomain` so the detached Task can
/// construct an `NSFileProviderManager` and call `signalEnumerator(for: parentContainer)`
/// after a successful generateAndUpload PUT — symmetric with the fallback path's
/// post-PUT signal in `consumeThumbnailFallback`.
///
/// Code review Fix 6 (Phase 13.2): explicit `Sendable` conformance. Auto-synthesis
/// is fragile under strict concurrency for structs containing protocol existentials
/// like `any DS3S3ClientProtocol`; declaring the conformance explicitly makes the
/// contract a hard compile-time constraint (CI Xcode 16.2 is stricter than local).
/// The `swiftformat:disable redundantSendable` directive (block-scoped at file level
/// for this declaration) prevents SwiftFormat from stripping the conformance.
struct ThumbnailUploadHookContext: Sendable {
    let originalKey: String
    /// MUST be non-empty. The enqueue path rejects empty/nil eagerly
    /// (the original PUT response always provides one). The Optional
    /// type is retained on the context struct for call-site stability;
    /// the precondition is enforced inside `enqueueThumbnailUpload`.
    let sourceETag: String?
    let drive: DS3Drive
    let s3Client: any DS3S3ClientProtocol
    let metadataStore: MetadataStore?
    let domain: NSFileProviderDomain
    let logger: os.Logger
}

// swiftformat:enable redundantSendable

/// Builds a `@Sendable` closure that calls `NSFileProviderManager(for: domain).signalEnumerator(for:)`
/// for a given parent container, logging non-fatal errors with `label` for context.
///
/// Phase 13.2 D-12: shared between the upload-hook (post-PUT after fresh upload) and the
/// consume-path fallback (post-PUT after cache-miss render) — both need to nudge Apple to
/// re-enumerate the parent folder so the just-uploaded thumbnail is fetched without a refresh.
///
/// The closure captures only Sendable locals (NSFileProviderDomain is Sendable). NEVER
/// captures `self` — preserves the free-function contract for both call sites.
///
/// `signalEnumerator` returns a vanilla NSError (not a Soto error), so
/// `error.localizedDescription` is acceptable here — the codebase-wide `describeSotoError`
/// rule applies only to Soto-originated errors.
@Sendable
func makeSignalParentContainer(
    domain: NSFileProviderDomain,
    logger: os.Logger,
    label: String
) -> @Sendable (NSFileProviderItemIdentifier) -> Void {
    { parentId in
        guard let manager = NSFileProviderManager(for: domain) else { return }
        manager.signalEnumerator(for: parentId) { error in
            if let error {
                logger.error(
                    "\(label, privacy: .public) signal failed for \(parentId.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }
}

// swiftlint:disable function_parameter_count
/// Performs the actual upload-hook work inside a detached Task. Extracted from
/// `enqueueThumbnailUpload` to keep the Task body type-checkable under Swift 6's
/// stricter overload resolution (the inline form ran into ambiguity between
/// `Task.detached` overloads when capturing a `@Sendable` callback alongside the
/// other Sendable locals). SwiftLint's count check is disabled here as a
/// deliberate trade-off — the alternative is yet another Sendable struct just
/// for this internal helper.
///
/// Issue #141 (Task 4): pivots the upload path off the FileProvider temp URL.
/// Sequence: acquire limiter slot → GET original from S3 → render → PUT thumb
/// → signal parent. Same bytes-source as `consumeThumbnailFallback` so the eager
/// and lazy paths are byte-identical.
@Sendable
private func runUploadHook(
    s3Client: any DS3S3ClientProtocol,
    drive: DS3Drive,
    originalKey: String,
    sourceETag: String,
    limiter: ThumbnailUploadLimiter,
    download: ThumbnailOriginalDownloader,
    signalCallback: @Sendable (NSFileProviderItemIdentifier) -> Void,
    logger: os.Logger
) async {
    #if os(macOS)
        // (a) Acquire the slot. Cancellation = exit cleanly without doing work.
        do {
            try await limiter.acquire()
        } catch {
            return
        }

        // Code review Fix 2 (Phase 13.2): release explicitly on every exit path
        // rather than via `defer { Task { await release } }`. Spawning an
        // unstructured Task to return the slot delays the hand-off by an extra
        // task hop. Explicit `await limiter.release()` before each return
        // guarantees the slot is returned synchronously within this Task —
        // mirrors the consume-path fallback pattern in
        // `consumeThumbnailFallback` (+ThumbnailConsume.swift).

        // (b) Download the original from S3. We just uploaded it; S3 is
        //     read-after-write consistent for new objects. Errors logged + swallowed (D-06).
        let identifier = NSFileProviderItemIdentifier(originalKey)
        let downloadedURL: URL
        do {
            (downloadedURL, _) = try await download(identifier, drive)
        } catch {
            logger.error(
                "Upload-hook: GET original failed for \(originalKey, privacy: .public): \(DS3S3Client.describeSotoError(error), privacy: .public)"
            )
            await limiter.release()
            return
        }
        defer { try? FileManager.default.removeItem(at: downloadedURL) }

        // (c) Render. Sub-reason logged via the RenderFailure enum.
        let renderResult = ThumbnailRenderer().renderJPEG(from: downloadedURL)
        let jpegBytes: Data
        switch renderResult {
        case let .success(bytes):
            jpegBytes = bytes
        case let .failure(reason):
            logger.info(
                "Upload-hook: render failed for \(originalKey, privacy: .public) — reason=\(reason.rawValue, privacy: .public)"
            )
            await limiter.release()
            return
        }

        // (d) PUT. `sourceETag` is guaranteed non-empty by enqueueThumbnailUpload's
        //     precondition (line ~225); no fallback needed.
        let bucket = drive.syncAnchor.bucket.name
        let drivePrefix = drive.syncAnchor.prefix
        let thumbKey = S3PathUtils.thumbnailKey(
            forOriginalKey: originalKey, drivePrefix: drivePrefix
        )
        let etagForPut = sourceETag
        do {
            _ = try await s3Client.putThumbnail(
                bucket: bucket, key: thumbKey, data: jpegBytes, sourceETag: etagForPut
            )
        } catch {
            logger.error(
                "Upload-hook: PUT failed for \(thumbKey, privacy: .public): \(DS3S3Client.describeSotoError(error), privacy: .public)"
            )
            await limiter.release()
            return
        }
        logger.info(
            "Upload-hook: PUT succeeded for \(thumbKey, privacy: .public)"
        )

        // (e) Signal the parent so Apple re-enumerates and the next visit hits
        //     the warm cache.
        let parentKeyOpt = S3PathUtils.parentKey(
            forKey: originalKey, drivePrefix: drivePrefix
        )
        let parentId: NSFileProviderItemIdentifier =
            parentKeyOpt.map { NSFileProviderItemIdentifier($0) } ?? .rootContainer
        signalCallback(parentId)
        await limiter.release()
    #else
        _ = (s3Client, drive, originalKey, sourceETag, limiter, download, signalCallback, logger)
    #endif
}

// swiftlint:enable function_parameter_count

/// Per-platform upload hook. macOS spawns a detached Task that runs the limiter-gated
/// GET → render → PUT → signal sequence; iOS is a no-op (Phase 14 owns the foreground
/// backfill driver). Errors are SWALLOWED inside the detached Task per D-06 — they
/// NEVER propagate to the user-visible upload contract.
///
/// Phase 13.2 D-12: after a successful PUT, invokes `signalParentContainer` (defaulting to the
/// NSFileProviderManager-backed implementation) so Apple re-enumerates the parent folder.
/// Tests inject a recorder closure to observe the callback without standing up a real domain.
///
/// Issue #141 (Task 4): admission control via `ThumbnailUploadLimiter`. Soft-cap check
/// at enqueue time drops new work past 64 pending waiters; the consume-path fallback
/// generates missing thumbnails on first view.
///
/// Implementation note: the soft-cap read crosses an actor boundary
/// (`isAtSoftCap`), so we wrap it in an outer `Task(priority: .utility)`
/// before spawning the inner `Task.detached(priority: .background)` that
/// runs the render+PUT. The outer Task only does the cap check; never
/// captures `self`.
@Sendable
func enqueueThumbnailUpload(
    _ context: ThumbnailUploadHookContext,
    limiter: ThumbnailUploadLimiter,
    download: @escaping ThumbnailOriginalDownloader,
    signalParentContainer: (@Sendable (NSFileProviderItemIdentifier) -> Void)? = nil
) {
    // (a) Pre-filter at the call boundary: non-raster originals never schedule render work.
    //     Phase 13.2 Plan 09 / Schema V6 dropped `thumbnailStatus`, so there is no
    //     longer a `.notApplicable` write on the non-raster branch — the hook simply
    //     returns. Per D-08.
    let pathExtension = (context.originalKey as NSString).pathExtension
    guard S3PathUtils.isRasterExtension(pathExtension) else {
        return
    }

    // (b) Require a non-empty sourceETag. The eager path's caller already has
    //     a fresh ETag from the original PUT response — empty here is an
    //     upstream bug.
    guard let sourceETag = context.sourceETag, !sourceETag.isEmpty else {
        context.logger.debug(
            "Upload-hook: skipping \(context.originalKey, privacy: .public) — empty sourceETag"
        )
        return
    }

    // (c) Capture sendable locals before opening the detached Task. NEVER capture `self`
    //     (this is a free function — the FileProviderExtension subclass is non-Sendable per
    //     Pitfall 1 in 13-RESEARCH.md). All values below are Sendable by construction —
    //     including `downloadFn`, which binds the @escaping `ThumbnailOriginalDownloader`
    //     closure into a named local so the invariant is explicit at the capture site.
    let limiterRef = limiter
    let originalKey = context.originalKey
    let logger = context.logger
    let s3Client = context.s3Client
    let drive = context.drive
    let domain = context.domain
    let downloadFn = download
    // Phase 13.2 D-12: bind the signal callback up-front. Production gets the NSFileProviderManager-backed
    // closure; tests inject a recorder. Either way, the closure is @Sendable and never captures self.
    let signalCallback = signalParentContainer ?? makeSignalParentContainer(
        domain: domain, logger: logger, label: "Upload-hook"
    )

    // (d) Soft-cap check. The check is a one-shot read against the actor; it CAN
    //     race (another job releases between the check and the spawn) but the
    //     cost is at most one extra waiter past the cap, which is fine.
    //     Issue #141: bulk imports past 64+2 in-flight jobs fall through to the
    //     consume-path fallback on first view.
    Task(priority: .utility) {
        if await limiterRef.isAtSoftCap {
            logger.info(
                "Upload-hook: soft cap reached, deferring \(originalKey, privacy: .public) to consume-path fallback"
            )
            return
        }
        Task.detached(priority: .background) {
            await runUploadHook(
                s3Client: s3Client,
                drive: drive,
                originalKey: originalKey,
                sourceETag: sourceETag,
                limiter: limiterRef,
                download: downloadFn,
                signalCallback: signalCallback,
                logger: logger
            )
        }
    }
}

// swiftlint:disable function_parameter_count
/// Convenience overload mirroring the call-site readability of named parameters.
/// Forwards into the `ThumbnailUploadHookContext` bundle to keep the per-call-site
/// invocation under SwiftLint's `function_parameter_count` limit transparently.
///
/// Phase 13.2 D-12: `signalParentContainer` is an optional test-injection seam.
/// Production passes nil (and the default NSFileProviderManager-backed closure runs);
/// tests pass a recorder closure to assert the post-PUT signal fires correctly.
///
/// Issue #141 (Task 4): `limiter` and `download` are required injection seams.
/// Production wires `download` to a closure around `S3Lib.downloadS3Item`; tests
/// inject a stub returning a known fixture URL + etag.
@Sendable
func enqueueThumbnailUpload(
    originalKey: String,
    sourceETag: String?,
    drive: DS3Drive,
    s3Client: any DS3S3ClientProtocol,
    metadataStore: MetadataStore?,
    domain: NSFileProviderDomain,
    logger: os.Logger,
    limiter: ThumbnailUploadLimiter,
    download: @escaping ThumbnailOriginalDownloader,
    signalParentContainer: (@Sendable (NSFileProviderItemIdentifier) -> Void)? = nil
) {
    enqueueThumbnailUpload(
        ThumbnailUploadHookContext(
            originalKey: originalKey,
            sourceETag: sourceETag,
            drive: drive,
            s3Client: s3Client,
            metadataStore: metadataStore,
            domain: domain,
            logger: logger
        ),
        limiter: limiter,
        download: download,
        signalParentContainer: signalParentContainer
    )
}

// swiftlint:enable function_parameter_count
