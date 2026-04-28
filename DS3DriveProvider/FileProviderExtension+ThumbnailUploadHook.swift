import DS3Lib
@preconcurrency import FileProvider
import Foundation
import os.log

// MARK: - Upload-time thumbnail hook (Phase 13 D-06, D-08, D-09, D-10; THUMB-06)

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
    let localURL: URL
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
/// other Sendable locals). Parameters bundled at the call site via
/// `ThumbnailUploadHookContext`; SwiftLint's count check is disabled here as a
/// deliberate trade-off — the alternative is yet another Sendable struct just
/// for this internal helper.
@Sendable
private func runUploadHook(
    s3Client: any DS3S3ClientProtocol,
    metadataStore: MetadataStore,
    drive: DS3Drive,
    originalKey: String,
    localURL: URL,
    sourceETag: String,
    signalCallback: @Sendable (NSFileProviderItemIdentifier) -> Void,
    logger: os.Logger
) async {
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
            // Phase 13.2 D-12: PUT succeeded — signal the parent container so Apple
            // re-enumerates and the just-uploaded thumbnail is fetched on the next visit.
            // Symmetric with the fallback path's post-PUT signal in consumeThumbnailFallback.
            let parentKey = S3PathUtils.parentKey(
                forKey: originalKey, drivePrefix: drive.syncAnchor.prefix
            )
            let parentId: NSFileProviderItemIdentifier =
                parentKey.map { NSFileProviderItemIdentifier($0) } ?? .rootContainer
            signalCallback(parentId)
        } catch {
            // D-06: errors NEVER propagate to the user-visible upload contract — log + swallow.
            // No signalCallback on the failure path: nothing to re-enumerate (D-12 negative path).
            logger.error(
                "Upload-hook: thumbnail upload failed for \(originalKey, privacy: .public): \(DS3S3Client.describeSotoError(error), privacy: .public)"
            )
        }
    #else
        // iOS path — Phase 14 will wire the foreground backfill driver. Phase 13.2
        // Plan 09 / Schema V6 dropped `thumbnailStatus`, so there is no longer a
        // metadata write to perform here. The consume-path fallback (Plan 02) will
        // attempt a render against S3 on the next visit anyway.
        _ = (metadataStore, s3Client, drive, originalKey, sourceETag, localURL, logger, signalCallback)
    #endif
}

// swiftlint:enable function_parameter_count

/// Per-platform upload hook. macOS spawns a detached Task that runs `ThumbnailUploader.generateAndUpload`;
/// iOS marks the row `.pending` for Phase 14's foreground driver to pick up. Errors are SWALLOWED
/// inside the detached Task per D-06 — they NEVER propagate to the user-visible upload contract.
///
/// Phase 13.2 D-12: after a successful PUT, invokes `signalParentContainer` (defaulting to the
/// NSFileProviderManager-backed implementation) so Apple re-enumerates the parent folder.
/// Tests inject a recorder closure to observe the callback without standing up a real domain.
@Sendable
func enqueueThumbnailUpload(
    _ context: ThumbnailUploadHookContext,
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

    // (b) Raster path. We require BOTH a normalized sourceETag AND a metadata store.
    //     Phase 13.2 Plan 09: the uploader no longer writes thumbnail-specific fields
    //     against the store, but we still gate on its presence to mirror the prior
    //     contract — call sites without a store are upstream regressions, not normal flow.
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
    //     Pitfall 1 in 13-RESEARCH.md). All values below are Sendable by construction.
    let s3Client = context.s3Client
    let drive = context.drive
    let originalKey = context.originalKey
    let localURL = context.localURL
    let logger = context.logger
    let domain = context.domain
    // Phase 13.2 D-12: bind the signal callback up-front. Production gets the NSFileProviderManager-backed
    // closure; tests inject a recorder. Either way, the closure is @Sendable and never captures self.
    let signalCallback = signalParentContainer ?? makeSignalParentContainer(
        domain: domain, logger: logger, label: "Upload-hook"
    )

    Task.detached(priority: .background) {
        await runUploadHook(
            s3Client: s3Client,
            metadataStore: metadataStore,
            drive: drive,
            originalKey: originalKey,
            localURL: localURL,
            sourceETag: sourceETag,
            signalCallback: signalCallback,
            logger: logger
        )
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
@Sendable
func enqueueThumbnailUpload(
    originalKey: String,
    localURL: URL,
    sourceETag: String?,
    drive: DS3Drive,
    s3Client: any DS3S3ClientProtocol,
    metadataStore: MetadataStore?,
    domain: NSFileProviderDomain,
    logger: os.Logger,
    signalParentContainer: (@Sendable (NSFileProviderItemIdentifier) -> Void)? = nil
) {
    enqueueThumbnailUpload(
        ThumbnailUploadHookContext(
            originalKey: originalKey,
            localURL: localURL,
            sourceETag: sourceETag,
            drive: drive,
            s3Client: s3Client,
            metadataStore: metadataStore,
            domain: domain,
            logger: logger
        ),
        signalParentContainer: signalParentContainer
    )
}

// swiftlint:enable function_parameter_count
