# Feature Research: Thumbnails for DS3 Drive v3.1

**Domain:** Consumer file sync app — thumbnail previews for image files
**Researched:** 2026-04-11
**Confidence:** HIGH
**Mode:** Ecosystem / feature landscape

## Executive Framing

The question for this milestone is narrow: "what does a user expect to see when they scroll a folder full of JPEGs in Finder or the iOS Files app while DS3 Drive is the provider?" The bar is set by Dropbox, iCloud Drive, Google Drive (desktop), and OneDrive — all four ship thumbnails in the OS file browser. Google Photos and iCloud Photos set a higher bar but target a different surface (a dedicated photo app), which is explicitly out of scope per PROJECT.md.

Key insight: because DS3 Drive renders inside Finder and Files.app, **all the "viewer" features are already provided by the OS for free** (Quick Look, Preview, the iOS Files preview sheet). The remaining job is purely "give the OS a small raster it can show as the icon of a cloud-only file." That dramatically shrinks the table-stakes list.

The File Provider thumbnail surface is `NSFileProviderReplicatedExtension.fetchThumbnails(for:requestedSize:perThumbnailCompletionHandler:completionHandler:)`. The OS asks for thumbnails; we either produce bytes or return an error.

## Feature Landscape

### Table Stakes (Users Expect These)

| # | Feature | User-observable behavior | Dependency on existing DS3 Drive capabilities | Complexity |
|---|---------|--------------------------|-----------------------------------------------|------------|
| TS-1 | **Thumbnails for cloud-only image files** | Finder icon view / Files.app grid shows preview without full download | Hooks into `fetchThumbnails` on `NSFileProviderReplicatedExtension`. Reuses S3Enumerator identifier→key mapping. Must bypass `fetchContents`. | MEDIUM |
| TS-2 | **Immediate thumbnails for files uploaded from this device** | Icon flips from generic to preview within seconds of upload | macOS: inline in `createItem`/`modifyItem`. iOS: blocked in extension by 20MB limit — handled by iOS main-app backfill, one-cycle delay acceptable. | MEDIUM |
| TS-3 | **Thumbnails for files uploaded on other devices eventually appear** | Opening a folder uploaded via web or another client shows thumbnails within an enumeration cycle | Opportunistic backfill during enumeration on macOS extension. BGProcessingTask on iOS. | MEDIUM |
| TS-4 | **No full-file download triggered for thumbnailing** | Browsing a folder of 40MB HEICs doesn't fill local disk | Consumer devices GET `.thumbnails/<key>.jpg`, never call `fetchContents` | LOW (property of TS-1) |
| TS-5 | **Supported formats match OS preview** | JPEG, PNG, HEIC/HEIF, GIF, TIFF, WebP — raster set ImageIO handles | ImageIO is a system framework, no new dependency | LOW |
| TS-6 | **Correct EXIF orientation** | Photos shot on phones display right-side-up | `CGImageSourceCreateThumbnailAtIndex` with `kCGImageSourceCreateThumbnailWithTransform: true` | LOW (but critical — single most visible thumbnail bug) |
| TS-7 | **Thumbnail lifecycle follows original** | Delete/rename/move of original cascades to thumbnail — no orphans | Hooks into existing `deleteItem`/`modifyItem` rename paths | MEDIUM |
| TS-8 | **`.thumbnails/` prefix invisible to users** | Root enumeration does not show `.thumbnails` folder | Reuses existing `.trash` filter pattern in S3Enumerator | LOW — **must land before TS-1 exposure** |
| TS-9 | **Coexists with sync status badges** | Cloud badge / synced check overlay work on top of thumbnail | File Provider handles compositing via `decorations` — validation, not new code | LOW |
| TS-10 | **Graceful degradation for missing/failed thumbnails** | Default format icon shown, not broken placeholder or stuck spinner, not original download | Return `NSFileProviderErrorDomain` — do NOT return custom error types (MEMORY.md constraint) | LOW |
| TS-11 | **Respects existing pause/resume state** | Paused drive halts thumbnail backfill along with transfers | Backfill worker reads DS3DriveManager pause state | LOW |

### Differentiators (Competitive Advantage)

| # | Feature | Value proposition | Complexity |
|---|---------|-------------------|------------|
| DIFF-1 | **Tray-menu "Thumbnails: N/M" progress indicator per drive** | Honest status — no competitor surfaces backfill state. Reuses existing tray infra + NotificationManager IPC. | LOW (macOS) |
| DIFF-2 | **On-device generation — privacy story** | "Your photos are never uploaded to an AI service." Aligns with Cubbit sovereignty positioning. Competitors (Dropbox, Google) generate server-side. | ZERO technical — positioning only |
| DIFF-3 | **Opportunistic macOS backfill during enumeration** | Browse a folder → backfill triggers → come back, thumbnails filled in. (Same feature as TS-3 macOS, named for marketing.) | MEDIUM |
| DIFF-4 | **Overnight iOS BGProcessingTask backfill** | iPhone user with 10k cloud photos wakes up to fully thumbnailed drive. (Same feature as TS-3 iOS.) | MEDIUM |
| DIFF-5 | **"Generate now" manual trigger in settings** | Power-user escape valve. Reuses backfill worker + IPC. | LOW |
| DIFF-6 | **Share Extension preview on pre-upload** | Source's `NSItemProvider` already provides preview — surface it in share sheet UI | LOW |
| DIFF-7 | **Quick Look low-res preview from thumbnail** | Spacebar preview on cloud-only file shows thumbnail first while full file downloads — matches iCloud Drive | ZERO — validation of TS-1 |

### Anti-Features (Commonly Requested, Refused)

| # | Anti-feature | Reasoning |
|----|--------------|-----------|
| ANTI-1 | **In-app photo viewer / gallery grid** | Files.app and Finder are already the file browser. PROJECT.md out-of-scopes "In-app file browser on iOS". |
| ANTI-2 | **Multiple thumbnail sizes (64/128/256/512/1024)** | ~5x storage and CPU cost. One fixed size (512×512 JPEG ~40KB) satisfies icon view + Quick Look. |
| ANTI-3 | **Server-side thumbnail generation** | PROJECT.md hard constraint: "No custom backend." Also contradicts DIFF-2 privacy story. |
| ANTI-4 | **Face detection, auto-tagging, smart albums** | Requires ML models (jetsam-hostile) or backend (forbidden). Not a sync-client feature. |
| ANTI-5 | **RAW file thumbnails in v3.1** | RAW decoding is memory-intensive, can exceed 20MB. Defer to v3.2+. PROJECT.md already defers. |
| ANTI-6 | **PDF / video thumbnails in v3.1** | PDFKit and AVFoundation expand the format matrix. PROJECT.md defers. |
| ANTI-7 | **Thumbnails adjacent to originals (`.key.jpg`)** | Pollutes listings, complicates filter. Use `.thumbnails/` prefix. |
| ANTI-8 | **User-facing "thumbnail quality" slider** | Zero user value, forks generator. Hardcode 80% JPEG. |
| ANTI-9 | **Separate thumbnail encryption** | Inherit bucket-level encryption. For future zero-knowledge drives, use same per-drive key. |
| ANTI-10 | **Regenerate on metadata change** | EXIF-only edits don't change pixels. Invalidate by original's ETag. |
| ANTI-11 | **"Upload all photos" / camera roll import** | That's Google Photos territory. PROJECT.md out-of-scopes camera upload. |
| ANTI-12 | **Pre-generating thumbnails during drive setup (blocking)** | Makes setup feel broken. Backfill is always async. Use DIFF-1 for visibility. |

## Feature Dependency Ordering

1. **TS-8 must land before TS-1 ships externally** — otherwise early testers see `.thumbnails` folder and file bugs.
2. **TS-1 + TS-5 + TS-6 + TS-9 + TS-10 together** are the minimum viewable increment.
3. **TS-2 depends on TS-1 storage layout** — inline generator writes where reader consumes.
4. **TS-3 splits cleanly along macOS / iOS boundary** — either can ship first.
5. **TS-7 (lifecycle) can land last** among table stakes — orphans are invisible (only cost S3 storage).
6. **DIFF-1 after TS-3 is functional**.

## Competitor Reference

| Behavior | Dropbox | iCloud Drive | Google Drive | OneDrive | DS3 Drive v3.1 |
|----------|---------|--------------|--------------|----------|-----------------|
| Cloud-only thumbnails | Yes | Yes | Yes | Yes | TS-1 |
| Server-side generated | Yes | Yes | Yes | Yes | **No — on-device (DIFF-2)** |
| Inline on upload | Yes | Yes | Yes | Yes | macOS: yes, iOS: next-cycle |
| Remote backfill | Yes | Yes | Yes | Yes | TS-3 |
| No-download thumbnailing | Yes | Yes | Yes | Yes | TS-4 |
| Raster format coverage | Yes | Yes (+RAW/PDF/video) | Yes (+PDF/video) | Yes (+PDF/video) | Raster only — TS-5 |
| EXIF orientation | Yes | Yes | Yes | Yes | TS-6 |
| Lifecycle cascade | Yes | Yes | Yes | Yes | TS-7 |
| Storage hidden from user | Yes | Yes | Yes | Yes | TS-8 |
| Coexists with badges | Yes | Yes | Yes | Yes | TS-9 |
| **User-visible backfill progress** | No | No | No | No | **Yes — DIFF-1** |
| **User-invokable "generate now"** | No | No | No | No | **Yes — DIFF-5** |
| In-app photo viewer | No | No | No | No | ANTI-1 |

## MVP Definition (v3.1)

### Must ship
- TS-8 (hide `.thumbnails/` — blocker for TS-1 exposure)
- TS-1, TS-4, TS-5, TS-6, TS-9, TS-10 (minimum viewable increment)
- TS-2 macOS + iOS
- TS-3 macOS (opportunistic backfill) + iOS (BGProcessingTask)
- TS-7 (lifecycle cascade)
- TS-11 (pause/resume respected)

### Should ship for polish
- DIFF-1 (tray progress indicator)
- DIFF-5 (manual "generate now")
- DIFF-7 (Quick Look validation)

### Can defer to v3.2+
- DIFF-6 (Share Extension preview)
- RAW, PDF, video support (explicitly deferred)

### Never
- ANTI-1 through ANTI-12

## Priority / Cost Matrix

| Feature | User value | Impl cost | Priority |
|---------|------------|-----------|----------|
| TS-1 | HIGH | MEDIUM | P1 |
| TS-2 macOS | HIGH | LOW | P1 |
| TS-2 iOS | HIGH | MEDIUM | P1 |
| TS-3 macOS backfill | HIGH | MEDIUM | P1 |
| TS-3 iOS BGProcessingTask | HIGH | MEDIUM | P1 |
| TS-4 | HIGH | LOW (property of TS-1) | P1 |
| TS-5 | HIGH | LOW | P1 |
| TS-6 | HIGH | LOW | P1 |
| TS-7 | MEDIUM | MEDIUM | P1 |
| TS-8 | HIGH | LOW | P1 |
| TS-9 | HIGH | LOW (validation) | P1 |
| TS-10 | MEDIUM | LOW | P1 |
| TS-11 | MEDIUM | LOW | P1 |
| DIFF-1 | MEDIUM | LOW | P2 |
| DIFF-2 | MEDIUM | ZERO (docs) | P2 |
| DIFF-5 | MEDIUM | LOW | P2 |
| DIFF-6 | LOW | LOW | P3 |
| DIFF-7 | LOW | ZERO (validation) | P2 |

## Open Questions (implementation phase, not milestone definition)

1. **Thumbnail size / quality target** — suggest 512×512 JPEG @ quality 0.8 (~40–60KB), empirical validation needed
2. **Exists-check mechanism** — S3 HEAD per item vs. list `.thumbnails/<prefix>` and diff
3. **Concurrency cap for backfill** — 2–4 parallel (mind HTTP/2 StreamClosed issue from MEMORY.md)
4. **iOS BGProcessingTask resumable checkpoint** — per-drive cursor into backfill queue
5. **ETag-based regeneration trigger** — attach original's ETag as S3 object metadata on thumbnail

## Confidence

| Area | Confidence |
|------|------------|
| Competitor observable behavior | HIGH |
| Apple File Provider API surface | HIGH |
| ImageIO format support | HIGH |
| iOS 20MB jetsam ceiling behavior | HIGH |
| User expectation delta | HIGH |
| Quantitative cost estimates | MEDIUM — requires pilot |
