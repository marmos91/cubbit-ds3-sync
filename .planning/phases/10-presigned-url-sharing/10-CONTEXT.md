# Phase 10: Presigned URL sharing (issue #104) - Context

**Gathered:** 2026-04-09
**Status:** Ready for planning
**Source:** Approved implementation plan (plan-mode session)

<domain>
## Phase Boundary

Add a right-click "share as presigned URL" action on files stored in a DS3 drive. Users right-click a file in Finder (macOS) or long-press in Files.app (iOS), pick a duration, and get a time-limited HTTPS download link on their clipboard. No web console, no extra auth.

The File Provider extension already registers custom actions (`NSExtensionFileProviderActions`) and holds a fully-configured Soto `S3` client with credentials — presigning runs entirely in-process.

</domain>

<decisions>
## Implementation Decisions

### D-01: Duration Presets
- Three top-level right-click actions: `Copy presigned URL (1 hour)` / `(1 day)` / `(7 days)`
- Custom File Provider actions cannot nest into submenus — flat list in Info.plist
- Max expiry is 7 days (SigV4 limit), hard-coded, not configurable

### D-02: Platform Scope
- Ship on both macOS and iOS in the same PR
- Soto's `signURL` is async but finishes well under a second (pure CPU, no network)
- Files.app custom-action timeouts are not a realistic concern
- Both platforms share `FileProviderExtension+CustomActions.swift`

### D-03: User Feedback
- Post a `UNUserNotification` on success with the expiry in the body (e.g. "Link copied — expires in 1 hour")
- Post an error notification on failure
- On denied notification authorization: silently no-op (clipboard is the primary feedback)
- iOS: system clipboard banner provides additional feedback automatically

### D-04: Architecture
- All generation logic in the extension process — no new IPC, no main-app changes
- Mirrors existing `copyS3URL` action pattern (item-iteration, clipboard write, completionHandler)
- Single item: one URL. Multiple items: one URL per item, joined with `\n`
- Errors must be `NSFileProviderError` or `NSCocoaError` (no custom error domains)

### D-05: Activation Rule
- Presigned URL actions restricted to non-folder items (`kMDItemContentTypeTree != 'public.folder'`)
- Folders excluded because presigning a folder GET doesn't make sense

### D-06: S3 Client Extension
- New `DS3S3Client+Presign.swift` with `presignedGetURL(bucket:key:expiresIn:)` method
- Calls Soto's `s3.signURL(url:httpMethod:.GET, expires:)`
- Validates `expiresIn` in `(0, 604800]`, throws `.invalidPresignExpiry` otherwise
- Builds object URL from `endpoint + bucket + key`

### Claude's Discretion
- Notification helper implementation details (DateComponentsFormatter vs hardcoded strings)
- Task group concurrency pattern for multi-select (can mirror existing patterns)
- Test structure and naming conventions

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### File Provider Custom Actions
- `DS3DriveProvider/FileProviderExtension+CustomActions.swift` — Existing custom action implementation (copyS3URL, evictItem, restoreFromTrash). Template for new presigned URL actions.
- `DS3DriveProvider/Info.plist` — NSExtensionFileProviderActions array. Add new entries here.
- `DS3DriveProvider/FileProviderExtension.swift:52,74-103` — S3 client initialization with credentials/endpoint.

### S3 Client Layer
- `DS3Lib/Sources/DS3Lib/DS3S3Client.swift` — S3 client class. The `s3: S3` property at line 176 exposes Soto's signURL.
- `DS3Lib/Sources/DS3Lib/DS3S3Client+Protocol.swift` — Protocol definition for mockable testing.
- `DS3Lib/Sources/DS3Lib/DS3S3Client+Transfers.swift` — Existing extension pattern to follow.

### Soto signURL API
- `DS3Lib/.build/checkouts/soto-core/Sources/SotoCore/AWSService+async.swift:30-38` — `signURL(url:httpMethod:headers:expires:logger:)` signature.

### Existing Integration Tests
- `DS3Lib/Tests/DS3LibTests/Integration/DS3S3ClientIntegrationTests.swift` — Pattern for new presign integration test.

### S3 Item Resolution
- `DS3DriveProvider/S3Item.swift` — `itemIdentifier.rawValue` = S3 key
- `DS3Lib/Sources/DS3Lib/Models/SyncAnchor.swift` — `drive.syncAnchor.bucket.name` for bucket name

</canonical_refs>

<specifics>
## Specific Ideas

- GitHub issue #104 by @esignoretti: https://github.com/marmos91/cubbit-ds3-drive/issues/104
- The existing `copyS3URL` action at CustomActions.swift:31-46 is the exact template to mirror
- `FileProviderExtension.s3Client` is already initialized with correct credentials — no new auth plumbing
- `BlockMenuItem` / `GearMenuButton` in tray are NOT touched — presigning is per-file (right-click), not per-drive (tray)
- Notification helper should use `UNUserNotificationCenter.current().add(...)` with `DateComponentsFormatter` for expiry display

</specifics>

<deferred>
## Deferred Ideas

- Configurable expiry beyond the 3 presets
- Web console-style "copy link" dialog with QR / shortened URL / embedded expiry view
- Read-write presigned URLs (only GET is generated)
- Tray-menu version of the action (requires file selection UX)
- Anonymous listing presigned URLs for folders

</deferred>

---

*Phase: 10-presigned-url-sharing*
*Context gathered: 2026-04-09 via approved plan*
