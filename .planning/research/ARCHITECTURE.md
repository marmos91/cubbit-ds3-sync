# Architecture Research: v3.1 Thumbnails

**Domain:** Integration of thumbnail generation/storage/consumption into DS3 Drive's existing File Provider app
**Researched:** 2026-04-11
**Confidence:** HIGH

## Key Discoveries

1. **Thumbnails already exist on macOS — but via download-then-generate-on-demand.** `DS3DriveProvider/FileProviderExtension+Thumbnails.swift` already implements `fetchThumbnails(for:requestedSize:...)` by downloading the full original from S3, then calling ImageIO. v3.1 shifts this to a precomputed `.thumbnails/` S3 prefix. This is a **refactor of an existing consumer**, not a greenfield implementation.

2. **Generators already exist in the macOS extension target.** `FileProviderExtension+ThumbnailGenerators.swift` has `generateImageThumbnail`, `generateVideoThumbnail`, `generatePDFThumbnail`, `jpegData` as static methods using ImageIO/AVFoundation/CoreGraphics. These must **move to DS3Lib** as `ThumbnailRenderer` so iOS main app can call them.

3. **`.thumbnails/` filtering has a 1:1 precedent.** `S3PathUtils.trashPrefix(forDrivePrefix:)`, `isTrashedKey(_:drivePrefix:)`, `DefaultSettings.S3.trashPrefix = ".trash/"` (Constants/DefaultSettings.swift:196). Filter hook: `S3Enumerator.swift:416-418`:
   ```swift
   let allItems = items.filter { item in
       !S3Lib.isTrashedKey(item.itemIdentifier.rawValue, drive: self.drive)
   }
   ```
   `.thumbnails/` filter is a literal copy.

4. **Upload-path integration has two call sites**, both return an ETag from `s3Lib.putS3Item`:
   - `DS3DriveProvider/FileProviderExtension+Create.swift:220` (after successful PUT, before `metadataStore.upsertItem`)
   - `DS3DriveProvider/FileProviderExtension+Modify.swift:154` (same pattern)
   Both are **macOS-only** for generation — iOS extension gated at `+Thumbnails.swift:165-173`.

5. **iOS backfill has a real home: `BackgroundRefreshManager`.** `DS3DriveApp/Helpers/BackgroundRefreshManager.swift` uses `BGTaskScheduler` with `io.cubbit.DS3Drive.refreshDrives` (BGAppRefreshTask). New `thumbnailBackfill` is a **second distinct identifier** using `BGProcessingTask`, not a replacement.

6. **MetadataStore needs schema V3** adding `thumbnailStatus` column (`.notApplicable | .pending | .uploaded | .failed`). Existing fallback at `MetadataStore.createContainer()` lines 28-46 auto-recreates on migration failure, so low risk.

7. **`.thumbnails/` rows must NOT be written into MetadataStore.** Filter at `ItemUpsertData` construction time in `S3Enumerator`, same pattern as trash.

## Target Architecture

```
┌────────────────────────────────────────────────────────────────────────┐
│ UI                                                                     │
│  Finder (macOS)                    iOS Files + Main App                │
│   └─ fetchThumbnails                └─ fetchThumbnails (CONSUMES only) │
├────────────────────────────────────────────────────────────────────────┤
│ DS3DriveProvider (shared extension, #if os() gated)                    │
│  ┌──────────────────┐  ┌──────────────────┐                            │
│  │ ThumbnailConsumer│  │ S3Enumerator     │                            │
│  │ (NEW, both)      │  │ (MODIFY: filter) │                            │
│  └────────┬─────────┘  └──────────────────┘                            │
│  ┌────────┴─────────┐  ┌──────────────────┐  ┌─────────────────┐       │
│  │ UploadThumbHook  │  │ DeleteThumbHook  │  │ MoveThumbHook   │       │
│  │ (NEW, macOS-only)│  │ (NEW, both)      │  │ (NEW, both)     │       │
│  └──────────────────┘  └──────────────────┘  └─────────────────┘       │
├────────────────────────────────────────────────────────────────────────┤
│ DS3Lib (shared SPM)                                                    │
│  ┌──────────────────┐  ┌──────────────────┐  ┌─────────────────┐       │
│  │ ThumbnailRenderer│  │ ThumbnailS3Svc   │  │ S3PathUtils     │       │
│  │ (NEW, ImageIO)   │  │ (NEW) put/get/   │  │ (MODIFY: thumb  │       │
│  │ raster only      │  │  delete          │  │  prefix helpers)│       │
│  └──────────────────┘  └──────────────────┘  └─────────────────┘       │
│  ┌──────────────────┐  ┌──────────────────┐                            │
│  │ ThumbnailKey     │  │ ThumbBackfill    │                            │
│  │ (NEW) key mapping│  │ Coordinator (NEW)│                            │
│  └──────────────────┘  └──────────────────┘                            │
│  ┌──────────────────┐  ┌──────────────────┐  ┌─────────────────┐       │
│  │ MetadataStore    │  │ SharedData       │  │ DefaultSettings │       │
│  │ (MODIFY: V3 +    │  │ (MODIFY: +thumb  │  │ (MODIFY: thumb  │       │
│  │  thumbnailStatus)│  │  Settings)       │  │  prefix + size) │       │
│  └──────────────────┘  └──────────────────┘  └─────────────────┘       │
├────────────────────────────────────────────────────────────────────────┤
│ DS3Drive (macOS app)        DS3DriveApp (iOS main app)                 │
│  No new components.         ┌─────────────────────────┐                │
│  Backfill runs inside       │ iOSThumbBackfillTask    │                │
│  macOS extension BFS.       │ (NEW) BGProcessingTask  │                │
│                             └──────────┬──────────────┘                │
│                             ┌──────────┴──────────────┐                │
│                             │ ForegroundBackfillDriver│                │
│                             │ (NEW) scene.active hook │                │
│                             └─────────────────────────┘                │
├────────────────────────────────────────────────────────────────────────┤
│ S3 (Cubbit DS3 gateway)                                                │
│  <drivePrefix>/original/key.jpg               ← existing                │
│  <drivePrefix>/.thumbnails/original/key.jpg.jpg  ← NEW                 │
└────────────────────────────────────────────────────────────────────────┘
```

## Component Inventory

### DS3Lib (cross-target, MUST LAND FIRST)

| Component | Status | File | Responsibility |
|-----------|--------|------|----------------|
| `DefaultSettings.S3.thumbnailsPrefix` | **MODIFY** | `Constants/DefaultSettings.swift` | `".thumbnails/"` — mirrors `trashPrefix` at line 196 |
| `DefaultSettings.S3.thumbnailMaxDimension` | **MODIFY** | same | Fixed size (suggest 512 px long edge) |
| `S3PathUtils.thumbnailsPrefix(forDrivePrefix:)` | **MODIFY** | `Utils/S3PathUtils.swift` | Analogue of `trashPrefix(forDrivePrefix:)` |
| `S3PathUtils.isThumbnailKey(_:drivePrefix:)` | **MODIFY** | same | Analogue of `isTrashedKey` |
| `S3PathUtils.thumbnailKey(forOriginalKey:drivePrefix:)` | **MODIFY** | same | Maps `photos/a.heic` → `photos/.thumbnails/a.heic.jpg` — **append `.jpg`, don't substitute** (collision avoidance) |
| `S3PathUtils.originalKey(fromThumbnailKey:drivePrefix:)` | **MODIFY** | same | Reverse mapping for orphan sweep |
| `ThumbnailRenderer` | **NEW** | `Thumbnails/ThumbnailRenderer.swift` | Pure ImageIO rasterizer, platform-agnostic. Raster scope only (jpg/png/heic/webp/gif/tiff). PDF/video generators **stay in extension target** as fallback — not promoted to DS3Lib in v3.1. |
| `ThumbnailKey` | **NEW** | `Thumbnails/ThumbnailKey.swift` | Value type for `(originalKey, thumbnailKey)` with extension-append rule |
| `ThumbnailS3Service` | **NEW** | `Thumbnails/ThumbnailS3Service.swift` | Protocol + impl: `put`, `getData`, `delete`, `headIfExists` — wraps `DS3S3Client` with small-object semantics (no multipart — thumbnails always <500KB) |
| `ThumbnailBackfillCoordinator` | **NEW** | `Thumbnails/ThumbnailBackfillCoordinator.swift` | **Actor.** Owns reconciliation algorithm. Generator is injected as closure (macOS passes existing extension generators; iOS passes `ThumbnailRenderer`). Same orchestration, different host. |
| `SyncedItem.thumbnailStatus` | **MODIFY** | `Metadata/SyncedItem.swift` | Enum: `.notApplicable / .pending / .uploaded / .failed` |
| Schema V3 migration | **MODIFY** | `SyncedItemMigrationPlan` | Lightweight V2→V3 (new optional column). Recovery path at `MetadataStore.createContainer()` lines 28-46 handles migration failure. |
| `MetadataStore.fetchItemsNeedingThumbnail(driveId:limit:)` | **MODIFY** | `Metadata/MetadataStore+Queries.swift` | Query by `thumbnailStatus == .pending` |
| `MetadataStore.setThumbnailStatus(s3Key:driveId:status:)` | **MODIFY** | same | Writer for generators + cascade ops |
| `SharedData+thumbnailSettings` | **NEW** | `SharedData/SharedData+thumbnailSettings.swift` | Mirror of `+trashSettings`. Enable/disable toggle. |

### DS3DriveProvider (shared extension, `#if os()` gated)

| Component | Status | File | Responsibility |
|-----------|--------|------|----------------|
| `.thumbnails/` filter (recursive path) | **MODIFY** | `S3Enumerator.swift:416-418` | Add `!S3PathUtils.isThumbnailKey(...)` to existing filter — **single discrete component** |
| `.thumbnails/` filter (per-folder path) | **MODIFY** | same, ~line 310 | Same filter on delimited `listS3Items` |
| `BreadthFirstIndexer` skip rule | **MODIFY** | `BreadthFirstIndexer.swift` | Early-continue on thumbnail prefix dequeue |
| `UploadThumbnailHook` | **NEW** | `FileProviderExtension+ThumbnailUploadHook.swift` (`#if os(macOS)`) | Called from `+Create.swift:220` and `+Modify.swift:154` after `putS3Item` success. Zero-cost ImageIO against the already-local file. Uploads via `ThumbnailS3Service`. Best-effort — all errors non-fatal. |
| `DeleteThumbnailHook` | **NEW** | `FileProviderExtension+ThumbnailDeleteHook.swift` (both) | Called from `+Delete.swift` after S3 delete. Best-effort. Orphan sweep backstops failures. |
| `MoveThumbnailHook` | **NEW** | `FileProviderExtension+ThumbnailMoveHook.swift` (both) | S3 server-side copy + delete on rename/move (`+Modify.swift:284, 337`) |
| `fetchThumbnails` cache-first refactor | **MODIFY** | `+Thumbnails.swift:157-249` | New primary path: `ThumbnailS3Service.getData(forOriginalKey:)` → HIT return, MISS: macOS fallback to existing download-and-generate + enqueue; iOS fallback to `(nil, nil)` + enqueue via `thumbnailStatus = .pending` |
| `#if os(iOS)` bailout | **MODIFY** | `+Thumbnails.swift:165-173` | Relax — cache-first path runs both platforms (it's just a small S3 GET). Keep "no live generation on iOS extension" rule intact. |

### DS3DriveApp (iOS main app)

| Component | Status | File | Responsibility |
|-----------|--------|------|----------------|
| `iOSThumbnailBackfillTask` | **NEW** | `Helpers/ThumbnailBackfillTask.swift` | Register `BGProcessingTaskRequest` identifier `io.cubbit.DS3Drive.thumbnailBackfill`, `requiresExternalPower = true`, `requiresNetworkConnectivity = true`. Task body: `ThumbnailBackfillCoordinator` with `ThumbnailRenderer`. Coexists with existing BGAppRefreshTask. |
| `ForegroundBackfillDriver` | **NEW** | `Helpers/ForegroundBackfillDriver.swift` | Observes `ScenePhase.active`, runs coordinator with smaller batch size, stops on `.inactive`. Guaranteed path for "open app, let it process." |
| Info.plist | **MODIFY** | `DS3DriveApp/Info.plist` | Add `io.cubbit.DS3Drive.thumbnailBackfill` to `BGTaskSchedulerPermittedIdentifiers`. Add `processing` to `UIBackgroundModes`. |
| Xcode project | **MODIFY** | project file | Enable "Background processing" capability on iOS main app target (in addition to existing "Background fetch") |
| `IOSDriveViewModel` / Settings | **MODIFY** | `ViewModels/IOSDriveViewModel.swift` + Settings view | Surface backfill progress ("123 of 456 thumbnails generated"). Reads `fetchItemsNeedingThumbnail` count. Essential for iOS users to understand non-instant backfill. |

### DS3Drive (macOS app)

**Zero changes.** All macOS generation happens in the extension. Main app is tray UI + config only. Resist adding a thumbnail service to the main app.

## Data Flows

**Flow 1 — Upload-path generation (macOS extension)**
```
User drops image → createItem(contents: file://tmp/...)
  → s3Lib.putS3Item(fileURL) → ETag               [existing, +Create.swift:220]
  → UploadThumbnailHook.generateAndUpload(fileURL, originalKey = key)  [NEW, macOS only]
      ├─ ThumbnailRenderer.render(fileURL)
      ├─ ThumbnailS3Service.put(data, forOriginalKey: key)
      │    ↳ PutObject to <drivePrefix>/.thumbnails/<key>.jpg
      └─ MetadataStore.setThumbnailStatus(key, .uploaded)
  → metadataStore.upsertItem(...)                  [existing]
  → completionHandler (file visible immediately; thumbnail runs async)
```

**Flow 2 — Consumption (both platforms)**
```
Finder/Files asks for thumbnails → fetchThumbnails(itemIdentifiers)
  for each identifier:
    ThumbnailS3Service.getData(forOriginalKey)     [GET .thumbnails/<key>.jpg]
    ├─ HIT → perThumbnailCompletionHandler(id, data, nil)  DONE
    └─ MISS (404):
        #if macOS:
          1. existing download-and-generate fallback
          2. enqueue key for ThumbnailBackfillCoordinator
        #if iOS:
          1. perThumbnailCompletionHandler(id, nil, nil)   // type icon fallback
          2. MetadataStore.setThumbnailStatus(key, .pending) via App Group
             ← iOS main app picks up next BGProcessingTask / foreground
```

**Flow 3 — Backfill (shared coordinator, different hosts)**

*Host A — macOS extension, inside BFS pass:*
```
BreadthFirstIndexer.runOneBFSPass()
  → ThumbnailBackfillCoordinator.runBatch(
        metadataStore,
        s3Service = ThumbnailS3Service,
        renderer = { url, size in FileProviderExtension.generateImageThumbnail(url, size) }
    )
  → for each pending image:
      1. download original via s3Lib.getS3Item
      2. render via injected closure
      3. upload via ThumbnailS3Service.put
      4. MetadataStore.setThumbnailStatus(.uploaded)
```

*Host B — iOS main app, BGProcessingTask:*
```
iOS wakes app (charging + idle)
  → iOSThumbnailBackfillTask.handle(task)
  → ThumbnailBackfillCoordinator.runBatch(        [SAME CODE PATH AS MACOS]
        metadataStore,
        s3Service = ThumbnailS3Service,
        renderer = { url, size in ThumbnailRenderer.render(url, size) }
    )
  → task.setTaskCompleted(success: true)
  → schedule next BGProcessingTaskRequest (~24h)
```

**Flow 4 — Cascade delete/move**
```
User deletes in Finder/Files → deleteItem(identifier)
  → s3Lib.deleteS3Item(...) or moveToTrash(...)   [existing]
  → DeleteThumbnailHook.delete(forOriginalKey)    [NEW, both]
  → ThumbnailS3Service.delete(forOriginalKey)     [best-effort, no propagation]
  → metadataStore.deleteItem (existing cascades thumbnail row)
```

**Flow 5 — Orphan sweep (inside coordinator, periodic)**
```
ThumbnailBackfillCoordinator.runBatch()
  ↓ every N passes:
list .thumbnails/ prefix (paginated)
  ↓
for each thumbnail key:
  1. derive original key via S3PathUtils.originalKey
  2. HEAD the original
  3. if 404 → delete orphan thumbnail
```

## Build Order

This order respects four hard constraints:
1. iOS extension consume-only — consume path ships before iOS writes anywhere
2. Upload-path and reconciliation-path generation are layered, not merged
3. Filtering must exist before any generation (otherwise first write pollutes Finder)
4. DS3Lib shared code lands before any consumer `import`s it

**Phase A — Foundation & Filtering (DS3Lib only, zero behavior change)**
- `DefaultSettings.S3.thumbnailsPrefix` + size constants
- `S3PathUtils` thumbnail helpers (mirror of trash, unit-tested)
- `ThumbnailKey` value type + tests
- `.thumbnails/` filtering in `S3Enumerator` + `BreadthFirstIndexer` (same step — load-bearing ordering)
- **Why first:** no thumbnails exist yet, filter is a no-op. Landing filter with no-op payload is the safe ordering. Unblocks everything.

**Phase B — Storage & Renderer (DS3Lib only)**
- `ThumbnailS3Service` protocol + impl (mocked S3 tests)
- Schema V3 migration for `thumbnailStatus`
- `MetadataStore` query/setter methods
- `SharedData+thumbnailSettings`
- `ThumbnailRenderer` (ImageIO only, raster scope, unit tests with Git LFS fixtures)
- **Why second:** defines read/write seams. Pure, testable, no call sites yet.

**Phase C — macOS generation & consumption (DS3DriveProvider)**
- `UploadThumbnailHook` wired into `+Create.swift:220` + `+Modify.swift:154`
- `fetchThumbnails` cache-first refactor (existing download-and-generate becomes MISS fallback)
- `MoveThumbnailHook` + `DeleteThumbnailHook` (cascade integrity is load-bearing before trusting the system)
- macOS backfill: `ThumbnailBackfillCoordinator` called from `BreadthFirstIndexer` per BFS pass, budgeted
- Orphan sweep
- **Why third:** First user-visible change. Finder shows instant thumbnails for new uploads, then backfilled for existing content. iOS automatically benefits — cache-first path is cross-platform; iOS Files starts showing thumbnails for anything macOS generated.

**Phase D — iOS generation (DS3DriveApp)**
- `iOSThumbnailBackfillTask` with `BGProcessingTask` registration
- `ForegroundBackfillDriver`
- Settings UI progress indicator
- Info.plist + Xcode capability
- **Why last:** iOS is consume-only platform. Ship consume path first (Phase C), verify iOS sees macOS-generated thumbnails end-to-end, *then* light up iOS-side generation. If iOS-side is broken, iOS users still see thumbnails for macOS-synced files.

## Integration Points (exact file paths)

| Integration | File | Line | What goes there |
|-------------|------|------|-----------------|
| Enum filter (recursive) | `DS3DriveProvider/S3Enumerator.swift` | 416-418 | Add `isThumbnailKey` check to existing `.filter` |
| Enum filter (per-folder) | `DS3DriveProvider/S3Enumerator.swift` | ~310 | Same filter for delimited `listS3Items` |
| BFS skip | `DS3DriveProvider/BreadthFirstIndexer.swift` | in `runOneBFSPass` dequeue | Early-continue on thumbnail prefix |
| Upload hook (create) | `+Create.swift` | 220 (after `putS3Item` success) | `UploadThumbnailHook` `#if os(macOS)` |
| Upload hook (modify) | `+Modify.swift` | 154 (after `putS3Item` success) | Same |
| Delete hook | `+Delete.swift` | after S3 delete | `DeleteThumbnailHook` both platforms |
| Rename/move hook | `+Modify.swift` | 284, 337 | `MoveThumbnailHook` after `moveS3Item` |
| Consumer cache-first | `+Thumbnails.swift` | 157-249 | Rewrite `fetchThumbnails` |
| Existing generators kept | `+ThumbnailGenerators.swift` | entire file | Becomes macOS MISS fallback |
| macOS backfill trigger | `BreadthFirstIndexer.swift` | end of `runOneBFSPass` | Call coordinator with budgeted batch |
| iOS BG task registration | `DS3DriveApp/DS3DriveApp.swift` | where `BackgroundRefreshManager` is registered | Register second task identifier |
| iOS BG task Info.plist | `DS3DriveApp/Info.plist` | `BGTaskSchedulerPermittedIdentifiers` | Add `io.cubbit.DS3Drive.thumbnailBackfill` + `processing` UIBackgroundMode |

## Open Questions for Roadmapper

1. **Thumbnail key mapping — append vs. substitute extension.** Recommend **append** (`photo.heic` → `.thumbnails/photo.heic.jpg`) for collision resistance. Milestone text is ambiguous; make this explicit in Phase A.
2. **Single-size policy.** PROJECT.md says "single fixed size." Recommend **512 px long edge, JPEG Q0.7** in `DefaultSettings.S3`.
3. **Schema V3 vs. FOUN-04.** FOUN-04 (SwiftData metadata DB shared via App Group) is still open. Decide whether v3.1 is the moment to close it or ship focused V3 delta.
4. **Backfill budget.** macOS BFS backfill needs per-pass cap (suggest: 20 thumbnails per pass) to avoid starving user-initiated fetches. Needs empirical tuning.
5. **iOS foreground driver opt-in.** Automatic or gated on a setting? Cellular users may object. Recommend **Wi-Fi only** via `NetworkMonitor` in `DS3Lib/Sync/NetworkMonitor.swift`.

## Confidence

| Area | Level | Reason |
|------|-------|--------|
| Existing extension flow | HIGH | Read `+Thumbnails.swift` + `+ThumbnailGenerators.swift` end-to-end |
| `.thumbnails/` filter placement | HIGH | Filter at `S3Enumerator.swift:416-418` is exact precedent |
| DS3Lib seams | HIGH | `S3PathUtils`, `SharedData+trashSettings`, `MetadataStore+Trash` are established conventions |
| macOS upload call sites | HIGH | Verified `+Create.swift:220` + `+Modify.swift:154` ETag return + "after success, before upsert" window |
| iOS BG task model | HIGH | `BackgroundRefreshManager.swift` is exact precedent; `BGProcessingTask` is a sibling API |
| Schema V3 migration risk | MEDIUM | Safe recreate-on-failure exists but SwiftData migrations non-trivial (FOUN-04 still open) |
| Orphan sweep correctness | MEDIUM | Depends on reverse key mapping — test extension-append rule carefully |
