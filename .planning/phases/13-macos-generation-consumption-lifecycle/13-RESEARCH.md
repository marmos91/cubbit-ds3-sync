# Phase 13: macOS Generation, Consumption & Lifecycle - Research

**Researched:** 2026-04-25
**Domain:** Wiring Phase 11/12 thumbnail substrate into user-visible flows on macOS — File Provider hooks, Schema V4, S3 cascades, BFS-driven backfill, terminating reconciliation, silent rollout
**Confidence:** HIGH

## Executive Summary

Phase 13 is a **wiring phase, not a primitives phase**. Phase 12 already shipped the renderer, S3 put/get/delete, Schema V3 with `thumbnailStatus`, the coordinator scaffold (already wired end-to-end fetchPending → download → render → put), and `SharedData+thumbnailSettings`. Phase 11 already shipped the path utilities, filter, and rollout collision check. Phase 13 turns the silent payload into the first user-visible feature on macOS by:

1. Adding the upload-time hook (`ThumbnailUploader` + post-PUT `Task.detached` in `+Create` / `+Modify`).
2. Rewriting `fetchThumbnails` to be cache-first (read `.thumbnails/<key>.jpg`, fall back to nil + mark pending) — a strict refactor that DELETES the existing inline download-and-generate fallback.
3. Adding `ThumbnailFetchLimiter` (actor in DS3DriveProvider, slots = 4 on macOS).
4. Hooking BFS pass tail to invoke `coordinator.runBatch(maxItems: 5)` with thermal gating + pause-awareness.
5. Adding delete/rename/move cascades using existing `deleteThumbnail` + new `copyThumbnail` (Soto's `copyObject` already exists in `DS3S3Client.swift:326-342` — we just call it with `metadata: nil` to get default `metadataDirective: COPY` semantics).
6. Tying orphan sweep to BFS pass tail using the already-built `allPassKeys: Set<String>` in `BreadthFirstIndexer.runOneBFSPass`.
7. Schema V4 adds `thumbnailFailCount: Int = 0` (lightweight migration; mirror of V2→V3); coordinator/uploader transition to `.failed` at count >= 3.
8. Silent auto-on rollout in `FileProviderExtension+Lifecycle` (once-per-drive `inspectThumbnailPrefix` re-check, persist).

**No alternatives are evaluated** — all 36 D-decisions are locked. This document supplies the technical specifics needed to execute them under Swift 6 strict concurrency on CI Xcode 16.2.

**Primary recommendation:** Treat the existing coordinator's `runBatch` (already shipped in Phase 12, already wired fetchPending → render → put end-to-end) as the integration target. Phase 13 *extends* it with thermal/pause/cancellation/strike-count, but does NOT rewrite the body.

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

**Rollout & Feature Gating**
- **D-01:** Silent auto-on for all eligible drives. On extension/app launch, iterate drives; for each drive call `inspectThumbnailPrefix`; if state ∈ {.empty, .matchesOurs} set `ThumbnailSettings.enabled = true` and persist. `.conflicting` stays disabled.
- **D-02:** Once-per-drive collision re-check. First v3.1 launch runs the check; subsequent launches read `enabled` without re-checking.
- **D-03:** Completely silent first-run UX. No notifications, toasts, or "What's New" cards.
- **D-04:** Disable = leave existing thumbnails in place. Re-enable reuses existing keys.
- **D-05:** Kill-switch via SharedData JSON only (no UI in Phase 13).

**Upload-Time Generation (THUMB-06)**
- **D-06:** Fire-and-forget `Task.detached` in `createItem` / `modifyItem` post-PUT. The Task is fully isolated from the upload completion handler.
- **D-07:** `ThumbnailUploader` is a separate, simpler type — NOT shared with the coordinator. Struct, Sendable. Renders + puts (does not fetch pending or batch).
- **D-08:** Pre-filter via `S3PathUtils.isRasterExtension(_:) -> Bool` (new helper). Non-raster: silently mark `.notApplicable`, return.
- **D-09:** `ThumbnailUploader.generateAndUpload` is `#if os(macOS)`-gated (function, not type).
- **D-10:** Modify cascade is the same code path. No HEAD-compare, no staleness detection — re-render unconditionally on `modifyItem` content change.

**Consume Path (THUMB-11, 12, 13, 14)**
- **D-11:** Cache-first miss → return nil + mark `.pending` in MetadataStore. No inline render, no inline S3 download, no synchronous coordinator nudge.
- **D-12:** `ThumbnailFetchLimiter` is a DS3DriveProvider actor (slots = 4 on macOS). Wraps the `fetchThumbnails` consume path. Upload-path bypasses; backfill coordinator has its own concurrency = 1.
- **D-13:** Error mapping at the File Provider boundary: 404 → `.noSuchItem`; Soto network/5xx/SlowDown → `.serverUnreachable`; auth → `.cannotSynchronize`. Renderer/S3/Soto errors NEVER cross.
- **D-14:** No SlowDown inline retry. Map directly to `serverUnreachable`.
- **D-15:** Sync status badges unchanged — Phase 13 only changes WHERE thumbnail bytes come from.

**Backfill Orchestration (THUMB-15, 21, 23)**
- **D-16:** One coordinator per drive, owned by `BreadthFirstIndexer`.
- **D-17:** BFS hook fires after every successful BFS pass tail. `try? await thumbnailCoordinator.runBatch(maxItems: 5)` if `enabled && !paused`.
- **D-18:** Fixed `maxItems = 5`. New constant `DefaultSettings.Thumbnail.backfillBatchSize = 5`.
- **D-19:** Thermal gating: skip when `ProcessInfo.processInfo.thermalState >= .serious` (read once per batch).
- **D-20:** Pause = don't start next batch + cancel in-flight Task at next render boundary. Coordinator checks pause at function entry + per loop iteration; uses `try Task.checkCancellation()` between phases (download/render/put/persist). On pause mid-batch, complete in-flight PUT then exit.

**Cascades (THUMB-17, 18)**
- **D-21:** Delete cascade — fire-and-forget Task in `+Delete` after successful original-delete. `try? await s3Client.deleteThumbnail(...)`. Failures fall to orphan sweep.
- **D-22:** Rename/move cascade — server-side `copyThumbnail(old → new)` + `deleteThumbnail(old)`. On copy failure, mark new key `.pending` so backfill regenerates.
- **D-23:** `copyThumbnail` ships in Phase 13. Soto's `S3.copyObject(CopyObjectRequest)` with `metadataDirective: .copy` (default when metadata is nil). Add to `DS3S3ClientProtocol`.
- **D-24:** Move cascade is the same path as rename.

**Orphan Sweep (THUMB-19)**
- **D-25:** Tied to BFS pass tail; piggybacks on enumeration data. List `<drive.prefix>.thumbnails/`, derive original key, if not in BFS-enumerated set → bulk-delete (max 50 per pass).
- **D-26:** Sweep cap = 50 orphan deletes per pass (`DefaultSettings.Thumbnail.maxOrphanDeletesPerPass`).
- **D-27:** Sweep gated by `enabled == true`.
- **D-28:** No HEAD method needed — BFS-enumerated key set is the authority.

**Terminating Reconciliation (THUMB-20)**
- **D-29:** Schema V4 adds `thumbnailFailCount: Int = 0` on V4.SyncedItem. Lightweight V3→V4 migration.
- **D-30:** `fetchPendingThumbnails` predicate excludes `.failed` (already does).
- **D-31:** Reset condition: original ETag changes. Upsert path resets `thumbnailFailCount = 0` AND `thumbnailStatus = .pending`.
- **D-32:** No timestamp/cooldown tracking. BFS cadence IS the backoff.
- **D-33:** Schema V4 migration test mirrors V2→V3 pattern.

**Concurrency, Errors, Tests**
- **D-34:** Heavy unit tests at component boundaries + 2-3 integration smoke tests. No real-S3 in CI.
- **D-35:** Renderer errors never cross File Provider boundary.
- **D-36:** `ThumbnailFetchLimiter` lives in DS3DriveProvider (extension-side, not DS3Lib).

### Claude's Discretion
- Exact file layout under `DS3Lib/Sources/DS3Lib/Thumbnails/` (new files vs. extension files for `ThumbnailUploader`).
- Whether to extract a tiny `ThumbnailRollout` helper from the launch-time auto-on iteration logic (D-01, D-02) or inline it in `+Lifecycle`.
- Exact placement of the BFS hook callout (D-17) — at the end of `runOneBFSPass` directly, or via a delegate / callback.
- Whether to share an actor-isolated `OrphanSweeper` with the coordinator or inline orphan-sweep logic in the BFS hook callout (recommend small dedicated type for testability).
- Whether to add a small `BatchScheduler` actor that owns `runBatch` cadence + thermal gating, or keep that logic inside `ThumbnailBackfillCoordinator.runBatch` (recommend the latter).
- Naming of `S3PathUtils.isRasterExtension(_:)` — could also be `isRasterFilename(_:)`.
- Concurrency primitive inside `ThumbnailFetchLimiter` (counting semaphore, async-channel, etc. — pick what reads cleanest in actor land).
- Test file naming and grouping inside `DS3LibTests` and `DS3DriveProviderTests`.

### Deferred Ideas (OUT OF SCOPE)
- Tray progress UI on macOS (THUMB-24) — *dropped* from v3.1, not deferred.
- `MetadataStore.countPendingThumbnails` — Phase 14 if iOS Settings UI needs it.
- Per-drive enabled toggle in Preferences UI — Phase 14.
- HEAD method on `DS3S3Client` — still deferred.
- Adaptive batch size — Phase 14+.
- Exponential backoff between strikes — not needed (BFS cadence IS the backoff).
- Cellular gating + manual "Generate now" — Phase 14.
- iOS `BGProcessingTask` + `ForegroundBackfillDriver` — Phase 14.
- iOS Settings progress UI — Phase 14.
- Parallel renders inside coordinator — Phase 14+.
- EXIF thumbnail fast-path — beyond v3.1.
- PNG fallback for line-art — beyond v3.1.
- Video / PDF / RAW thumbnail support — out of scope per REQUIREMENTS.
- WebP / AVIF thumbnail format — beyond v3.1.
- Promoting `BucketListingLimiter` → `S3RequestLimiter` — beyond v3.1.
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| THUMB-06 | macOS extension generates thumbnails inline during upload (fire-and-forget, decoupled) | `ThumbnailUploader` D-06/07/08/09; `Task.detached` patterns from `NotificationsManager.swift`; existing `+Create.swift:231-245` ETag-return seam |
| THUMB-11 | Real thumbnails in Finder for image files including cloud-only, no full-file download | Cache-first rewrite via `getThumbnailBytes`; `fetchThumbnails` cache-first refactor (D-11) |
| THUMB-12 | Thumbnails coexist with sync badges (cloud/synced/syncing/error) | D-15 — existing badge code paths untouched; only thumbnail-byte source changes |
| THUMB-13 | Errors always in `NSFileProviderErrorDomain` / `NSCocoaErrorDomain` — never custom | D-13 error mapping table; CLAUDE.md File Provider Error Handling rule |
| THUMB-14 | Concurrent thumbnail fetches bounded (macOS=4) via `ThumbnailFetchLimiter` | D-12 + D-36 — actor in DS3DriveProvider; mirror of `BucketListingLimiter` |
| THUMB-15 | Backfill opportunistic during BFS passes, budgeted, thermal-gated | D-17 BFS tail hook + D-19 thermal gate + D-18 fixed batch size 5 |
| THUMB-17 | Delete cascade (delete-after-original; orphan sweep backstops failures) | D-21 fire-and-forget after successful S3 delete; D-25 sweep backstop |
| THUMB-18 | Rename/move cascade — server-side copy + delete old | D-22 + D-23 `copyThumbnail` via existing `DS3S3Client.copyObject` (lines 326-342) |
| THUMB-19 | Periodic orphan sweep removes orphans whose originals don't exist | D-25 — piggyback on BFS `allPassKeys: Set<String>` already built in `runOneBFSPass` |
| THUMB-20 | Terminating reconciliation — 3 strikes → silent terminal `.failed` | D-29 Schema V4 + D-31 ETag-change reset; D-30 predicate excludes `.failed` |
| THUMB-21 | Backfill respects per-drive pause/resume | D-20 — pause check at coordinator entry + per iteration; `Task.checkCancellation()` at phase boundaries |
| THUMB-23 | No eager full-bucket scan on feature launch — opportunistic only | D-17 BFS tail hook is the only entry; D-25 orphan sweep also tied to BFS pass |
</phase_requirements>

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| Upload-time generation | DS3DriveProvider extension (macOS) | DS3Lib (`ThumbnailUploader`) | Hooks live in `+Create`/`+Modify`, but the render+PUT pipeline is reusable from DS3Lib |
| Cache-first consume path | DS3DriveProvider extension | DS3Lib (`getThumbnailBytes`) | `fetchThumbnails` boundary is File-Provider-only; S3 GET is DS3Lib |
| Concurrency limiting (consume) | DS3DriveProvider extension (`ThumbnailFetchLimiter`) | — | UI-pacing concern, not a DS3Lib primitive (D-36) |
| Backfill orchestration | DS3Lib (`ThumbnailBackfillCoordinator`) | DS3DriveProvider (BFS hook) | Coordinator already exists in DS3Lib (Phase 12); BFS calls into it |
| BFS hook (pass tail) | DS3DriveProvider (`BreadthFirstIndexer.runOneBFSPass`) | — | Indexer owns the BFS pass; calls coordinator + sweeper |
| Cascades (delete/rename/move) | DS3DriveProvider extension (`+Delete`, `+Modify`) | DS3Lib (`copyThumbnail`, `deleteThumbnail`) | File-Provider request handlers fire-and-forget; S3 ops are DS3Lib |
| Orphan sweep | DS3DriveProvider (BFS hook) | DS3Lib (`copyThumbnail`/`deleteObjects`) | Sweep needs the BFS-built key set, which only the indexer has |
| Terminating reconciliation (strike count) | DS3Lib (Schema V4, MetadataStore writes) | DS3DriveProvider (callers via coordinator) | Persistence concern lives in DS3Lib |
| Silent auto-on rollout | DS3DriveProvider extension (`+Lifecycle`) | DS3Lib (`inspectThumbnailPrefix`, `SharedData+thumbnailSettings`) | Extension lifecycle owns drive iteration on launch |

**Why this matters:** Phase 13 adds the most extension-side mass of any v3.1 phase. The risk is mis-locating responsibility — e.g., putting the limiter in DS3Lib (it's UI-pacing, not a primitive), or trying to put the BFS hook in DS3Lib (it lives next to the indexer it wraps). The map above is the canonical answer.

## Standard Stack

### Core (verified existing in repo)

| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| Soto v6 (`SotoS3`) | 6.x (declared in `DS3Lib/Package.swift`) | S3 client for `putObject`, `getObject`, `copyObject`, `deleteObject`, `listObjectsV2` | [VERIFIED: existing `DS3Lib/Sources/DS3Lib/DS3S3Client.swift:326-342` already calls `S3.CopyObjectRequest`] |
| ImageIO (`CGImageSource*`) | macOS 14+ system framework | Memory-bounded JPEG render | [VERIFIED: existing `DS3Lib/Sources/DS3Lib/Thumbnails/ThumbnailRenderer.swift:35,52` uses all 4 mandatory flags] |
| SwiftData (`@Model`, `MigrationStage.lightweight`) | macOS 14+ system framework | Schema V4 migration | [VERIFIED: existing `SyncedItem.swift:283,288` shows V1→V2→V3 lightweight pattern] |
| Foundation (`ProcessInfo.thermalState`, `Task.detached`, `Task.checkCancellation()`) | macOS 14+ system framework | Thermal gating, fire-and-forget, cancellation | [CITED: developer.apple.com/documentation/foundation/processinfo/thermalstate-swift.property] |
| FileProvider (`NSFileProviderError`, `fetchThumbnails`) | macOS 14+ system framework | Error domain mapping at boundary | [VERIFIED: CLAUDE.md File Provider Error Handling rule, MEMORY.md "NEVER return custom error types"] |

### No new dependencies in Phase 13

Every API needed is in already-linked frameworks. The only new symbols are project-internal (`copyThumbnail` extension method, `ThumbnailUploader` struct, `ThumbnailFetchLimiter` actor, `Schema V4`).

## Architecture Patterns

### System Architecture Diagram

```
                      ┌─────────────────────────────────────────────────────────┐
                      │  Finder / iOS Files                                     │
                      └──┬───────────────────┬──────────────────────────────┬───┘
                         │ fetchThumbnails   │ createItem / modifyItem      │ deleteItem
                         ▼                   ▼                              ▼
              ┌───────────────────────┐  ┌────────────────────────┐  ┌────────────┐
              │ ThumbnailFetchLimiter │  │ +Create / +Modify      │  │ +Delete    │
              │ (actor, 4 slots/Mac)  │  │ post-PUT hook          │  │ post-del   │
              │     [DS3DriveProv]    │  │  Task.detached {       │  │ Task.det.{ │
              └──────────┬────────────┘  │   ThumbnailUploader    │  │  delete   │
                         │                │   .generateAndUpload  │  │  Thumb-   │
                         ▼                │ }                     │  │  nail()    │
              ┌───────────────────────┐  │                        │  │ }          │
              │ getThumbnailBytes     │  └─────────┬──────────────┘  └────────────┘
              │ on .thumbnails/key.jpg│            │ rename/move:                  
              │  HIT  → return bytes  │            │ Task.detached { copy + del }   
              │  MISS → return nil    │            ▼                                
              │      mark .pending    │  ┌────────────────────────┐                
              └────────────┬──────────┘  │ DS3S3Client            │                
                           │             │ +Thumbnails extension  │                
                  error mapped to        │  putThumbnail          │                
              NSFileProviderError        │  getThumbnailBytes     │                
              (.noSuchItem /             │  deleteThumbnail       │                
               .serverUnreachable /      │  copyThumbnail (NEW)   │                
               .cannotSynchronize)       └──────────┬─────────────┘                
                                                    │                              
              ┌────────────────────────────────────┘                              
              │ S3 (Cubbit DS3 gateway)                                            
              │  <prefix>/key.jpg              <-- original, existing               
              │  <prefix>/.thumbnails/key.jpg  <-- thumbnail, written by 13         
              └─────────────────────────────────────────────────────────────────┐  
                                                                                ▲  
              ┌─────────────────────────────────────────────────────────────┐  │  
              │ BreadthFirstIndexer.runOneBFSPass (every cycle)             │  │  
              │   ↓                                                          │  │  
              │   tail (defer-equivalent point):                             │  │  
              │     if enabled && !paused:                                  │  │  
              │       try? await coordinator.runBatch(maxItems: 5) ─────────┼──┘  
              │         (thermal-gated, pause-aware, 3-strike on failure)   │     
              │     OrphanSweeper.sweep(allPassKeys, enumerated keys)       │     
              │       (cap 50/pass, only when enabled)                      │     
              └──────────────────────┬──────────────────────────────────────┘     
                                     ▼                                            
              ┌────────────────────────────────────────────────────────────┐    
              │ MetadataStore (Schema V4)                                  │    
              │  thumbnailStatus: pending|uploaded|failed|notApplicable    │    
              │  thumbnailFailCount: Int = 0  (NEW in V4)                  │    
              │  fetchPendingThumbnails / setThumbnailStatus / setThumb    │    
              │  Failure (NEW: incr + transition to .failed at >=3)        │    
              └────────────────────────────────────────────────────────────┘    
```

**Trace the primary user flow (upload + later browse):**
1. User drops `photo.heic` in Finder → `createItem` runs.
2. `s3Lib.putS3Item(...)` returns ETag at `+Create.swift:231` (existing).
3. Phase 13 NEW: `Task.detached { thumbnailUploader.generateAndUpload(localURL:, sourceETag:, drive:, originalKey:) }`.
4. `metadataStore.upsertItem(...)` runs (existing, `+Create.swift:236`).
5. Completion handler returns success to Finder — file visible immediately.
6. Inside the detached Task: render → PUT to `<prefix>/.thumbnails/<key>.jpg` → mark `.uploaded`.
7. Later, Finder calls `fetchThumbnails` → through `ThumbnailFetchLimiter` (4 slots) → `getThumbnailBytes` → HIT → return bytes.

### Recommended Project Structure (Phase 13 deltas)

```
DS3Lib/Sources/DS3Lib/
├── Thumbnails/
│   ├── ThumbnailRenderer.swift            # existing (Phase 12)
│   ├── ThumbnailBackfillCoordinator.swift # existing (Phase 12) — EXTENDED
│   └── ThumbnailUploader.swift            # NEW (D-07)
├── DS3S3Client+Thumbnails.swift           # existing (Phase 12) — EXTENDED with copyThumbnail
├── DS3S3ClientProtocol.swift              # existing — EXTENDED with copyThumbnail signature (default impl OK since copyObject already exists)
├── Metadata/
│   └── SyncedItem.swift                   # existing — ADD V4 schema + V3→V4 migration + typealias bump
├── Metadata/MetadataStore+Queries.swift   # existing — predicate already excludes .failed; ADD setThumbnailFailure (incr+transition) helper
├── Constants/DefaultSettings.swift        # existing — ADD Thumbnail.{backfillBatchSize, maxOrphanDeletesPerPass, maxFailStrikes}
└── Utils/S3PathUtils.swift                # existing — ADD isRasterExtension(_:) static (D-08; can wrap DefaultSettings.Thumbnail.rasterExtensions)

DS3DriveProvider/
├── ThumbnailFetchLimiter.swift            # NEW (D-12, D-36)
├── ThumbnailRollout.swift                 # NEW (optional helper, D-01/D-02 — discretion)
├── OrphanSweeper.swift                    # NEW (optional helper, D-25 — discretion, recommended for testability)
├── FileProviderExtension+Thumbnails.swift # rewrite fetchThumbnails (D-11) — DELETE downloadThumbnailImage
├── FileProviderExtension+Create.swift     # add post-PUT Task.detached hook
├── FileProviderExtension+Modify.swift     # add post-PUT (content) hook + rename/move cascade
├── FileProviderExtension+Delete.swift     # add post-delete cascade
├── FileProviderExtension+Lifecycle.swift  # add launch-time silent rollout
└── BreadthFirstIndexer.swift              # add coordinator hook + orphan sweep call at pass tail
```

**File-length watch:**
- `FileProviderExtension+Thumbnails.swift` is 522 lines (per `wc -l`); rewrite removes ~150 lines (`downloadThumbnailImage` and macOS branch's inline path) — should comfortably fit.
- `FileProviderExtension+Modify.swift` is 492 lines; cascade additions (~30 lines) at rename/move sites should fit. If borderline, extract `+ThumbnailCascade.swift`.
- `BreadthFirstIndexer.swift` is 273 lines; tail hook (~10-15 lines) fits.

### Pattern 1: Fire-and-forget `Task.detached` in File Provider handlers

**What:** Decouple a non-user-visible side effect from the user-visible request completion handler.
**When to use:** Upload-time generation (D-06), delete cascade (D-21), rename/move cascade (D-22) — all required by THUMB-06/17/18 to never block the file contract.
**Example (verified pattern from existing code):**
```swift
// Source: Pattern verified in DS3DriveProvider/NotificationsManager.swift (Task { [weak self] in ... })
// and DS3DriveProvider/FileProviderExtension+Create.swift:185 (existing Task { ... })
// Phase 13's wrinkle: Task.detached so we don't inherit MainActor / structured-concurrency parents.

// Inside +Create, after putS3Item succeeds:
let createETag = try await self.withAPIKeyRecovery {
    try await s3Lib.putS3Item(s3Item, fileURL: url, withProgress: uploadProgress)
}

// existing upsertItem etc...

#if os(macOS)
if S3PathUtils.isRasterExtension(filename) {
    let normalizedETag = ETagUtils.normalize(createETag) ?? createETag
    let driveCopy = drive             // capture sendable value
    let s3LibCopy = s3Lib              // capture (s3Lib must be Sendable; it already is)
    let originalKey = key
    let localURL = url
    Task.detached(priority: .background) { [logger = self.logger] in
        do {
            let uploader = ThumbnailUploader(
                s3Client: s3LibCopy.dsClient, // see Note A below on Sendable client
                metadataStore: metadataStore
            )
            try await uploader.generateAndUpload(
                localURL: localURL,
                drive: driveCopy,
                sourceETag: normalizedETag,
                originalKey: originalKey
            )
        } catch {
            logger.error("Thumbnail upload failed for \(originalKey, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}
#endif
// Continue with completionHandler(s3Item, ...) — already isolated.
```

**Note A — Sendable s3 client capture:** `DS3S3Client` is declared `public final class DS3S3Client: Sendable` (verified `DS3S3Client.swift:176`). The protocol `DS3S3ClientProtocol` is `Sendable` (line 5). Capturing it into a `Task.detached { }` is safe under Swift 6 strict concurrency. Capturing `self` (the FileProviderExtension subclass) is unsafe — capture only the specific properties needed (logger, drive, metadataStore, s3Lib) and copy them into locals before the Task.

### Pattern 2: Cache-first consume with explicit error mapping

**What:** Map every leaked error from below the seam to a `NSFileProviderError` before the per-thumbnail completion handler returns.
**When to use:** `fetchThumbnails` rewrite (D-11, D-13).
**Example:**
```swift
// Source: Verified pattern from existing FileProviderExtension+Thumbnails.swift error handling at line 119-141 (fetchContents).
// Phase 13 NEW (replaces old downloadThumbnailImage path):

private func consumeThumbnail(
    for identifier: NSFileProviderItemIdentifier,
    drive: DS3Drive,
    s3Lib: S3Lib,
    perItemHandler: @escaping (NSFileProviderItemIdentifier, Data?, Error?) -> Void
) async {
    // 1. Pre-filter unreachable cases with success-with-nil (so Finder draws default icon, no error).
    if identifier.rawValue.hasSuffix("/") || identifier == .rootContainer {
        perItemHandler(identifier, nil, nil); return
    }
    let filename = String(identifier.rawValue.split(separator: "/").last ?? "")
    guard S3PathUtils.isRasterExtension(filename) else {
        perItemHandler(identifier, nil, nil); return
    }

    let thumbKey = S3PathUtils.thumbnailKey(forOriginalKey: identifier.rawValue, drivePrefix: drive.syncAnchor.prefix)

    do {
        let bytes = try await s3Lib.dsClient.getThumbnailBytes(bucket: drive.syncAnchor.bucket.name, key: thumbKey)
        if let bytes {
            perItemHandler(identifier, bytes, nil)
        } else {
            // 404: mark .pending so BFS picks it up next pass; tell Finder no-such-thumb (it falls back to UTType icon).
            try? await metadataStore?.setThumbnailStatus(s3Key: identifier.rawValue, driveId: drive.id, status: .pending)
            perItemHandler(identifier, nil, NSFileProviderError(.noSuchItem) as NSError)
        }
    } catch {
        // Map below-the-seam errors to the THREE allowed File Provider errors.
        let mapped = mapThumbnailFetchError(error)
        perItemHandler(identifier, nil, mapped)
    }
}

private func mapThumbnailFetchError(_ error: Error) -> NSError {
    // Auth errors → cannotSynchronize (drive enters error state via existing UX).
    if DS3S3Client.isRecoverableAuthError(error) {
        return NSFileProviderError(.cannotSynchronize) as NSError
    }
    // S3 throttling / network → serverUnreachable (Finder retries naturally).
    // Soto 6 throttling shows up as AWSErrorType with errorCode in {"SlowDown", "RequestTimeout", "ServiceUnavailable"} or as URLError.
    if let code = DS3S3Client.s3ErrorCode(from: error),
       ["SlowDown", "RequestTimeout", "ServiceUnavailable", "InternalError"].contains(code) {
        return NSFileProviderError(.serverUnreachable) as NSError
    }
    if let urlErr = error as? URLError {
        switch urlErr.code {
        case .notConnectedToInternet, .timedOut, .networkConnectionLost, .cannotConnectToHost:
            return NSFileProviderError(.serverUnreachable) as NSError
        default: break
        }
    }
    // Unknown → cannotSynchronize (conservative; surfaces sync error UI).
    return NSFileProviderError(.cannotSynchronize) as NSError
}
```

### Pattern 3: Thermal-gated coordinator entry

**What:** Read `ProcessInfo.processInfo.thermalState` once per `runBatch` and bail early on `.serious` / `.critical`.
**When to use:** `ThumbnailBackfillCoordinator.runBatch` top of function (D-19).
**Example:**
```swift
// Source: Apple developer docs (developer.apple.com/documentation/foundation/processinfo/thermalstate-swift.property)
// "Apps running on macOS, iOS, iPadOS, tvOS, and watchOS can read this property at any time."

public func runBatch(maxItems: Int) async throws -> BatchResult {
    #if os(macOS)
    // Single read at function entry — thermal escalation is rare; per-item polling is wasteful.
    let thermal = ProcessInfo.processInfo.thermalState
    if thermal == .serious || thermal == .critical {
        logger.info("Backfill: skipping batch — thermalState=\(String(describing: thermal), privacy: .public)")
        let totalPending = (try? await metadataStore.countPendingRasterThumbnails(driveId: drive.id)) ?? 0
        return BatchResult(processed: 0, succeeded: 0, skipped: 0, failed: 0, totalPending: totalPending)
    }
    // existing batch logic ...
    #else
    return BatchResult(...) // existing iOS placeholder
    #endif
}
```

**Observability note:** The notification name is `Notification.Name.NSProcessInfoThermalStateDidChange` (also written as `ProcessInfo.thermalStateDidChangeNotification`). Phase 13 does NOT need observation — the per-batch read is sufficient given BFS cadence (every `bfsCycleIntervalSeconds`). Defer observation to Phase 14 if/when iOS overnight task wants to react to escalation mid-batch.

### Pattern 4: `Task.checkCancellation()` between phases inside an actor

**What:** Probe cancellation at well-defined boundaries inside `runBatch` so a `Task.cancel()` from outside (or a pause check inside) cleanly aborts.
**When to use:** Between download / render / put / persist phases inside the coordinator (D-20).
**Example:**
```swift
// Source: Verified Swift 6 concurrency semantics — Task cancellation propagates to actor methods if the
// invoking task is cancelled. The actor method runs on the calling task's executor; cancellation flag is per-task.
// Inside an actor method, you must explicitly call try Task.checkCancellation() or check Task.isCancelled.
// Cancellation does NOT throw spontaneously; it only throws on explicit check or via async APIs that throw on it
// (e.g., Task.sleep). Reference: swift.org/documentation/concurrency/

private func processItem(...) async -> Outcome {
    // Phase 1: temp file alloc (no I/O cost; skip cancel check)
    let tempURL = try? temporaryFileURL(...)

    // Phase 2: download original
    do {
        try Task.checkCancellation()
        _ = try await s3Client.getObject(bucket:, key:, toFile: tempURL, onProgress: nil)
    } catch is CancellationError {
        // pause / cancel hit — clean up and exit; don't transition to .failed
        try? FileManager.default.removeItem(at: tempURL)
        return .skipped // or some new "cancelled" outcome that doesn't increment strike count
    } catch {
        return await markFailed(item)
    }

    // Phase 3: render (CPU-bound, doesn't yield; no cancellation point — accept that one render finishes once started)
    guard let data = ThumbnailRenderer().renderJPEG(from: tempURL) else { ... }

    // Phase 4: put
    do {
        try Task.checkCancellation()
        _ = try await s3Client.putThumbnail(bucket:, key:, data: data, sourceETag: sourceETag)
    } catch is CancellationError {
        // pause hit between render and PUT — D-20 says "complete current item's already-started PUT".
        // Since PUT hasn't started yet, exit cleanly; no strike.
        return .skipped
    } catch {
        return await markFailed(item)
    }

    // Phase 5: persist (cheap)
    await transition(item, to: .uploaded)
    return .succeeded
}
```

**Important nuance for D-20:** "complete the current item's already-started PUT" means: if the PUT is in flight, do NOT cancel it. The way to express that is to *not* check cancellation between when `putThumbnail` is invoked and when it returns — you check BEFORE invoking it. After it returns, persist the status before exiting. The above sketch matches that contract.

**Pause-vs-cancellation distinction:** D-20 talks about pause. The cleanest implementation is to call `coordinator.cancelInFlightBatch()` from the BFS hook when `isDrivePaused` flips to true, which sets an actor-internal `currentTask?.cancel()`. Inside `runBatch`, the existing `try Task.checkCancellation()` calls catch it. Cancel + pause use the same primitive.

### Pattern 5: Schema V3→V4 lightweight migration

**What:** Add an Int field with a default value, preserve existing rows.
**When to use:** D-29 — add `thumbnailFailCount: Int = 0` to V4.SyncedItem.
**Example (mirrors V2→V3 pattern verified at `SyncedItem.swift:288-291`):**
```swift
// Source: Verified existing pattern in DS3Lib/Sources/DS3Lib/Metadata/SyncedItem.swift:283 (V1→V2) and :288 (V2→V3).
// SwiftData lightweight migrations handle additive fields with defaults automatically.

// 1. Add V4 schema definition (mirror V3 verbatim, add one field):
public enum SyncedItemSchemaV4: VersionedSchema {
    public nonisolated static let versionIdentifier = Schema.Version(4, 0, 0)
    // CRITICAL: nonisolated static let — Schema.Version is not Sendable; without this CI Xcode 16.2 fails
    // even when local Xcode passes. (Per MEMORY.md.)

    public static var models: [any PersistentModel.Type] {
        [SyncedItem.self, SyncAnchorRecord.self]
    }

    // Reuse V2's SyncAnchorRecord typealias to avoid the SwiftData "failed to cast model" trap
    // (verified in V3 at line 195).
    public typealias SyncAnchorRecord = SyncedItemSchemaV2.SyncAnchorRecord

    @Model
    public final class SyncedItem {
        // ... all V3 fields verbatim ...
        public var thumbnailStatus: String = ThumbnailStatus.pending.rawValue
        @Transient public var thumbnail: ThumbnailStatus { ... }

        // NEW in V4:
        public var thumbnailFailCount: Int = 0

        public init(...) {
            // existing fields
            self.thumbnailFailCount = 0
        }
    }
}

// 2. Add migration stage:
public enum SyncedItemMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] {
        [SyncedItemSchemaV1.self, SyncedItemSchemaV2.self, SyncedItemSchemaV3.self, SyncedItemSchemaV4.self]
    }

    public static var stages: [MigrationStage] {
        [migrateV1toV2, migrateV2toV3, migrateV3toV4]
    }

    nonisolated static let migrateV3toV4 = MigrationStage.lightweight(
        fromVersion: SyncedItemSchemaV3.self,
        toVersion: SyncedItemSchemaV4.self
    )
}

// 3. Bump typealias at bottom of file:
public typealias SyncedItem = SyncedItemSchemaV4.SyncedItem

// 4. Update MetadataStore.swift:16 — Schema(versionedSchema: SyncedItemSchemaV4.self).
```

**Migration test recipe (mirrors `SchemaV3MigrationTests` per Phase 12 D-36):**
```swift
func testV3ToV4LightweightMigrationPreservesRowsAndDefaultsFailCount() async throws {
    // 1. Build a V3 store with seeded SyncedItem rows of varied thumbnailStatus.
    // 2. Close container.
    // 3. Re-open with V4 schema + migration plan.
    // 4. Assert: count matches; every row has thumbnailFailCount == 0; all other fields preserved (especially thumbnailStatus).
}
```

### Pattern 6: `copyThumbnail` via existing `copyObject`

**What:** Server-side S3 copy preserving metadata.
**When to use:** D-22 rename/move cascade.
**Example:**
```swift
// Source: VERIFIED — DS3S3Client.copyObject already exists at DS3S3Client.swift:326-342 with correct
// metadataDirective semantics. When metadata is nil, the request is built with metadataDirective: nil,
// which Soto serializes as omitting the header — and per AWS S3 API spec, the default is COPY (preserve
// source metadata). Reference: docs.aws.amazon.com/AmazonS3/latest/API/API_CopyObject.html — "If the
// metadataDirective header isn't specified, COPY is the default behavior."

// In DS3S3Client+Thumbnails.swift, ADD:
public extension DS3S3ClientProtocol {
    /// Server-side copy of a thumbnail. Preserves source metadata (x-amz-meta-source-etag,
    /// x-amz-meta-ds3drive-thumb-version) by passing nil — Soto omits the metadataDirective header,
    /// AWS defaults to COPY.
    func copyThumbnail(
        bucket: String,
        fromKey: String,
        toKey: String
    ) async throws {
        try await copyObject(
            bucket: bucket,
            sourceKey: fromKey,
            destinationKey: toKey,
            metadata: nil  // -> metadataDirective: nil -> S3 default COPY
        )
    }
}

// And add to the protocol:
// (No change needed if copyThumbnail is on the protocol-extension itself — it's not in the
// protocol's required methods because it's expressible via copyObject which IS in the protocol.)
```

**Edge cases / error mapping for `copyThumbnail`:**
- Source thumbnail doesn't exist (`NoSuchKey`): use `DS3S3Client.isNotFoundError(error)` (existing helper at `DS3S3Client.swift:379`). Treat as "no thumbnail to migrate" — fall through to D-22's "mark new key `.pending`" path.
- 5xx / SlowDown: throw — D-22 catch block maps to `.pending`.
- Single-part guarantee: server-side copy is a single S3 operation by definition. No multipart concerns. Soto's `copyObject` always uses a single CopyObject API call (it does NOT auto-promote to UploadPartCopy for objects > 5GB; that limit is irrelevant here since thumbnails are < 500KB).

### Anti-Patterns to Avoid

- **Don't return non-nil errors with non-nil data:** `perThumbnailCompletionHandler(id, data, error)` — system behavior is undefined. D-13 says: HIT → `(id, bytes, nil)`; MISS → `(id, nil, .noSuchItem)`; transient → `(id, nil, .serverUnreachable)`.
- **Don't capture `self` in `Task.detached`** when `self` is the FileProviderExtension subclass — capture sendable values into locals first. Existing pattern at `+Create.swift:185` (`Task { ... }`) inherits `self`'s isolation domain, which is acceptable for that case but NOT for fire-and-forget detached Tasks (which we need for upload-hook decoupling).
- **Don't put the limiter in DS3Lib:** D-36 — UI-pacing is an extension concern. Phase 12's `BucketListingLimiter` actor at `DS3DriveProvider/BucketListingLimiter.swift` is the precedent.
- **Don't read `thermalState` per item:** O(N) waste; the value rarely changes within a 5-item batch. Read once per `runBatch`.
- **Don't return custom error domains:** Renderer/Soto errors map to one of the three allowed `NSFileProviderError` codes or `NSCocoaErrorDomain`. CLAUDE.md "File Provider Error Handling" + MEMORY.md.
- **Don't HEAD before copy:** Phase 12 D-15 / Phase 13 D-28 — orphan sweep uses BFS-enumerated set; HEAD has no consumer.
- **Don't run the BFS hook synchronously inside the BFS pass:** D-17 says fire-and-forget at the BFS layer (let coordinator run AFTER pass scheduler arms next pass). Otherwise pass duration becomes coordinator-bound.
- **Don't try to "cancel mid-PUT":** D-20 requires completing in-flight PUTs to avoid corruption. Check cancellation BEFORE the PUT, not during.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| S3 server-side copy | A custom GET+PUT pair | `DS3S3Client.copyObject` (already exists) → wrap as `copyThumbnail` | Server-side copy is single-API-call, transfers no bytes through client; preserves metadata via `metadataDirective: nil` default |
| Concurrency limiting | Counter + lock | Actor with semaphore (mirror `BucketListingLimiter` at `DS3DriveProvider/BucketListingLimiter.swift`) | Existing project precedent; actor isolation gives Swift 6 strict-concurrency safety free |
| Thermal monitoring | `IOPMSystemPowerStateNotify` / mach calls | `ProcessInfo.processInfo.thermalState` | Apple-blessed, no entitlements needed, available since macOS 10.10.3 |
| Cancellation propagation | Manual `isCancelled: Bool` flags | `Task.checkCancellation()` + `Task.cancel()` | Built into Swift Concurrency; structured cancellation propagates through `await` boundaries |
| Schema migration | Custom `MigrationPlan` with code | `MigrationStage.lightweight(fromVersion:toVersion:)` | Lightweight is sufficient for additive Int field with default; same pattern used in V1→V2 and V2→V3 |
| Orphan detection | Per-thumbnail HEAD requests | Set difference: `enumerated thumbnail keys - allPassKeys` | BFS already builds `allPassKeys: Set<String>` (verified `BreadthFirstIndexer.swift:94,126`); HEAD per item would be 1000s of round-trips |
| Strike count timing | Date-based cooldown table | Counter + ETag-change reset | D-32 — BFS cadence IS the backoff; simplest correct design |
| Error domain mapping | Per-call-site translation | Single `mapThumbnailFetchError(_ error: Error) -> NSError` helper | One choke point, testable, matches CLAUDE.md mandatory contract |

**Key insight:** Phase 12 already shipped most of the heavy lifting. Phase 13 is mostly "add 5-15 lines at N integration points" plus three new types (`ThumbnailUploader`, `ThumbnailFetchLimiter`, optional `OrphanSweeper`). Resist the urge to refactor anything Phase 12 already did — the verification report (`12-VERIFICATION.md`) shows 500 tests green, including the migration scaffolding.

## Common Pitfalls

### Pitfall 1: `Task.detached { }` capturing `self` makes the FileProviderExtension subclass non-Sendable

**What goes wrong:** `Task.detached { try? await self.thumbnailUploader.generateAndUpload(...) }` — Swift 6 strict concurrency complains because `FileProviderExtension` (the subclass) inherits from `NSObject`, which is not declared `Sendable`. CI Xcode 16.2 enforces this even when local Xcode passes.
**Why it happens:** `Task.detached` opens a fresh isolation domain; whatever it captures must cross actors. `self` doesn't qualify.
**How to avoid:** Capture only the specific values needed into locals before the Task. The pattern at `Pattern 1` above shows this. `s3Lib`, `drive`, `metadataStore`, `originalKey`, `localURL`, and `logger` are all Sendable; `self` is not.
**Warning signs:** "Capture of 'self' with non-sendable type 'FileProviderExtension' in a `@Sendable` closure" CI error.

### Pitfall 2: SwiftData V4 schema `Schema.Version` not Sendable trap

**What goes wrong:** `public static let versionIdentifier = Schema.Version(4, 0, 0)` — without `nonisolated`, CI Xcode 16.2 fails with "Static property 'versionIdentifier' is not concurrency-safe because non-'Sendable' type 'Schema.Version' may have shared mutable state". Local Xcode 16.x may pass.
**Why it happens:** `Schema.Version` is a struct, but in newer Xcode SDKs it's not annotated `Sendable`.
**How to avoid:** Always use `public nonisolated static let versionIdentifier = Schema.Version(...)` exactly as V1, V2, V3 do (verified `SyncedItem.swift:7,65,187`). Per MEMORY.md.
**Warning signs:** Local build green, CI red on the V4 schema declaration line.

### Pitfall 3: `fetchPendingThumbnails` after Schema V4 still works, but tests must seed the new field

**What goes wrong:** Phase 13 doesn't change the `.pending` predicate (D-30), but every test that constructs a V4 SyncedItem manually must seed `thumbnailFailCount` (or rely on the `= 0` default).
**Why it happens:** Existing query tests in `MetadataStoreThumbnailQueriesTests.swift` (Phase 12) construct V3 SyncedItem objects. Phase 13's bump propagates to V4 — tests must compile.
**How to avoid:** The default `Int = 0` makes existing tests compile unchanged. New tests for the 3-strike rule explicitly construct items with `thumbnailFailCount: 2` and assert that an additional failure transitions to `.failed`.

### Pitfall 4: `ThumbnailFetchLimiter` deadlock if upload-path passes through it

**What goes wrong:** D-12 explicitly says upload-path bypasses the limiter. If you accidentally route the upload-hook's PUT through it, you can deadlock when 4 user-initiated `fetchThumbnails` calls hold all 4 slots and the upload hook is waiting for one — creating no-progress.
**Why it happens:** Architectural drift if the uploader and the consume-path code both go through a shared "thumbnail rate gate" type.
**How to avoid:** D-12 + D-36: limiter is an extension-side actor wrapping `fetchThumbnails` ONLY. `ThumbnailUploader` and `ThumbnailBackfillCoordinator` do NOT take a limiter in their init. Three lanes, no shared gate.
**Warning signs:** Hangs in Finder during heavy upload activity; thumbnails stop appearing.

### Pitfall 5: Rename/move cascade race if BFS upserts old key as still-existing

**What goes wrong:** Rename: `+Modify` deletes old original, creates new original. Cascade `Task.detached` is fire-and-forget. If BFS pass runs between the rename and the cascade Task, BFS might still see the old key (if S3 read-after-rename is eventually consistent) and upsert it — orphan sweep then deletes the just-copied new thumbnail because old original "still exists in BFS set".
**Why it happens:** BFS-enumerated set isn't a transactional snapshot.
**How to avoid:** D-25 sweep operates on the BFS-enumerated key set BUILT DURING THE PASS THAT JUST COMPLETED — by the time the sweep runs, the rename has long since landed in the next listObjectsV2 result. Cubbit DS3 is strongly consistent for reads-after-writes (per Cubbit composer-cli docs). Additionally, D-22's fallback (mark new key `.pending` on copy failure) backstops the case where the rename and copy are out of order.
**Warning signs:** Thumbnails disappear shortly after rename and reappear after one BFS pass (regenerated from new original).

### Pitfall 6: `copyObject` percent-encoding the `copySource`

**What goes wrong:** `copySource: "\(bucket)/\(sourceKey)"` — if `sourceKey` contains `+`, `%`, `/`, or non-ASCII chars, Soto rejects or constructs an invalid URL.
**Why it happens:** S3 expects `x-amz-copy-source: bucket/url-encoded-key`.
**How to avoid:** VERIFIED — `DS3S3Client.copyObject` at `DS3S3Client.swift:329` already does `addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)` and throws `DS3ClientError.parseError` on failure. Phase 13's `copyThumbnail` inherits this safety automatically.

### Pitfall 7: `Task.checkCancellation()` doesn't fire from inside a still-running `await` on `getObject`

**What goes wrong:** Pause flips to true while a 100MB original is downloading. `Task.cancel()` propagates the cancellation flag to the actor, but `s3.getObject(...)` doesn't observe it until it next yields — which for a single-shot streaming read could be after the whole download.
**Why it happens:** Soto's `getObject(toFile:)` is a single `await` that may not internally check cancellation.
**How to avoid:** D-20 accepts this — "complete the current item's already-started PUT" implicitly covers the downstream phases. For a paused-mid-batch scenario, the worst case is one full item completes before the pause takes effect on the NEXT item. The acceptable behavior is documented in D-20.
**Warning signs:** Pause appears non-immediate during a backfill of large originals; this is by design.

### Pitfall 8: Renderer memory spike on macOS extension under concurrent uploads

**What goes wrong:** User drops 200 photos at once. `+Create` fires 200 `Task.detached` Tasks, each rendering a 50MB HEIC. Even on macOS without a hard jetsam budget, peak memory could exceed extension limits and trigger OS termination.
**Why it happens:** Fire-and-forget without rate limiting on the upload lane.
**How to avoid:** D-12 explicitly allows the upload lane to be unbounded — "rate-limited naturally by upload rate". The actual upload PUT is the natural gate (Cubbit DS3 has request limits + Soto has connection pooling). However, if drop-batch sizes are extreme, future Phase 14+ tuning could add a `ThumbnailUploadLimiter` actor. Phase 13 ships unbounded as decided.
**Warning signs:** Extension OOM kill on huge batched uploads; mitigated by Phase 11's `os_proc_available_memory()` guard inside `ThumbnailRenderer` returning nil on low-mem (verified `ThumbnailRenderer.swift:27`).

### Pitfall 9: `ThumbnailUploader` capturing `MetadataStore` (a `@ModelActor`) from a `Task.detached`

**What goes wrong:** `MetadataStore` is `@ModelActor` (existing pattern). Passing it into a `Task.detached` is fine — actor references are Sendable. But calling `await metadataStore.setThumbnailStatus(...)` from inside the detached Task crosses two isolation domains (detached → actor), which is correct but slightly noisy in logs if MetadataStore's queue is busy.
**Why it happens:** Normal Swift concurrency; not actually a bug.
**How to avoid:** Just be aware that the upload Task may serialize behind other MetadataStore work. Phase 13 doesn't add a new mitigation — the existing batchUpsertItems / setSyncStatus pattern already lives with this.

### Pitfall 10: `DefaultSettings.Thumbnail.maxFailStrikes` interpreted off-by-one

**What goes wrong:** Is `3` the count to stop at (`if count >= 3`) or the count after which to stop (`if count > 3`)? Different parts of the code disagree.
**Why it happens:** Natural language ambiguity around "after 3 failures".
**How to avoid:** D-29 says "3 strikes → `.failed`". Implementation: increment count; if `count >= maxFailStrikes` (i.e., `count >= 3`), transition to `.failed`. So three failures total before terminal. Document this in the helper signature: `setThumbnailFailure(s3Key:driveId:) -> ThumbnailStatus` (returns the resulting status — `.pending` if count < 3, `.failed` if >= 3). Test with seeded counts of 0, 1, 2: third failure (count becoming 3) flips to `.failed`.
**Warning signs:** Tests pass on count seed 2 but fail on count seed 3, or vice versa — usually one count off.

### Pitfall 11 (Phase 13-relevant from milestone PITFALLS.md): EXIF orientation regression

**What:** Already mitigated by Phase 11's `kCGImageSourceCreateThumbnailWithTransform: true` (verified `ThumbnailRenderer.swift:81`). Phase 13 inherits this — no new risk introduced.

### Pitfall 12 (Phase 13-relevant): SwiftLint file length limit on `+Modify.swift` after cascade addition

**What:** `+Modify.swift` is 492 lines; cascade additions at rename/move sites (~30 lines) approach SwiftLint default 500-line limit.
**How to avoid:** If lint fails, extract `FileProviderExtension+ThumbnailCascade.swift` containing private helpers `enqueueRenameCascade(...)`, `enqueueMoveCascade(...)`. The `+Modify.swift` rename/move handlers each call one helper (single line each).

## Code Examples

### Example 1: `ThumbnailUploader` complete signature and body

```swift
// File: DS3Lib/Sources/DS3Lib/Thumbnails/ThumbnailUploader.swift
// Source: D-07 verbatim. Renders + PUTs; sets MetadataStore status.

import Foundation
import os.log

public struct ThumbnailUploader: Sendable {
    private let s3Client: any DS3S3ClientProtocol
    private let metadataStore: MetadataStore
    private let logger = Logger(
        subsystem: LogSubsystem.app,
        category: LogCategory.thumbnail.rawValue
    )

    public init(s3Client: any DS3S3ClientProtocol, metadataStore: MetadataStore) {
        self.s3Client = s3Client
        self.metadataStore = metadataStore
    }

    #if os(macOS)
    /// Renders + PUTs the thumbnail. On render failure, marks SyncedItem .failed
    /// (or .notApplicable if format isn't in the raster allow-list).
    /// Re-renders unconditionally on every invocation (D-10).
    public func generateAndUpload(
        localURL: URL,
        drive: DS3Drive,
        sourceETag: String,
        originalKey: String
    ) async throws {
        // Pre-filter (defensive — caller should already have checked S3PathUtils.isRasterExtension).
        guard S3PathUtils.isRasterExtension((originalKey as NSString).pathExtension) else {
            try? await metadataStore.setThumbnailStatus(
                s3Key: originalKey, driveId: drive.id, status: .notApplicable
            )
            return
        }

        // Render. Renderer returns nil on memory pressure / format reject / decode fail.
        guard let data = ThumbnailRenderer().renderJPEG(from: localURL) else {
            logger.info("Uploader: render returned nil for \(originalKey, privacy: .public) — incrementing fail count")
            try? await metadataStore.setThumbnailFailure(s3Key: originalKey, driveId: drive.id)
            return
        }

        // PUT to .thumbnails/<key>.jpg.
        let bucket = drive.syncAnchor.bucket.name
        let drivePrefix = drive.syncAnchor.prefix
        let thumbKey = S3PathUtils.thumbnailKey(forOriginalKey: originalKey, drivePrefix: drivePrefix)

        do {
            _ = try await s3Client.putThumbnail(
                bucket: bucket,
                key: thumbKey,
                data: data,
                sourceETag: sourceETag
            )
        } catch {
            logger.error("Uploader: PUT failed for \(thumbKey, privacy: .public): \(error.localizedDescription, privacy: .public)")
            try? await metadataStore.setThumbnailFailure(s3Key: originalKey, driveId: drive.id)
            throw error
        }

        try? await metadataStore.setThumbnailStatus(
            s3Key: originalKey, driveId: drive.id, status: .uploaded
        )
    }
    #endif
}
```

### Example 2: `MetadataStore.setThumbnailFailure` (3-strike helper)

```swift
// File: DS3Lib/Sources/DS3Lib/Metadata/MetadataStore+Queries.swift (extend existing)
// Source: D-29 + D-30 + D-31. Encapsulates the strike count + transition logic so callers don't have to.

public extension MetadataStore {
    /// Increments thumbnailFailCount; transitions thumbnailStatus to .failed if count >= maxFailStrikes.
    /// Returns the new ThumbnailStatus (caller can log/route on it). No-op if item not found.
    @discardableResult
    func setThumbnailFailure(s3Key: String, driveId: UUID) throws -> ThumbnailStatus {
        guard let item = try findItem(byKey: s3Key, driveId: driveId) else {
            return .failed // best-effort on missing row
        }
        item.thumbnailFailCount += 1
        let newStatus: ThumbnailStatus = item.thumbnailFailCount >= DefaultSettings.Thumbnail.maxFailStrikes
            ? .failed
            : .pending
        item.thumbnailStatus = newStatus.rawValue
        try modelExecutor.modelContext.save()
        return newStatus
    }
}
```

### Example 3: Reset on ETag change (D-31)

```swift
// File: DS3Lib/Sources/DS3Lib/Metadata/MetadataStore.swift — modify upsertItem (or batchUpsertItems body).
// Source: D-31 — when the persisted ETag differs from the freshly-listed ETag, reset thumbnail state.

// Inside MetadataStore.upsertItem (or its batched cousin), after merging fields:
if let existing = ... {
    let oldETag = existing.etag
    existing.etag = newETag
    // ... other field merges ...

    // Phase 13 D-31: ETag change re-arms thumbnail.
    if let oldETag, let newETag, oldETag != newETag {
        existing.thumbnailFailCount = 0
        existing.thumbnailStatus = ThumbnailStatus.pending.rawValue
    }
}
```

### Example 4: `ThumbnailFetchLimiter` actor (DS3DriveProvider)

```swift
// File: DS3DriveProvider/ThumbnailFetchLimiter.swift
// Source: D-12, D-36. Mirror of DS3DriveProvider/BucketListingLimiter.swift.

import Foundation

actor ThumbnailFetchLimiter {
    private let maxSlots: Int
    private var inFlight = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(maxSlots: Int = 4) { // macOS=4 per THUMB-14
        self.maxSlots = maxSlots
    }

    func acquire() async {
        if inFlight < maxSlots {
            inFlight += 1
            return
        }
        await withCheckedContinuation { cont in
            waiters.append(cont)
        }
        inFlight += 1
    }

    func release() {
        inFlight -= 1
        if !waiters.isEmpty {
            let next = waiters.removeFirst()
            next.resume()
        }
    }
}

// Usage inside fetchThumbnails (per-item loop):
//   await limiter.acquire()
//   defer { Task { await limiter.release() } }
//   await consumeThumbnail(for: identifier, drive: drive, s3Lib: s3Lib, perItemHandler: perThumbnailCompletionHandler)
```

### Example 5: BFS hook with thermal + pause + orphan sweep

```swift
// File: DS3DriveProvider/BreadthFirstIndexer.swift — at the tail of runOneBFSPass.
// Source: D-17, D-19, D-20, D-25.

// Existing tail (line ~191 area):
if !Task.isCancelled {
    await synthesizeVirtualFoldersFromKeys(allPassKeys)
}

// Phase 13 ADD AFTER synthesize:
if !Task.isCancelled,
   let metadataStore = self.metadataStore,
   (try? await isThumbnailEnabled(for: drive)) == true,
   (try? SharedData.default().isDrivePaused(drive.id)) != true {

    // Coordinator hook — fire-and-forget so BFS pass scheduler arms next pass immediately.
    let coordinator = thumbnailCoordinator(metadataStore: metadataStore)
    Task.detached { [logger, drive] in
        do {
            let result = try await coordinator.runBatch(
                maxItems: DefaultSettings.Thumbnail.backfillBatchSize
            )
            logger.debug("BFS thumbnail batch: \(result.processed) processed, \(result.totalPending) pending")
        } catch {
            logger.error("BFS thumbnail batch failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // Orphan sweep — also fire-and-forget; uses the keys we just collected.
    let keysSnapshot = allPassKeys // Set<String> is Sendable
    Task.detached { [s3Lib, drive, logger] in
        do {
            let sweeper = OrphanSweeper(s3Lib: s3Lib, drive: drive)
            let removed = try await sweeper.sweep(
                enumeratedOriginalKeys: keysSnapshot,
                cap: DefaultSettings.Thumbnail.maxOrphanDeletesPerPass
            )
            if removed > 0 {
                logger.info("Orphan sweep removed \(removed) thumbnails")
            }
        } catch {
            logger.error("Orphan sweep failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
```

## Runtime State Inventory

| Category | Items Found | Action Required |
|----------|-------------|------------------|
| Stored data | **Schema V3 metadata DB** (existing per-drive SyncedItem rows in App Group container `~/Library/Group Containers/group.X889956QSM.io.cubbit.DS3Drive/SyncedItems.store`) — V3→V4 lightweight migration runs automatically on first launch with new build | Lightweight SwiftData migration; no manual data migration. New `thumbnailFailCount = 0` defaulted on every existing row. **Test:** mirror Phase 12 D-36 V2→V3 test seeded with V3 store containing varied `thumbnailStatus` rows. |
| Stored data | **`SharedData/thumbnail-settings.json`** — exists per Phase 12 D-23. Default `enabled = false` for all drives | Phase 13 launch path FLIPS this to `true` for eligible drives via D-01 silent rollout. Kill-switch: user edits JSON manually (D-05) |
| Stored data | **`.thumbnails/` S3 prefix in user buckets** — may contain Phase 12 test artifacts or external-tool content. Phase 11's `inspectThumbnailPrefix` discriminates | D-02 once-per-drive re-check at first v3.1 launch. `.conflicting` drives stay disabled silently |
| Live service config | **None** — DS3 Drive does not depend on any live external service config (no n8n, no Datadog, no Tailscale ACLs, no Cloudflare tunnel) | None |
| OS-registered state | **File Provider extension domain** (`io.cubbit.DS3Drive.provider`) registered with `fileproviderd` — exists since Phase 1; Phase 13 doesn't touch domain registration | None — Phase 13 is purely behavioral changes inside the existing extension. Existing `killall fileproviderd` recovery sequence (CLAUDE.md) still applies for build-time issues, NOT for runtime data migration |
| OS-registered state | **`NSFileProviderItemDecorating` badges** (Phase 5) — already render on top of OS-supplied thumbnails | D-15 — no change. Verify post-implementation that cloud/synced/syncing/error badges still display correctly on thumbnails (success criterion #2 verification) |
| Secrets/env vars | **Cubbit IAM tokens, S3 credentials** — managed by existing `DS3Authentication` / `SharedData` flow | None — Phase 13 doesn't introduce new secrets, doesn't rename existing ones |
| Build artifacts | **Stale `~/Library/Developer/Xcode/DerivedData/DS3Drive-*` builds** — affect extension cache per CLAUDE.md "Extension Won't Load" recovery sequence | None for Phase 13 specifically; standard rebuild + clean build recovery applies if extension fails to load mid-development |

**Nothing found in category:** Live service config — verified by checking PROJECT.md no-custom-backend constraint and grepping for external service references.

## Validation Architecture

### Test Framework

| Property | Value |
|----------|-------|
| Framework | Swift Testing (`@Test`) + XCTest legacy (`final class XCTestCase`) — both used in DS3LibTests; DS3DriveProviderTests is XCTest only |
| Config file | `DS3Lib/Package.swift` (test targets); macOS scheme uses XCTest runner. iOS scheme can also run DS3LibTests on simulator |
| Quick run command | `swift test --package-path DS3Lib --filter "ThumbnailUploaderTests"` (single target tests) |
| Full suite command | `swift test --package-path DS3Lib && xcodebuild test -scheme DS3Drive -destination 'platform=macOS'` |

### Phase Requirements → Test Map

| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| THUMB-06 | Upload-hook fires post-PUT, marks `.uploaded`, never blocks createItem | unit | `swift test --filter ThumbnailUploaderTests` | ❌ Wave 0 |
| THUMB-06 | `S3PathUtils.isRasterExtension` rejects PDF/MP4 | unit | `swift test --filter S3PathUtilsTests/testIsRasterExtension` | ❌ Wave 0 |
| THUMB-06 | Modify cascade re-renders unconditionally | unit | `swift test --filter ThumbnailUploaderTests/testReRenderOnModify` | ❌ Wave 0 |
| THUMB-11/12/13 | `fetchThumbnails` HIT returns bytes; MISS returns `.noSuchItem` + marks `.pending`; transient → `.serverUnreachable` | unit (mock S3) | `xcodebuild test -only-testing DS3DriveProviderTests/FetchThumbnailsConsumeTests` | ❌ Wave 0 |
| THUMB-14 | Limiter caps in-flight to 4 on macOS | unit | `xcodebuild test -only-testing DS3DriveProviderTests/ThumbnailFetchLimiterTests` | ❌ Wave 0 |
| THUMB-15 | BFS pass tail invokes coordinator with `enabled && !paused` | integration | `xcodebuild test -only-testing DS3DriveProviderTests/BFSThumbnailHookTests` | ❌ Wave 0 |
| THUMB-17 | Delete cascade fires `deleteThumbnail` after successful original delete | unit (mock S3) | `xcodebuild test -only-testing DS3DriveProviderTests/DeleteThumbnailCascadeTests` | ❌ Wave 0 |
| THUMB-18 | Rename cascade calls `copyThumbnail(old → new)` then `deleteThumbnail(old)` | unit (mock S3) | `xcodebuild test -only-testing DS3DriveProviderTests/RenameThumbnailCascadeTests` | ❌ Wave 0 |
| THUMB-18 | Rename cascade marks new key `.pending` on copy failure | unit | same target | ❌ Wave 0 |
| THUMB-19 | Orphan sweep deletes thumbnails not in BFS-enumerated set, capped at 50/pass | unit | `xcodebuild test -only-testing DS3DriveProviderTests/OrphanSweeperTests` | ❌ Wave 0 |
| THUMB-19 | Orphan sweep gated by `enabled == true` | unit | same target | ❌ Wave 0 |
| THUMB-20 | 3 strikes transitions `.pending → .failed` | unit | `swift test --filter MetadataStoreThumbnailFailureTests` | ❌ Wave 0 |
| THUMB-20 | ETag change resets `thumbnailFailCount = 0, thumbnailStatus = .pending` | unit | same target | ❌ Wave 0 |
| THUMB-20 | Schema V4 migration preserves rows + defaults `thumbnailFailCount = 0` | unit | `swift test --filter SchemaV4MigrationTests` | ❌ Wave 0 |
| THUMB-21 | Coordinator skips on `isDrivePaused == true` at entry | unit | `swift test --filter ThumbnailBackfillCoordinatorTests/testPauseGate` | ✅ partial (existing scaffold tests need extension) |
| THUMB-21 | Coordinator skips on `thermalState == .serious` | unit | `swift test --filter ThumbnailBackfillCoordinatorTests/testThermalGate` | ❌ Wave 0 |
| THUMB-23 | No call sites perform full-bucket scan on launch | grep test (CI) | `grep -r "listObjectsV2.*MaxKeys: 1000" DS3DriveProvider/` should return only `OrphanSweeper.swift` (BFS-tied) | ❌ Wave 0 |

### Sampling Rate

- **Per task commit:** `swift test --package-path DS3Lib` (DS3Lib unit tests, ~30s) + `xcodebuild test -scheme DS3Drive -destination 'platform=macOS' -only-testing DS3DriveProviderTests` for the touched DS3DriveProvider test files
- **Per wave merge:** Full DS3Lib test suite + full macOS Xcode test scheme + iOS scheme build (compile-only, since iOS doesn't run thumbnail tests)
- **Phase gate:** Both `swift test` and `xcodebuild test` green; both schemes (`DS3Drive` macOS, `DS3DriveApp` iOS) build clean; full suite count baseline = Phase 12's 500 tests + new Phase 13 tests, expect ~530-550 green

### Wave 0 Gaps

- [ ] `DS3Lib/Tests/DS3LibTests/ThumbnailUploaderTests.swift` — covers THUMB-06 (raster filter, render-fail → `.failed` strike, PUT-fail → `.failed` strike, success → `.uploaded`)
- [ ] `DS3Lib/Tests/DS3LibTests/SchemaV4MigrationTests.swift` — covers THUMB-20 migration (mirror `SchemaV3MigrationTests`)
- [ ] `DS3Lib/Tests/DS3LibTests/MetadataStoreThumbnailFailureTests.swift` — covers `setThumbnailFailure` strike count behavior + ETag-change reset on upsert
- [ ] `DS3Lib/Tests/DS3LibTests/S3PathUtilsRasterExtensionTests.swift` — covers `isRasterExtension` allow-list (likely added to existing `S3PathUtilsTests.swift`)
- [ ] `DS3Lib/Tests/DS3LibTests/DS3S3ClientCopyThumbnailTests.swift` — covers `copyThumbnail` happy path + 404 source + 5xx (likely added to existing `DS3S3ClientThumbnailsTests.swift`)
- [ ] `DS3DriveProviderTests/ThumbnailFetchLimiterTests.swift` — covers slot capping under contention
- [ ] `DS3DriveProviderTests/FetchThumbnailsConsumeTests.swift` — covers cache-first happy/miss/error mapping
- [ ] `DS3DriveProviderTests/DeleteThumbnailCascadeTests.swift` — covers fire-and-forget invocation after successful delete
- [ ] `DS3DriveProviderTests/RenameThumbnailCascadeTests.swift` — covers `copyThumbnail` + `deleteThumbnail` ordering, copy-failure → mark `.pending` fallback
- [ ] `DS3DriveProviderTests/OrphanSweeperTests.swift` — covers set-difference logic + cap-at-50
- [ ] `DS3DriveProviderTests/BFSThumbnailHookTests.swift` — integration smoke test (mock indexer + mock coordinator) verifying hook fires on pass tail when `enabled && !paused`
- [ ] Extend `DS3LibTests/ThumbnailBackfillCoordinatorTests.swift` — add thermal-gate test (mock `ProcessInfo`-injectable shim or split the gate into a Sendable `() -> ProcessInfo.ThermalState` closure to allow injection)
- [ ] Extend `DS3LibTests/ThumbnailBackfillCoordinatorTests.swift` — add pause-gate test + cancellation test (cancel mid-batch, verify `.failed` count NOT incremented for skipped items)

**Existing test infrastructure that survives unchanged:**
- `DS3LibTests/SharedDataThumbnailSettingsTests.swift` (12 tests, Phase 12) — all should still pass; only writers change (extension lifecycle starts writing `enabled: true` in Phase 13)
- `DS3LibTests/DS3S3ClientThumbnailsTests.swift` (9 tests, Phase 12) — all should still pass; new tests added for `copyThumbnail`
- `DS3LibTests/MetadataStoreThumbnailQueriesTests.swift` (7 tests, Phase 12) — should still pass; predicate unchanged

### Testable Invariants (Nyquist Dimension 8)

These invariants are listed as the "what must remain true" contract that test cases enforce:

1. **Every PUT thumbnail carries `x-amz-meta-source-etag`** — `ThumbnailUploaderTests.testPutCarriesSourceETag` inspects the captured request metadata via mocked client.
2. **Every PUT thumbnail carries `x-amz-meta-ds3drive-thumb-version: 1`** — same test.
3. **Every consume-path error stays in `NSFileProviderErrorDomain`** — `FetchThumbnailsConsumeTests.testErrorMappingExhaustive` parameterized over Soto error codes + URLError codes; assert `(error as NSError).domain == NSFileProviderErrorDomain || .domain == NSCocoaErrorDomain`.
4. **Schema V4 migration preserves `thumbnailStatus` AND defaults `thumbnailFailCount = 0`** — `SchemaV4MigrationTests.testV3ToV4PreservesThumbnailStatusAndDefaultsFailCount`: seed V3 with rows of `.pending/.uploaded/.failed/.notApplicable`, assert all preserved + new field is 0.
5. **3 failures (count reaching 3) flips status to `.failed`; 2 leaves `.pending`** — `MetadataStoreThumbnailFailureTests.test3StrikesTransitionsToFailed`.
6. **ETag change resets BOTH `thumbnailFailCount` AND `thumbnailStatus`** — `MetadataStoreThumbnailFailureTests.testEtagChangeResetsFailureState`.
7. **`fetchPendingThumbnails` predicate excludes `.failed`** — `MetadataStoreThumbnailQueriesTests.testFailedRowsNotIncluded` (extend existing).
8. **`ThumbnailFetchLimiter` never has more than `maxSlots` callers in the critical region simultaneously** — `ThumbnailFetchLimiterTests.testNeverExceedsMaxSlots`: spawn 20 contenders, instrument the inside of the critical region with an atomic counter, assert max observed value <= 4.
9. **BFS hook does NOT fire when `enabled == false`** — `BFSThumbnailHookTests.testGatedByEnabledFlag`.
10. **BFS hook does NOT fire when `isDrivePaused == true`** — `BFSThumbnailHookTests.testGatedByPause`.
11. **Coordinator returns zero-counts when `thermalState >= .serious`** — `ThumbnailBackfillCoordinatorTests.testThermalGateReturnsZero` (requires injectable thermal-state probe).
12. **Coordinator does NOT increment strike count on cancellation** — `ThumbnailBackfillCoordinatorTests.testCancellationDoesNotIncrementStrike`.
13. **Delete cascade fires only AFTER successful original delete** — `DeleteThumbnailCascadeTests.testCascadeOrdering`: when original delete throws, cascade Task is NOT spawned (assert via mocked client recording).
14. **Rename cascade fallback marks NEW key `.pending`, not OLD key** — `RenameThumbnailCascadeTests.testCopyFailureMarksNewKeyPending`.
15. **Orphan sweep cap = 50 per pass; never deletes more in one invocation** — `OrphanSweeperTests.testCapEnforcement`: seed 200 orphans, assert exactly 50 deleted on one call.
16. **No `listObjectsV2` call site outside `OrphanSweeper.swift` performs unrestricted listing** — grep-based assertion (CI-runnable).
17. **`copyThumbnail` preserves source metadata** — `DS3S3ClientCopyThumbnailTests.testPreservesMetadata` via mocked S3: capture `CopyObjectRequest`, assert `metadataDirective == nil` (i.e., default = COPY).
18. **Silent rollout writes `enabled: true` exactly once per drive** — `ThumbnailRolloutTests.testOncePerDriveSemantics`: simulate two consecutive launches, assert `inspectThumbnailPrefix` is called exactly once per drive across both launches.

## Security Domain

> Note: `security_enforcement` is not explicitly configured in `.planning/config.json`; treating as enabled per protocol.

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | yes (inherited) | Existing IAM v1 challenge-response + JWT in `DS3Authentication` (DS3Lib). Phase 13 doesn't touch auth flow. The auth-error mapping at the consume-path boundary (`.cannotSynchronize`) routes to existing drive error UI, NOT a new auth surface |
| V3 Session Management | no | No new sessions introduced |
| V4 Access Control | yes (inherited) | S3 bucket access controlled by per-drive IAM keys (existing). Thumbnails inherit the same access boundary — `.thumbnails/<key>.jpg` is in the same bucket+prefix as the original. Anyone with read access to originals has read access to thumbnails (correct: thumbnails MUST not exceed access scope) |
| V5 Input Validation | yes | (1) `S3PathUtils.isRasterExtension` allow-list rejects unknown extensions before render → defense against malicious file types triggering ImageIO format-confusion. (2) ETag CR/LF stripping at `DS3S3Client+Thumbnails.swift:23-24` already defends against header injection from a hostile S3-compatible endpoint. (3) Renderer `os_proc_available_memory()` guard at `ThumbnailRenderer.swift:27` blocks DoS via huge images |
| V6 Cryptography | no | No new crypto. Bucket-level encryption (existing) protects thumbnails the same as originals |

### Known Threat Patterns for the macOS File Provider extension + Soto v6 stack

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| Path traversal via crafted S3 key (e.g., `..\.thumbnails\..`) | Tampering | `S3PathUtils.thumbnailKey` always passes through `isUserVisible` filter before any read; thumbnails never escape `<drive.prefix>.thumbnails/<key>.jpg` namespace because the key construction is purely string-suffix |
| Custom error domain leak crashing thumbnail subsystem (Pitfall 4 in milestone PITFALLS.md) | Denial of Service | D-13 mandatory error-domain mapping at the File Provider boundary; renderer/Soto errors never cross |
| Resource exhaustion via 1000-image folder browse → SlowDown cascade → stuck Finder | Denial of Service | D-12 `ThumbnailFetchLimiter` cap of 4 in-flight on macOS; consume path returns `.serverUnreachable` on SlowDown without retrying inside a held slot (D-14) |
| Renderer memory exhaustion via crafted huge HEIC | Denial of Service | Phase 11's `os_proc_available_memory()` guard (existing) returns nil on low-mem; format allow-list rejects non-raster |
| Stale thumbnail attached to renamed-then-replaced original (Pitfall 12 in milestone PITFALLS.md) | Information Disclosure | D-10 unconditional re-render on `modifyItem`; `x-amz-meta-source-etag` enables out-of-band staleness detection in future phases |
| Header injection via hostile ETag in S3-compatible response | Tampering | CR/LF stripping at `DS3S3Client+Thumbnails.swift:23-24` (existing Phase 12 defense) |
| 3-strike loop never terminating → infinite S3 retry cost | Denial of Service / Cost | D-29/30/31 — `.failed` is terminal until ETag change; predicate excludes `.failed` from `fetchPendingThumbnails` |

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| `fetchThumbnails` downloads original + renders inline (existing pre-Phase-13 code at `+Thumbnails.swift:225-236`) | Cache-first read of `.thumbnails/<key>.jpg`; 404 → mark `.pending` for backfill | Phase 13 (this phase) | No more full-file downloads on consume path; bandwidth + latency drop dramatically. THUMB-23 satisfied |
| Backfill: nonexistent (no opportunistic backfill in v2.0) | BFS-pass-tail batched coordinator with thermal/pause gating + 3-strike termination | Phase 13 | First time existing-bucket thumbnails populate without user action |
| Cascade on delete/rename: nonexistent | Fire-and-forget Tasks after successful original op + orphan sweep backstop | Phase 13 | Bucket stays clean; storage cost of `.thumbnails/` matches user-visible content |
| `BGAppRefreshTask` for sync polling (existing) | Deferred — Phase 14 adds `BGProcessingTask` for iOS-side thumbnail backfill | Phase 14 | Out of scope for Phase 13 |

**Deprecated/outdated in Phase 13:**
- The `downloadThumbnailImage` method in `+Thumbnails.swift:266-367` is DELETED entirely (D-11). Old call site (line 228) is replaced by `consumeThumbnail` (Pattern 2 above).
- The whole-file `S3Lib+Thumbnails.swift` (DS3DriveProvider) shrinks — only the path-utility wrappers remain after this phase. Phase 13 might inline these into call sites and delete the file, or keep it for symmetry with `S3Lib+Trash.swift`. (Discretion.)

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | Soto 6 omits the `x-amz-metadata-directive` header when `metadataDirective: nil`, allowing AWS S3 to default to COPY semantics | Pattern 6, D-23 | If Soto sets some default value other than nil-omission, the request might fail or replace metadata. **Verify in Wave 0:** add a unit test that captures the `CopyObjectRequest` and asserts `metadataDirective == nil`; if it serializes differently, the existing `DS3S3Client.copyObject` already passes `nil` so the behavior is what we get. Phase 12 already shipped this code path — it's been working in tests for `copyObject(metadata: nil)` |
| A2 | `Task.checkCancellation()` is honored by Soto's async `getObject(toFile:)` and `putObject(...)` such that a `Task.cancel()` from the BFS layer reliably aborts an in-flight download | Pitfall 7, Pattern 4 | If Soto doesn't honor cancellation, paused drives may continue downloading large originals up to several seconds before the next cancellation point. D-20's "complete in-flight" carve-out covers this — degraded but acceptable. **Verify in Wave 0** with a test that issues `Task.cancel()` mid-download against a mock client that simulates a long delay; assert behavior matches D-20 |
| A3 | `ProcessInfo.thermalState` reads are constant-time and side-effect-free; reading once per `runBatch` is sufficient | Pattern 3, D-19 | If reading `thermalState` is expensive on macOS, batch entry overhead grows. Apple docs imply it's cached state; risk is low |
| A4 | Cubbit DS3 supports `S3.copyObject` with read-after-write consistency (i.e., after a copyThumbnail succeeds, a subsequent getThumbnailBytes against the new key returns the bytes) | D-22, Pitfall 5 | If consistency is eventual, the rename cascade's "delete old after copy succeeds" leaves a momentary window where neither key has the thumbnail readable. D-22's fallback "mark `.pending` on copy failure" doesn't cover this window. AWS S3 itself is strongly consistent for read-after-write since Dec 2020; Cubbit DS3 should be too. **Risk acceptable:** worst case is a single fetchThumbnails miss → mark `.pending` → backfill regenerates |
| A5 | The existing `BFS allPassKeys: Set<String>` (verified `BreadthFirstIndexer.swift:94,126`) is complete (contains all originals at end of pass) — orphan sweep can use it as the authoritative "exists" set | D-25 | If BFS skips some keys (e.g., on listobjects errors), the sweep would falsely classify legitimate originals' thumbnails as orphans. The 50/pass cap and the eventual-consistency model bound the damage to "user sees thumbnail flicker, regenerates next pass". Acceptable per D-26 rationale |
| A6 | The `.conflicting` state from `inspectThumbnailPrefix` is rare in practice (most users won't have foreign `.thumbnails/` content) | D-01, D-02 | If many users hit `.conflicting`, the silent UX leaves them confused why thumbnails don't appear. Phase 13's choice (D-03) is to ship silent — Phase 14 may revisit if support tickets show the pattern |

**If this table is empty:** Not the case — six items above need confirmation, none of them block planning. All assumptions can be verified in Wave 0 tests or accepted per D-decisions.

## Open Questions (RESOLVED)

None blocking the planner. Two low-priority items resolved as decisions:

1. **`OrphanSweeper` shape:** RESOLVED: ship as a `Sendable` struct with stateless methods. Sweep is not a long-running stateful operation; one invocation per BFS pass. Plan 13-09 implements as `struct OrphanSweeper`.
2. **`setThumbnailFailure` return type:** RESOLVED: `@discardableResult func setThumbnailFailure(...) async throws -> ThumbnailStatus`. Returning the resulting status lets callers log the `.failed` transition distinctly from a normal increment. Plan 13-04 implements this signature.

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| Xcode | macOS extension build | ✓ | 16.x (CI: 16.2 stricter than local) | — |
| swift-package-manager (SwiftPM) | DS3Lib unit tests | ✓ | included with Xcode | — |
| Git LFS | Test fixtures (Phase 11/12 fixtures already in repo) | ✓ | already used | — |
| Soto v6 SotoS3 | S3 operations including `copyObject` | ✓ | 6.x (declared in `DS3Lib/Package.swift`) | — |
| ImageIO (system) | `ThumbnailRenderer` | ✓ | system | — |
| FileProvider (system) | extension protocols | ✓ | system | — |
| SwiftData (system) | Schema V4 migration | ✓ | macOS 14+ | — |
| `fileproviderd` | extension hosting (debug + runtime) | ✓ | macOS system service | killall + lsregister recovery (CLAUDE.md) |
| `idevicesyslog` (libimobiledevice) | iOS device logs (only useful for iOS — Phase 13 is macOS-only) | optional | only if doing iOS investigation | n/a |

**Missing dependencies with no fallback:** None — Phase 13 is pure code change, no new external deps.

## Sources

### Primary (HIGH confidence)
- `DS3Lib/Sources/DS3Lib/Thumbnails/ThumbnailBackfillCoordinator.swift` (Phase 12) — verified existing actor with `runBatch` already wired end-to-end
- `DS3Lib/Sources/DS3Lib/DS3S3Client+Thumbnails.swift` (Phase 12) — verified `putThumbnail` / `getThumbnailBytes` / `deleteThumbnail` shapes
- `DS3Lib/Sources/DS3Lib/DS3S3Client.swift:326-342` — verified `copyObject(metadataDirective: nil → COPY default)` behavior
- `DS3Lib/Sources/DS3Lib/Metadata/SyncedItem.swift` — verified V1/V2/V3 schema patterns + `nonisolated static let` requirement
- `DS3Lib/Sources/DS3Lib/Metadata/MetadataStore+Queries.swift` (Phase 12) — verified `fetchPendingThumbnails` / `setThumbnailStatus`
- `DS3Lib/Sources/DS3Lib/Constants/DefaultSettings.swift:215-227` — verified `Thumbnail` namespace + `rasterExtensions` allow-list
- `DS3DriveProvider/BreadthFirstIndexer.swift:94,126,191` — verified `allPassKeys: Set<String>` is built during pass
- `DS3DriveProvider/FileProviderExtension+Thumbnails.swift:157-249` — verified existing `fetchThumbnails` shape that Phase 13 rewrites
- `DS3DriveProvider/FileProviderExtension+Create.swift:231-245` — verified post-PUT ETag-return seam for upload hook
- `DS3DriveProvider/FileProviderExtension+Modify.swift:286,339,443` — verified rename / move sites where cascade fires
- `DS3DriveProvider/BucketListingLimiter.swift` — actor precedent for `ThumbnailFetchLimiter`
- `.planning/phases/12-renderer-storage-schema/12-VERIFICATION.md` — confirms 500 tests green, all Phase 12 artifacts shipped
- CLAUDE.md "File Provider Error Handling" — non-negotiable error domain rule
- MEMORY.md — `Schema.Version` non-Sendable footgun, "NEVER return custom error types"

### Secondary (MEDIUM confidence)
- [Apple — `ProcessInfo.thermalState`](https://developer.apple.com/documentation/foundation/processinfo/thermalstate-swift.property) — read at any time, four levels (nominal/fair/serious/critical)
- [Apple — `NSProcessInfoThermalStateDidChangeNotification`](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/RespondToThermalStateChanges.html) — observation pattern (deferred to Phase 14)
- [AWS S3 — `CopyObject` `metadataDirective`](https://docs.aws.amazon.com/AmazonS3/latest/API/API_CopyObject.html) — "If metadataDirective isn't specified, COPY is the default behavior"
- `.planning/research/STACK.md` — ImageIO, Soto, FileProvider stack characteristics
- `.planning/research/PITFALLS.md` — milestone-level pitfall catalog; Phase 13-applicable items (#3, #4, #8, #9, #10, #12) referenced inline
- `.planning/research/ARCHITECTURE.md` — extension-side mass concentration in Phase C/13

### Tertiary (LOW confidence — flagged for validation)
- Soto v6 Swift SDK exact `metadataDirective` serialization when set to `nil` — assumed to be header omission (Assumption A1). Verified indirectly via Phase 12 tests that already pass `metadata: nil` through `copyObject`
- Cubbit DS3 read-after-write consistency for `copyObject` (Assumption A4) — assumed to match AWS S3 (Dec 2020 strong consistency)

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — every framework verified in existing codebase
- Architecture: HIGH — wiring of existing primitives, no new architectural inventions
- Pitfalls: HIGH — milestone PITFALLS.md is mature; new pitfalls (Schema V4 trap, Task.detached self capture, limiter deadlock) verified against MEMORY.md and existing patterns
- Soto `copyObject` defaults: MEDIUM — Apple/Soto docs are clear, but verify in Wave 0 unit test capturing the request

**Research date:** 2026-04-25
**Valid until:** 2026-05-25 (30 days; stable codebase area, slow-moving framework dependencies)

## RESEARCH COMPLETE
