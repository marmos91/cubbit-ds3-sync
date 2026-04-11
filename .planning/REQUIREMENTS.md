# Requirements: DS3 Drive

**Defined:** 2026-04-11
**Core Value:** Files sync reliably and transparently between the user's Mac, iPhone, iPad and Cubbit DS3, with zero friction

## v3.1 Requirements (Thumbnails)

Closes GitHub issue #109. Image files in Finder (macOS) and the iOS Files app show real thumbnail previews, backed by a `.thumbnails/` S3 prefix that is transparent to the user. Both macOS and iOS can independently generate thumbnails — no platform is a required peer.

### Foundation & Storage

- [ ] **THUMB-01**: `.thumbnails/` S3 prefix is invisible to users — filtered from every enumeration code path via a centralized `S3KeyFilter.isUserVisible(key:)` in DS3Lib
- [ ] **THUMB-02**: Drive setup refuses to enable thumbnails if the bucket has pre-existing incompatible `.thumbnails/` content (collision protection)
- [ ] **THUMB-03**: Thumbnail S3 key layout mirrors original with `.jpg` appended, not substituted (`photos/a.heic` → `photos/.thumbnails/a.heic.jpg`)
- [ ] **THUMB-04**: `SyncedItem` tracks per-item thumbnail status (`.notApplicable` / `.pending` / `.uploaded` / `.failed`) via Schema V3 migration
- [ ] **THUMB-05**: Single fixed thumbnail size — 512 px long edge, JPEG quality 0.7, stored as constants in `DefaultSettings.S3`

### Generation

- [ ] **THUMB-06**: macOS File Provider extension generates thumbnails inline during upload in `createItem` / `modifyItem` (fire-and-forget, decoupled from upload lifecycle — failures never propagate to user-visible file upload)
- [ ] **THUMB-07**: iOS File Provider extension is strictly consume-only — it never calls ImageIO / CoreImage / UIImage; enforced with `#if os(macOS)` gates on the generator type
- [ ] **THUMB-08**: Generated thumbnails correctly apply EXIF orientation so portrait iPhone photos display right-side up
- [ ] **THUMB-09**: Generator supports raster formats: jpg, jpeg, png, heic, heif, webp, gif, tiff. Unsupported formats are silently skipped (no error, no user-visible spinner)
- [ ] **THUMB-10**: Thumbnail PUT is always single-part (thumbnails always <500 KB — never multipart); thumbnails are written with `x-amz-meta-source-etag` and `x-amz-meta-ds3drive-thumb-version` for staleness detection and format versioning

### Consumption

- [ ] **THUMB-11**: User sees real thumbnails in Finder (macOS) and iOS Files app for image files, including cloud-only files, without triggering a full-file download
- [ ] **THUMB-12**: Thumbnails coexist with existing sync status badges — cloud / synced / syncing / error overlays still render correctly on top of thumbnails
- [ ] **THUMB-13**: Missing or failed thumbnails fall back gracefully to the default UTType icon — errors returned from `fetchThumbnails` are always in `NSFileProviderErrorDomain` or `NSCocoaErrorDomain`, never custom domains
- [ ] **THUMB-14**: Concurrent thumbnail fetches are bounded (macOS 4, iOS 2) via a `ThumbnailFetchLimiter` to prevent S3 `SlowDown` under folder-browse fanout

### Backfill & Lifecycle

- [ ] **THUMB-15**: macOS extension backfills existing and externally-added images opportunistically during BFS enumeration passes (budgeted per pass, thermal-state gated)
- [ ] **THUMB-16**: iOS main app backfills via `BGProcessingTask` (overnight, charging, idle) and via a foreground driver that runs while the app is in `ScenePhase.active`
- [ ] **THUMB-17**: Deleting an image cascades to delete its thumbnail (delete-after-original ordering; orphan sweep backstops failures)
- [ ] **THUMB-18**: Renaming or moving an image cascades to the thumbnail (server-side S3 copy to new key, then delete old)
- [ ] **THUMB-19**: Periodic orphan sweep removes `.thumbnails/` entries whose originals no longer exist
- [ ] **THUMB-20**: Reconciliation loop terminates — items that fail 3 times with permanent errors enter a negative cache and are counted as "done — N skipped" in UI, not "99%"
- [ ] **THUMB-21**: Thumbnail backfill respects the existing per-drive pause/resume state
- [ ] **THUMB-22**: iOS thumbnail backfill is gated off cellular / metered connections by default (opt-in setting required to enable on cellular)
- [ ] **THUMB-23**: No eager full-bucket scan on feature launch — backfill is opportunistic; existing-content processing runs only when users browse folders or trigger the manual action

### UI Feedback & Control

- [ ] **THUMB-24**: macOS menu bar tray shows per-drive "Thumbnails: N/M" progress indicator while backfill is active (hides at 100%)
- [ ] **THUMB-25**: Settings (macOS and iOS) expose a manual "Generate thumbnails now" action for power users, with an explicit bandwidth / cost warning on first use
- [ ] **THUMB-26**: iOS settings UI shows backfill progress and user-facing copy explaining the force-quit caveat for background generation

## Future Requirements (deferred beyond v3.1)

- RAW file thumbnail support (memory-intensive ImageIO path; defer to dedicated milestone)
- PDF thumbnail support (PDFKit path; separate format matrix)
- Video thumbnail support (AVFoundation frame extraction; memory-heavy)
- Multiple thumbnail sizes / size pyramid
- EXIF-embedded thumbnail fast path (range GET first ~64 KB for JPEG/HEIC thumbnail metadata)
- PushKit-triggered thumbnail generation wake-up (depends on PushKit infrastructure not yet built)
- PNG fallback for line-art / screenshot content (JPEG Q0.7 ringing artifacts — known limitation for v3.1)
- Generalizing `BucketListingLimiter` → `S3RequestLimiter` to back `ThumbnailFetchLimiter`

## Out of Scope

- **In-app photo viewer / gallery grid** — Files.app and Finder are already the file browser; PROJECT.md out-of-scopes in-app file browser
- **Server-side thumbnail generation (Lambda, worker, cloud function)** — PROJECT.md hard constraint: no custom backend; contradicts on-device privacy positioning
- **Face detection, auto-tagging, smart albums, search by content** — ML models are jetsam-hostile on iOS extension; not a sync-client feature; PROJECT.md out-of-scopes camera upload / document scanning
- **Camera roll import / auto photo backup** — separate product domain; Share Extension is the correct level of integration
- **Pre-generating thumbnails at drive setup (blocking)** — makes setup feel broken; backfill must always be async
- **User-facing thumbnail quality slider** — trivial choice, zero value; hardcode 80% JPEG
- **Multiple thumbnail sizes** — 5× storage and CPU cost; single 512 px satisfies Finder icon view + Quick Look
- **Sibling-file thumbnail layout** (`photo.jpg.thumb`) — pollutes listings, complicates filter; `.thumbnails/` prefix is the correct pattern
- **Separate thumbnail encryption** — inherits bucket-level encryption; future zero-knowledge drives use same per-drive key
- **Regeneration on metadata-only changes** — EXIF edits don't change pixels; invalidate via ETag only

## Previous Milestones

See `.planning/milestones/v1.0-REQUIREMENTS.md` and `.planning/milestones/v2.0-REQUIREMENTS.md` for previously-validated requirements.

## Traceability

Maps each v3.1 requirement to the phase that will deliver it. 26/26 requirements mapped — no orphans, no duplicates.

| Requirement | Phase | Category | Status |
|-------------|-------|----------|--------|
| THUMB-01 | Phase 11: Foundation & Filtering | Foundation & Storage | Pending |
| THUMB-02 | Phase 11: Foundation & Filtering | Foundation & Storage | Pending |
| THUMB-03 | Phase 11: Foundation & Filtering | Foundation & Storage | Pending |
| THUMB-05 | Phase 11: Foundation & Filtering | Foundation & Storage | Pending |
| THUMB-04 | Phase 12: Renderer, Storage & Schema | Foundation & Storage | Pending |
| THUMB-07 | Phase 12: Renderer, Storage & Schema | Generation | Pending |
| THUMB-08 | Phase 12: Renderer, Storage & Schema | Generation | Pending |
| THUMB-09 | Phase 12: Renderer, Storage & Schema | Generation | Pending |
| THUMB-10 | Phase 12: Renderer, Storage & Schema | Generation | Pending |
| THUMB-06 | Phase 13: macOS Generation, Consumption & Lifecycle | Generation | Pending |
| THUMB-11 | Phase 13: macOS Generation, Consumption & Lifecycle | Consumption | Pending |
| THUMB-12 | Phase 13: macOS Generation, Consumption & Lifecycle | Consumption | Pending |
| THUMB-13 | Phase 13: macOS Generation, Consumption & Lifecycle | Consumption | Pending |
| THUMB-14 | Phase 13: macOS Generation, Consumption & Lifecycle | Consumption | Pending |
| THUMB-15 | Phase 13: macOS Generation, Consumption & Lifecycle | Backfill & Lifecycle | Pending |
| THUMB-17 | Phase 13: macOS Generation, Consumption & Lifecycle | Backfill & Lifecycle | Pending |
| THUMB-18 | Phase 13: macOS Generation, Consumption & Lifecycle | Backfill & Lifecycle | Pending |
| THUMB-19 | Phase 13: macOS Generation, Consumption & Lifecycle | Backfill & Lifecycle | Pending |
| THUMB-20 | Phase 13: macOS Generation, Consumption & Lifecycle | Backfill & Lifecycle | Pending |
| THUMB-21 | Phase 13: macOS Generation, Consumption & Lifecycle | Backfill & Lifecycle | Pending |
| THUMB-23 | Phase 13: macOS Generation, Consumption & Lifecycle | Backfill & Lifecycle | Pending |
| THUMB-24 | Phase 13: macOS Generation, Consumption & Lifecycle | UI Feedback & Control | Pending |
| THUMB-16 | Phase 14: iOS Generation & Polish | Backfill & Lifecycle | Pending |
| THUMB-22 | Phase 14: iOS Generation & Polish | Backfill & Lifecycle | Pending |
| THUMB-25 | Phase 14: iOS Generation & Polish | UI Feedback & Control | Pending |
| THUMB-26 | Phase 14: iOS Generation & Polish | UI Feedback & Control | Pending |

**Coverage summary:**
- Phase 11: 4 requirements (THUMB-01, 02, 03, 05)
- Phase 12: 5 requirements (THUMB-04, 07, 08, 09, 10)
- Phase 13: 13 requirements (THUMB-06, 11, 12, 13, 14, 15, 17, 18, 19, 20, 21, 23, 24)
- Phase 14: 4 requirements (THUMB-16, 22, 25, 26)
- **Total: 26/26 ✓**
