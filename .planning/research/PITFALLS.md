# Pitfalls Research: v3.1 Thumbnails

**Domain:** Thumbnails in File Provider + S3 sync app (macOS 14+ / iOS 17+)
**Researched:** 2026-04-11
**Confidence:** HIGH

## Critical Pitfalls

### Pitfall 1: Generating thumbnails inside the iOS File Provider extension (20 MB jetsam kill)

**What goes wrong:** Decoding a 12MP HEIC via UIImage, CIImage, or `CGImageSourceCreateImageAtIndex` allocates 40–150MB transient memory — instantly over the iOS File Provider extension's ~20 MB jetsam budget. Extension killed mid-upload → crash loop → `fileproviderd` disables the extension.

Even `CGImageSourceCreateThumbnailAtIndex` with `kCGImageSourceCreateThumbnailFromImageAlways: true` can exceed the budget when the source is a 4:3 48MP iPhone HEIC — no embedded thumbnail matches the requested size, so ImageIO decodes the full image.

**Why it happens:** Symmetric intuition: "macOS does it at upload, so iOS should too." Teams miss that iOS File Provider extensions get the tightest memory class of any extension type (smaller than Share Extensions' ~120MB).

**Prevention:**
- **Architectural rule: iOS extension = consume-only.** Never call ImageIO/CoreImage/UIImage/CGImageSource in DS3DriveProvider on iOS. Enforce with `#if os(macOS)` gate around the generator type. Import check in the iOS extension target.
- iOS thumbnail generation lives in `DS3DriveApp` (main app, ~unconstrained memory).
- iOS extension only *reads* `.thumbnails/<key>.jpg` from S3 — ~30KB JPEG, memory-safe.
- Memory-budget guard before any ImageIO call: `os_proc_available_memory()` check, bail on low.

**Phase mapping:** Phase A (Foundation) — design-time decision, hard to retrofit.

---

### Pitfall 2: `.thumbnails/` prefix leaks into enumeration → phantom folder in Finder

**What goes wrong:** Filter added to `S3Enumerator.listObjects()` but missed in other paths: `enumerateChanges`, conflict-detection sibling lookup, drive setup wizard "is prefix empty" check, future versioned browsing. User sees `.thumbnails` folder, opens it, either deletes it (catastrophic cascade) or files a bug.

This is the most common "hidden prefix" regression. Dropbox, iCloud, and OneDrive have all shipped this publicly.

**Prevention:**
- Centralize filter in `S3KeyFilter.isUserVisible(key:)` in DS3Lib. Every S3 list consumer MUST go through it — no direct `.objects` iteration.
- Apply at source (the `listObjects` wrapper), not at each call site. Opt-out, not opt-in.
- Mirror every `.trash` filter site — grep the codebase.
- Unit test: list a bucket containing `.thumbnails/`, `.trash/`, and user keys; assert every code path returns only user keys.
- Reject user-created top-level `.thumbnails/` via `NSFileProviderError.filenameCollision`.

**Phase mapping:** Phase A — filter must land **before** first thumbnail write, or prefix appears in dev builds and poisons dogfood.

---

### Pitfall 3: Thumbnail upload blocks / breaks the user-visible file upload

**What goes wrong:** Naive `try await uploadThumbnail(for: item)` in `createItem`/`modifyItem` critical path:
1. Thumbnail generation fails (corrupt EXIF) → upload throws → file marked failed → synced-then-error flicker
2. Thumbnail upload is slow → user's `createItem` appears stalled even though original is on S3
3. Thumbnail PUT returns `SlowDown` → whole upload retried → doubled bandwidth

**User contract:** uploading a file must succeed as soon as the original bytes are durably on S3. Anything else is a regression vs. v2.0.

**Prevention:**
- **Decouple lifecycles.** `createItem`/`modifyItem` returns `.success` the moment the original is confirmed. Thumbnail generation is fire-and-forget on a separate queue with its own retry, NEVER propagates back.
- Wrap in `do { try await ... } catch { logger.error(...) }` — catch-all, log, never rethrow.
- Bounded `OperationQueue` (macOS: `maxConcurrentOperationCount = 2`, iOS: `1`), separate from upload queue.
- On failure, mark in "thumbnail pending" table. Backfill retries later. No loop-retry on upload path.
- Telemetry: track `upload_success` and `thumbnail_success` as independent metrics.

**Phase mapping:** Phase C (Upload integration) — the integration boundary that determines whether thumbnails ship as a delight or regression.

---

### Pitfall 4: Returning custom error domains from `fetchThumbnails`

**What goes wrong:** `NSFileProviderThumbnailing` expects `NSFileProviderErrorDomain` or `NSCocoaErrorDomain`. Returning `ThumbnailError.generationFailed` or a Soto `S3ErrorType` causes `Provider returned error 0 from domain ... unsupported`. Entire thumbnail subsystem wedges, **all thumbnails stop loading**, not just the broken one.

MEMORY.md already documents this footgun: "NEVER return custom error types to the File Provider system."

**Prevention:**
- Dedicated `NSError.fileProviderThumbnailError(from:)` mapper. Funnels every thrown error into `NSFileProviderError.noSuchItem`, `.serverUnreachable`, `.notAuthenticated`, or `NSCocoaErrorDomain/NSFileReadUnknownError`.
- Apply at **outermost** boundary of `fetchThumbnails` — single `do/catch` wraps everything.
- Per-item errors through `perThumbnailCompletionHandler(id, nil, error)` with mapped error only.
- Unit test: every `throws` path has a mapping test verifying `NSError.domain` is one of the two allowed.
- SwiftLint rule / CI grep: `fetchThumbnails.*catch` must be followed by the mapper.

**Phase mapping:** Phase C (File Provider integration) — lands with first `fetchThumbnails` modification.

---

### Pitfall 5: EXIF orientation ignored → rotated / sideways thumbnails

**What goes wrong:** `CGImageSourceCreateThumbnailAtIndex` does NOT apply EXIF orientation by default. Forgetting `kCGImageSourceCreateThumbnailWithTransform: true` ships sideways thumbnails for every portrait iPhone photo. Viewer applies orientation, so desktop-shot QA images never see the bug — only real phone photos.

**Prevention:**
- Thumbnail options MUST include all four keys:
  ```swift
  [
    kCGImageSourceCreateThumbnailFromImageAlways: true,
    kCGImageSourceCreateThumbnailWithTransform: true,   // ← critical
    kCGImageSourceShouldCacheImmediately: true,
    kCGImageSourceThumbnailMaxPixelSize: 512
  ]
  ```
- Test fixture: at least one JPEG + one HEIC with EXIF orientation 6 (rotated 90° CW). Assert generated dimensions match *oriented* aspect ratio.
- Visual diff test against known-good PNG.

**Phase mapping:** Phase A (Generator) — table-stakes correctness, catch in unit tests.

---

### Pitfall 6: HEIC decoding performance cliffs on older hardware

**What goes wrong:**
- Older Intel Macs without HEVC hardware decode: HEIC decode works but is 5–10× slower. Bulk backfill of 10,000 HEICs pins a core for an hour.
- HEIC *output* via `CGImageDestinationCreateWithData` can return `nil` on unusual configs (solution: **always output JPEG** — already the spec).
- iOS 17 on A9/A10: HEIC decode works but full-image path notably slower than JPEG.
- Animated WebP/GIF: first frame only, silently drops animation.

**Prevention:**
- Output format: **JPEG always**, Q0.7, max 512 px. Defend this.
- Input format allow-list: check `CGImageSourceGetType(source)` against `public.jpeg, public.png, public.heic, public.heif, com.google.webp, com.compuserve.gif, public.tiff`. Skip unknown types.
- On iOS, defer heavy formats (HEIC) to `BGProcessingTask` backfill, not foreground.
- Check `ProcessInfo.thermalState` — suspend on `.serious`/`.critical`, yield BG task.
- Animated formats: document as "first frame only," not a bug.

**Phase mapping:** Phase C (macOS Backfill) + Phase D (iOS Backfill).

---

### Pitfall 7: `BGProcessingTask` silently disabled after force-quit

**What goes wrong:** When user force-quits from app switcher, **ALL `BGTaskScheduler` tasks are disabled** until manual re-launch. Apple documented behavior. User opens app, sees empty queue, swipes to close, expects thumbnails overnight — doesn't happen. "Thumbnails are broken."

**Prevention:**
- Treat **foreground generation as primary** iOS path. BG task is opportunistic supplement.
- UX: show "X photos still generating. Keep the app open or plug in overnight to finish." Be explicit.
- After every successful `BGProcessingTask` run, schedule next from within handler. `submit` failure → log `.fault`, surface in settings.
- Do NOT block feature delivery on BG task success. Foreground generation + macOS extension (via shared `.thumbnails/` prefix) is the guaranteed completion path.
- PushKit remote-change detection is a v3.2+ improvement (already on roadmap) — survives force-quit for *sync notifications*, though still not for *generation*.

**Phase mapping:** Phase D (iOS Backfill) — affects UX copy + "is backfill done?" messaging.

---

### Pitfall 8: Rename / delete cascade races → orphaned thumbnails accumulate

**What goes wrong:**
1. Delete original succeeds, delete thumbnail fails (network) → no retry → orphan forever
2. Rename: copy succeeds, delete old thumbnail fails → two thumbnails → stale one attaches to future upload at same key (ghost thumbnail)
3. Cross-prefix move: 1000-image move → 1000 generation jobs → iOS BGProcessingTask explodes
4. Trash cascade decision: does thumbnail also go to trash? Either answer has trade-offs.

Orphans invisible until someone asks "why is the bucket 2× visible content?"

**Prevention:**
- **Always delete thumbnail AFTER original.** Failed original delete → thumbnail stays → next retry both go. Thumbnail without original is benign; original without thumbnail is missing-feature not bug.
- Rename: copy to new key FIRST, rename original, delete old thumb. Overlap window has *two* thumbnails (degrades gracefully).
- Move across prefixes: treat as delete + regenerate from thumbnail perspective. Document trade-off.
- `thumbnail_pending_deletion` table with exponential backoff retry. Never silently drop.
- Periodic orphan reconciler: list `.thumbnails/` batches, HEAD original, delete orphans. **Cap at N per run.**
- Trash: hard-delete thumbnails on trash (not mirror to trash). Restore regenerates on next backfill.

**Phase mapping:** Phase C (Lifecycle cascade) — must land with upload path.

---

### Pitfall 9: `fetchThumbnails` fanout → unbounded S3 GETs → rate limiting

**What goes wrong:** 500-image folder → Finder asks for all 500 thumbnails in one batch → naive impl fires 500 parallel GETs → `SlowDown` 503s → network saturation → timeouts → Finder shows generic icons indefinitely.

**Prevention:**
- Mirror existing `BucketListingLimiter` pattern with `ThumbnailFetchLimiter` — capped concurrency (macOS: 4, iOS: 2), queue the rest.
- Respect `progress.isCancelled` — abort pending fetches if Finder scrolls away.
- **Cache aggressively.** Write generated thumbnails to `NSFileProviderManager.temporaryDirectoryURL` — subsequent calls for same `itemIdentifier` return cached without S3 refetch.
- Return `NSFileProviderError.serverUnreachable` (not `.noSuchItem`) on S3 `SlowDown` so system retries later.

**Phase mapping:** Phase C (File Provider integration) — same pattern as existing `BucketListingLimiter`.

---

### Pitfall 10: Reconciliation loop that never terminates

**What goes wrong:** "Find items missing thumbnail, generate them" loop terminates when nothing missing. But if any item can't be processed (corrupt JPEG, unsupported variant, permission error), every pass rediscovers and re-attempts. Backfill says "99% forever." iOS BGProcessingTask slots burned on unproductive work.

**Prevention:**
- **Negative cache.** `thumbnail_unprocessable` set for items that failed N times with permanent-looking error. Skip future passes. Retry only on manual "rebuild" or app version bump.
- Attempt counter per item; after 3 consecutive failures → mark unprocessable.
- Distinguish permanent (`CGImageSourceStatusInvalidData`) from transient (`NSURLErrorNotConnectedToInternet`). Only permanent → unprocessable.
- Termination: `pending.isEmpty || allPendingAreUnprocessable`.
- **UI counts unprocessable as "done."** Show "100% — 3 unsupported files skipped" not "99%".
- Cap iterations per run (`maxIterationsPerBackgroundRun = 1000`). Yield after cap.
- Telemetry: "made progress" metric per run. Zero new thumbnails + zero new unprocessables → wedged → log `.fault`.

**Phase mapping:** Phase C + D (Backfill) — termination condition is load-bearing for UX.

---

### Pitfall 11: Naive bulk backfill on existing bucket → cost spike + rate limiting

**What goes wrong:** User enables v3.1 on 50,000-image bucket. First reconciler run = 50,000 GET + 50,000 PUT = 100,000 S3 ops. Cubbit bills per-request → bill doubles. `SlowDown` throttles. iOS: ~8 hours of BGProcessingTask slots, realistically never completes. On cellular, downloading originals to generate burns data cap.

**Prevention:**
- **Opportunistic, not eager.** Do NOT full-bucket-scan on feature launch.
  1. Generate for new uploads (proportional to usage)
  2. Generate as items are enumerated by Finder/Files (user already looking)
  3. User-triggered "Generate thumbnails for existing files" in Settings, with bandwidth/cost warning
- Rate-limit reconciler: target <N requests/minute. Config-tunable.
- Respect `NWPathMonitor.currentPath.isExpensive` on iOS — skip on cellular default, opt-in.
- On macOS, gate on `isConstrained` (hotspot/metered Wi-Fi).
- Range-GET first ~256KB of large images if ImageIO can work with truncated source (safe for JPEG, unsafe for progressive PNG — format-gated).
- **Persist progress across app launches.** Don't restart from zero.

**Phase mapping:** Phase C + D (Backfill) — most cost-sensitive decision of the milestone.

---

## Moderate Pitfalls

### Pitfall 12: Stale thumbnail on overwrite at same key
**What:** User uploads `photo.jpg`, thumbnail generated. User overwrites with different content at same name. Reconciler sees "thumbnail exists," skips regen. Old thumbnail forever.
**Prevention:** On `modifyItem`, ALWAYS regenerate. Include source ETag in thumbnail metadata (`x-amz-meta-source-etag`). Reconciler compares, detects stale.
**Phase:** C (Lifecycle)

### Pitfall 13: `autoreleasepool` alone doesn't prevent iOS memory spikes
**What:** Peak allocation during `CGImageSourceCreateImageAtIndex` happens *inside* the call. Pool drains only on return. By then jetsam has fired.
**Prevention:** Belt-and-suspenders — pool + `os_proc_available_memory()` check + format allow-list + thumbnail-only decode path first. On iOS extension: **don't decode at all** (Pitfall 1).
**Phase:** A (Generator)

### Pitfall 14: `fetchThumbnails` called for undownloaded on-demand items
**What:** Item contents not yet local. Impl tries to read local file → fails → returns `.noSuchItem` → Finder thinks item doesn't exist.
**Prevention:** Thumbnail path reads `.thumbnails/<key>.jpg` directly from S3 — **never attempts to download original from within `fetchThumbnails`**. Thumbnailing must be independent of content path.
**Phase:** C (File Provider integration)

### Pitfall 15: `.thumbnails/` prefix collides with user's legacy folder
**What:** User has existing `.thumbnails` folder from another tool. v3.1 reads/writes there, corrupts user data.
**Prevention:** Detect existing `.thumbnails/` at drive setup. If present with objects that don't match our naming/format, refuse to enable OR use more uncollidable prefix (`.ds3drive/thumbs/` — two levels deep, very unlikely).
**Phase:** A (Foundation) — prefix name decision is irreversible after first ship.

### Pitfall 16: iOS main app suspended mid-generation
**What:** Main app running in background with extension active → ~30s window before suspend → mid-operation JPEG write corrupted.
**Prevention:** All thumbnail PUTs must be **single-part** (never multipart a 30KB JPEG). Use `UIApplication.beginBackgroundTask(withName:)` around individual generate+upload. On `willResignActive`, drain current + stop queue.
**Phase:** D (iOS Backfill)

### Pitfall 17: Thumbnail format metadata missing → regeneration loop
**What:** Can't tell if `.thumbnails/photo.jpg.jpg` was written by v3.1 or future v3.2 with different dimensions.
**Prevention:** Write `x-amz-meta-ds3drive-thumb-version: 1` + `x-amz-meta-ds3drive-thumb-size: 512` on every PUT. On read, version mismatch → pending regen (bounded — not whole bucket on every update).
**Phase:** C (Lifecycle)

---

## Minor Pitfalls

### Pitfall 18: JPEG Q0.7 too aggressive for line-art/screenshots
Ringing artifacts on text. Document as known limitation; defer PNG-fallback heuristic to v3.2.

### Pitfall 19: Pixel vs point confusion
`NSFileProviderThumbnailing.requestedSize` is in pixels. Pass directly into `kCGImageSourceThumbnailMaxPixelSize`. Don't convert via UIKit/AppKit point.

### Pitfall 20: Missing `signalEnumerator(.workingSet)` after backfill
Generates 1000 thumbnails but never signals → Finder shows generic icons until manual refresh. Debounced signal at batch boundaries (max once per 2s, not per-item).

---

## Phase-Specific Warning Matrix

| Phase | Likely Pitfall | Mitigation |
|-------|---------------|------------|
| **A: Foundation + Generator** | #1 iOS imports generator | `#if os(macOS)` gate + target exclusion |
| | #5 EXIF orientation | All four ImageIO options + HEIC rotation fixture |
| | #2 `.thumbnails/` single-site filter | Centralize in `S3KeyFilter` in DS3Lib |
| | #15 User prefix collision | Check at drive setup |
| **B: Storage & Renderer** | #13 Memory spike during decode | `os_proc_available_memory()` guard, format allow-list |
| **C: macOS Integration** | #3 Thumbnail failure breaks upload | Fire-and-forget + catch-all |
| | #4 Custom error domain | Mandatory `NSError.fileProviderThumbnailError` mapper |
| | #12 Stale thumbnail on overwrite | Always regenerate on modify + ETag metadata |
| | #8 Orphaned thumbnails | Delete-after-original, rename = copy-before-delete |
| | #9 Fetch fanout | `ThumbnailFetchLimiter` mirroring `BucketListingLimiter` |
| | #14 Thumbnailing undownloaded items | Read `.thumbnails/` from S3 directly, never download original |
| | #11 Bulk backfill cost spike | Opportunistic default, user-triggered for existing |
| | #6 HEIC performance cliff | Format allow-list + thermal-state gating |
| | #10 Reconciler never terminates | Negative cache + iteration cap + progress telemetry |
| **D: iOS Backfill** | #7 Force-quit disables BG | Foreground-primary UX; BG is supplemental |
| | #16 Main-app suspend mid-generation | Single-part PUT + `beginBackgroundTask` per op |
| | #6 HEIC on A9/A10 | Thermal-state gating, defer heavy to BG slots |
| **Polish** | #17 Format versioning | `x-amz-meta-ds3drive-thumb-version` |
| | #20 Missing enumerator signal | Debounced `.workingSet` signal at batch boundaries |

---

## Key Findings

1. **iOS extension = consume-only is the single load-bearing architectural decision.** Any generation on iOS extension is a ticking jetsam bomb. Enforce via `#if os(macOS)` from day one — not retrofittable.

2. **Three regression multipliers must land together in Phase C:** (a) centralized `.thumbnails/` filter via `S3KeyFilter`, (b) fire-and-forget decoupling of thumbnail from upload lifecycle, (c) mandatory `NSError` domain mapper at `fetchThumbnails` boundary. Missing any one causes user-visible breakage.

3. **`BGProcessingTask` is unreliable by design** (force-quit disables). Treat as bonus, not primary. Foreground iOS main app + macOS extension via shared `.thumbnails/` prefix is the guaranteed completion path.

4. **Bulk backfill on existing buckets is the highest-cost-risk scenario.** Default to opportunistic; never eager-scan on feature launch.

5. **EXIF orientation** is the highest-probability "invisible in QA, visible in prod" bug. `kCGImageSourceCreateThumbnailWithTransform: true` is mandatory, needs fixture-backed test.

## Open Questions for Codebase Audit

- Exact list of S3 `ListObjectsV2` call sites (for filter centralization audit) — needs codebase-research before Phase A scoping.
- Actual iOS File Provider extension jetsam budget on A9/A10 vs A14+ — v2.0 says "tight," Apple doesn't publish. Empirical measurement recommended before finalizing generator's memory guard.
- Whether Cubbit DS3 supports S3 `Range` requests on HEIC (for truncated-decode optimization in Pitfall 11).
- Whether existing `BucketListingLimiter` can be generalized to reusable `S3RequestLimiter`.

## Sources

### Apple Documentation
- [`NSFileProviderThumbnailing.fetchThumbnails`](https://developer.apple.com/documentation/fileprovider/nsfileproviderthumbnailing/fetchthumbnails(for:requestedsize:perthumbnailcompletionhandler:completionhandler:))
- [`kCGImageSourceCreateThumbnailWithTransform`](https://developer.apple.com/documentation/imageio/kcgimagesourcecreatethumbnailwithtransform)
- [`CGImageSourceCreateThumbnailAtIndex`](https://developer.apple.com/documentation/imageio/cgimagesourcecreatethumbnailatindex(_:_:_:))

### Memory & Background Task Constraints
- Dealing with memory limits in iOS app extensions — Igor Kulman
- Background fetch after app is force-quit — Apple Developer Forums
- BGProcessingTask Terminated Due to... — Apple Developer Forums
- Common Reasons for Background Tasks to Fail — Andy Ibanez

### Project-Specific Context
- CLAUDE.md — File Provider error-domain rule, 20 MB jetsam context
- PROJECT.md — v3.1 milestone spec
- `.planning/milestones/v2.0-research/PITFALLS.md` — Prior v2.0 research (BucketListingLimiter pattern, error-code mapping, sync anchor rules)
- MEMORY.md — "NEVER return custom error types to the File Provider system"
