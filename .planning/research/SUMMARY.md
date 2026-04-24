# Research Summary: v3.1 Thumbnails

**Milestone:** v3.1 Thumbnails
**Synthesized:** 2026-04-11
**Sources:** STACK.md, FEATURES.md, ARCHITECTURE.md, PITFALLS.md
**Overall confidence:** HIGH

## 1. Milestone in One Sentence

Ship image thumbnails in Finder and the iOS Files app by mirroring originals to a hidden `.thumbnails/` S3 prefix, with the macOS File Provider extension and the iOS main app as independent generators and the iOS File Provider extension strictly consume-only, using only already-linked Apple frameworks plus existing Soto v6.

## 2. Key Architectural Decisions (load-bearing)

1. **iOS File Provider extension is consume-only. Forever.** 20 MB jetsam budget makes any ImageIO decode a ticking bomb. Enforced with `#if os(macOS)` around every generator type — not retrofittable.
2. **`.thumbnails/` S3 prefix, mirrored layout, extension appended (not substituted).** `photos/a.heic` → `photos/.thumbnails/a.heic.jpg`. Mirrors the existing `.trash/` precedent end-to-end.
3. **Upload lifecycle and thumbnail lifecycle are decoupled.** `createItem`/`modifyItem` returns success the instant the original is durable on S3. Thumbnail is fire-and-forget on a separate bounded queue, catches all errors, never propagates.
4. **Shared `ThumbnailBackfillCoordinator` actor in DS3Lib, renderer injected per host.** Same code runs in macOS extension (BFS passes) and iOS main app (BGProcessingTask + foreground driver). One algorithm, two hosts.
5. **Opportunistic, never eager.** No full-bucket scan on feature launch. New uploads inline; existing content backfills as Finder/Files enumerates. User-invokable "Generate now" escape valve.

## 3. Stack Additions

Zero new third-party dependencies. Already-linked Apple frameworks + existing Soto v6.

| Framework | Where | Purpose | Critical flags |
|-----------|-------|---------|----------------|
| **ImageIO** | macOS ext, iOS main app — **NOT iOS ext** | Memory-bounded decode | `kCGImageSourceShouldCache: false` + `kCGImageSourceShouldCacheImmediately: true` + `kCGImageSourceCreateThumbnailWithTransform: true` + `kCGImageSourceCreateThumbnailFromImageAlways: true` — all four mandatory, wrapped in `autoreleasepool` |
| **UniformTypeIdentifiers** | All | Format allow-list | `public.jpeg / png / heic / heif / webp / gif / tiff` only |
| **BackgroundTasks** (`BGProcessingTask`) | iOS main app | Overnight backfill | Identifier `io.cubbit.DS3Drive.thumbnailBackfill`; needs `processing` `UIBackgroundMode` + "Background processing" capability |
| **FileProvider** (`NSFileProviderThumbnailing`) | macOS ext + iOS ext | Consumption | Errors MUST be `NSFileProviderErrorDomain` / `NSCocoaErrorDomain`; `(id, nil, nil)` on miss |
| **Soto v6** (existing) | All | `.thumbnails/<key>.jpg` put/get/delete | Single-part PUT only (~30–60 KB) |

**Latent bug to fix in Phase A:** `+ThumbnailGenerators.swift:11` passes `nil` source options — missing `kCGImageSourceShouldCache: false`.

**Format targets:** 512 px long edge, JPEG Q0.7, ~40–60 KB, single fixed size.

## 4. Feature Categorization

### Table Stakes — all P1, all ship

| # | Feature | Cost | Notes |
|---|---------|------|-------|
| TS-1 | Cloud-only image thumbnails | MED | Core `fetchThumbnails` rewrite |
| TS-2 | Inline on upload | LOW/MED | macOS inline, iOS next-cycle |
| TS-3 | Backfill for existing/remote-uploaded | MED | macOS: BFS opportunistic. iOS: BGProcessingTask + foreground |
| TS-4 | No full-download for thumbnailing | LOW | Property of TS-1 |
| TS-5 | Raster format coverage | LOW | jpg/png/heic/heif/webp/gif/tiff; RAW/PDF/video deferred |
| TS-6 | EXIF orientation | LOW | All four ImageIO flags + HEIC fixture |
| TS-7 | Lifecycle cascade | MED | Delete/rename/move + orphan sweep |
| TS-8 | `.thumbnails/` hidden from enumeration | LOW | **Blocks TS-1 exposure — must land first** |
| TS-9 | Coexists with sync badges | LOW | Validation |
| TS-10 | Graceful failure fallback | LOW | `NSError` domain mapper |
| TS-11 | Respects pause/resume | LOW | Reads `DS3DriveManager` state |

### Differentiators — should ship for polish

| # | Feature | Cost |
|---|---------|------|
| DIFF-1 | Tray "Thumbnails N/M" progress per drive | LOW |
| DIFF-2 | On-device privacy positioning (docs only) | ZERO |
| DIFF-5 | Manual "Generate now" in settings | LOW |
| DIFF-7 | Quick Look uses thumbnail as low-res preview | ZERO |

### Anti-features — hard no

ANTI-1 in-app viewer, ANTI-2 multi-size, ANTI-3 server-side, ANTI-4 face detection, ANTI-5 RAW, ANTI-6 PDF/video, ANTI-7 sibling-file layout, ANTI-11 camera-roll upload, ANTI-12 blocking pre-gen at drive setup.

## 5. Build Order

Ordering constraints: (a) iOS extension consume-only, (b) filter must land before any write, (c) DS3Lib lands before consumers, (d) upload-path and reconciliation-path are layered.

### Phase A — Foundation & Filtering (DS3Lib only, zero user-visible change)

- `DefaultSettings.S3.thumbnailsPrefix` + size/quality constants
- `S3PathUtils` helpers mirroring `trashPrefix` set
- `ThumbnailKey` value type with extension-append rule + tests
- **Centralized `S3KeyFilter.isUserVisible(key:)`** — every list consumer routes through it
- `.thumbnails/` filter at `S3Enumerator.swift:416-418` + `:~310` + `BreadthFirstIndexer` dequeue skip
- Drive-setup collision check (refuse enable if bucket has non-DS3 `.thumbnails/` content)
- Fix `kCGImageSourceShouldCache: false` latent bug in `+ThumbnailGenerators.swift:11`

**Why first:** Filter is a no-op (no thumbs exist yet) — landing it silently is the only safe ordering; if it ships after generation, the prefix appears in dev builds and poisons dogfood.

### Phase B — Renderer, Storage & Schema (DS3Lib only, still zero user-visible)

- `ThumbnailRenderer` — ImageIO raster-only, `autoreleasepool` + all four flags + `os_proc_available_memory()` guard + format allow-list
- `ThumbnailS3Service` — put/get/delete/headIfExists, single-part PUT only
- Schema V3: `thumbnailStatus: .notApplicable | .pending | .uploaded | .failed`
- `MetadataStore.fetchItemsNeedingThumbnail(...)` + `setThumbnailStatus(...)`
- `SharedData+thumbnailSettings` mirroring `+trashSettings`
- `ThumbnailBackfillCoordinator` actor scaffolded (not yet called)
- Unit tests with Git LFS fixtures: JPEG + HEIC with EXIF orientation 6

### Phase C — macOS generation & consumption (first user-visible value)

- `UploadThumbnailHook` at `+Create.swift:220` + `+Modify.swift:154`, **fire-and-forget + catch-all**, `#if os(macOS)`
- `fetchThumbnails` cache-first refactor at `+Thumbnails.swift:157-249`:
  - HIT: return S3-stored bytes
  - MISS macOS: existing download-and-generate fallback + enqueue `.pending`
  - MISS iOS: `(nil, nil)` + enqueue `.pending` via App Group
- **Mandatory `NSError.fileProviderThumbnailError(from:)` mapper** wrapping outermost `do/catch`
- `ThumbnailFetchLimiter` mirroring `BucketListingLimiter` (macOS 4, iOS 2)
- `DeleteThumbnailHook` + `MoveThumbnailHook` — delete-after-original, rename = copy-before-delete
- `ThumbnailBackfillCoordinator` invoked from `BreadthFirstIndexer.runOneBFSPass()` with per-pass budget (~20 thumbs) + thermal-state gating
- Orphan sweep every N passes
- Negative cache (`thumbnail_unprocessable` after 3 failures)
- `signalEnumerator(.workingSet)` debounced at batch boundaries
- ETag-based staleness: `x-amz-meta-source-etag` on thumbnail

**Why here:** Three regression multipliers (centralized filter, fire-and-forget decoupling, mandatory NSError mapper) ALL land here. **iOS automatically benefits** — cache-first consumer is cross-platform.

### Phase D — iOS generation & polish

- `iOSThumbnailBackfillTask` registering `BGProcessingTaskRequest` (`requiresExternalPower = true`, `requiresNetworkConnectivity = true`)
- Task body invokes shared `ThumbnailBackfillCoordinator` with `ThumbnailRenderer` — **same code path as Phase C**
- Expiration handler (<1s return, cancel flag only)
- `ForegroundBackfillDriver` observing `ScenePhase.active` — **guaranteed completion path on iOS** since BGProcessingTask is unreliable after force-quit
- `UIApplication.beginBackgroundTask(withName:)` around each generate+upload
- Cellular gating via `NWPathMonitor.isExpensive`
- `Info.plist`: `BGTaskSchedulerPermittedIdentifiers` + `processing` `UIBackgroundModes`
- Xcode: "Background processing" capability on DS3DriveApp target
- iOS settings UI: progress + UX copy about BG unreliability after force-quit
- DIFF-1 tray progress + DIFF-5 manual "Generate now"

**Why last:** iOS is consume-only platform. Ship consume path first (Phase C), verify iOS end-to-end against macOS-generated thumbnails, then light up iOS-side generation.

## 6. Watch Out For

| # | Pitfall | Phase | Prevention |
|---|---------|-------|------------|
| 1 | iOS extension ImageIO → jetsam kill | A | `#if os(macOS)` gate on generator type |
| 2 | `.thumbnails/` phantom folder in Finder | A | Centralized `S3KeyFilter.isUserVisible` |
| 4 | Custom error domain wedges thumbnails | C | Mandatory `NSError.fileProviderThumbnailError` mapper |
| 3 | Thumbnail failure breaks file upload | C | Fire-and-forget, catch-all, never rethrow |
| 5 | EXIF orientation ignored → sideways photos | B | All four ImageIO flags + fixture |
| 11 | Bulk backfill cost spike + rate limiting | C+D | Opportunistic default, "Generate now" escape, cellular gating |
| 7 | BGProcessingTask disabled after force-quit | D | Foreground-primary UX; BG is supplemental |
| 10 | Reconciliation at 99% forever | C | Negative cache after 3 failures; UI counts unprocessable as done |
| 8 | Rename/delete cascade orphans | C | Delete-after-original; rename = copy-before-delete; orphan sweep |
| 9 | 500 parallel `fetchThumbnails` → `SlowDown` | C | `ThumbnailFetchLimiter` |

## 7. Open Questions for Roadmapper

1. **Key mapping: append vs. substitute extension.** Recommendation: **append** (`a.heic` → `.thumbnails/a.heic.jpg`).
2. **Single-size policy numbers.** Recommendation: **512 px long edge, JPEG Q0.7**.
3. **Schema V3 vs. FOUN-04.** Recommendation: **focused V3 delta** — don't gate on FOUN-04.
4. **Bulk backfill default policy.** Recommendation: **opportunistic only**; never eager-scan.
5. **iOS foreground driver automaticity.** Recommendation: **automatic on Wi-Fi only**; user toggle for cellular.
6. **macOS BFS backfill budget.** Suggest 20 thumbs/pass; empirical tuning in Phase C.
7. **Trash cascade.** Recommendation: **hard-delete thumbnails on trash, regenerate on restore**.
8. **Orphan sweep cadence.** Needs explicit N/M.

## 8. Cross-Doc Notes (No Hard Contradictions)

- **Memory safety = belt-and-suspenders:** STACK and PITFALLS both flag memory — resolved by `#if os(macOS)` + `autoreleasepool` + all four ImageIO flags + format allow-list + `os_proc_available_memory()`. All mandatory together.
- **Filter centralization:** ARCHITECTURE names three sites; PITFALLS insists on centralized `S3KeyFilter`. Resolution: centralize, have the three sites call into it. Phase A needs a list-S3 call-site audit.
- **iOS "inline" on upload:** FEATURES says inline; STACK/ARCHITECTURE say enqueue-and-generate-later. Resolution: iOS generation is inline-from-user-perspective but next-foreground-cycle technically. Document honestly in progress UI.

## Confidence

| Area | Level |
|------|-------|
| Stack | HIGH |
| Features | HIGH |
| Architecture | HIGH |
| Pitfalls | HIGH |
| Quantitative cost estimates (size, batch, jetsam headroom) | MEDIUM — empirical tuning in Phase C/D |
| Schema V3 migration risk | MEDIUM |

## Gaps to Address During Planning

- List-S3 call-site audit in Phase A (grep every `ListObjectsV2` consumer)
- Empirical iOS memory measurement on oldest supported device before finalizing `os_proc_available_memory()` threshold
- Whether `BucketListingLimiter` can generalize to `S3RequestLimiter`
- Empirical JPEG Q0.7 validation on line-art / screenshots (ringing artifacts known)

---

**Ready for requirements:** Yes. 4 phases recommended.
