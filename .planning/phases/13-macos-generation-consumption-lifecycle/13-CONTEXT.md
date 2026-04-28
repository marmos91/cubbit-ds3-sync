# Phase 13: macOS Generation, Consumption & Lifecycle - Context

**Gathered:** 2026-04-25
**Status:** Ready for planning

<domain>
## Phase Boundary

Phase 13 wires the Phase-11/12 primitives into user-visible flows on macOS — the **first user-visible thumbnails** in v3.1. Specifically:

1. **Upload-time generation** — Inline, fire-and-forget thumbnail generation post-PUT in `createItem` / `modifyItem`, decoupled from the upload contract (THUMB-06).
2. **Cache-first `fetchThumbnails` rewrite** — `FileProviderExtension+Thumbnails.swift:157-249` is rewritten to read `.thumbnails/<key>.jpg` from S3 first; on miss, return nil (default UTType icon) and mark `.pending` for backfill (THUMB-11, 12, 13).
3. **`ThumbnailFetchLimiter`** — actor in DS3DriveProvider (macOS=4) wrapping the consume path; upload-path bypasses (THUMB-14).
4. **BFS-driven backfill** — `BreadthFirstIndexer` calls `ThumbnailBackfillCoordinator.runBatch(maxItems: 5)` after every successful pass tail; thermal-gated; pause-aware (THUMB-15, 21, 23).
5. **Cascades** — Delete cascade: fire-and-forget `deleteThumbnail` after successful original delete (THUMB-17). Rename cascade: server-side S3 copy old→new + delete old (THUMB-18). Modify cascade: re-render + overwrite (ETag staleness handled by upload-hook re-running unconditionally).
6. **Orphan sweep** — Tied to BFS pass tail; piggybacks on enumeration data; bulk-deletes orphaned `.thumbnails/` keys per drive (THUMB-19).
7. **Terminating reconciliation** — Schema V4 adds `thumbnailFailCount: Int = 0`; 3 strikes → `.failed` (excluded from `fetchPendingThumbnails`); reset condition is original-ETag change (THUMB-20).
8. **Rollout switch** — `ThumbnailSettings.enabled` flips on silently for every drive whose `inspectThumbnailPrefix` re-check passes on first v3.1 launch. Persisted; no per-launch re-check after that. No user-visible toggle in Phase 13.

**Critical scope changes to ratify before planning** (see `<scope_changes>` below):
- **THUMB-24 dropped** — no tray progress UI on macOS. The user explicitly chose fully silent end-to-end. Requires updating REQUIREMENTS.md and ROADMAP.md success criterion #5 BEFORE planner generates plans.

**Not in this phase** — iOS generation (Phase 14), `BGProcessingTask` + `ForegroundBackfillDriver` (Phase 14), cellular gating (Phase 14), manual "Generate now" action (Phase 14), iOS Settings progress UI (Phase 14), per-drive Settings/Preferences UI for the toggle (deferred — kill-switch is editing JSON in App Group container).

</domain>

<scope_changes>
## Scope Changes (must be applied before planner runs)

These follow from a deliberate user decision to ship Phase 13 fully silently on macOS:

### Drop THUMB-24 entirely
- **REQUIREMENTS.md** — remove the THUMB-24 row from the v3.1 requirements table; remove the THUMB-24 entry from Phase 13's mapped requirements.
- **ROADMAP.md** — Phase 13 success criterion #5 currently reads "The macOS menu bar tray shows an honest 'Thumbnails: N / M' progress readout per drive while backfill is running, the counter reaches 100% even when the bucket contains permanently unprocessable files (they count as 'N skipped', never leaving the UI stuck at 99% forever), and concurrent thumbnail fetches from Finder never trigger S3 `SlowDown` thanks to the bounded `ThumbnailFetchLimiter`, while every failure path funnels through `NSFileProviderErrorDomain` / `NSCocoaErrorDomain` — never a custom domain". Rewrite to drop the tray-progress and skipped-counter clauses; keep the `ThumbnailFetchLimiter` and error-domain clauses. Suggested replacement: *"Concurrent thumbnail fetches from Finder never trigger S3 `SlowDown` thanks to the bounded `ThumbnailFetchLimiter`, and every failure path funnels through `NSFileProviderErrorDomain` / `NSCocoaErrorDomain` — never a custom domain. Permanently unprocessable items terminate after 3 strikes (silently — no progress UI surfaces them)."*

### Phase 13 mapped requirements after the change
THUMB-06, THUMB-11, THUMB-12, THUMB-13, THUMB-14, THUMB-15, THUMB-17, THUMB-18, THUMB-19, THUMB-20, THUMB-21, THUMB-23 (12 requirements; was 13).

### Why
The user prefers a silent rollout (consistent with the silent first-run UX choice and the Phase 11/12 silent-payload posture). Tray UI invites support questions about a feature that "just works" if left invisible. The 3-strike rule still ships — it has standalone value (caps S3 retries on permanently-broken items) even without a UI consumer.

### Implications for downstream agents
- **Planner**: do NOT generate a plan task for tray progress UI. Do NOT add `MetadataStore.countPendingThumbnails` (Phase 12 D-22 explicitly deferred this; nothing in Phase 13 needs it). Schema V4 still ships (thumbnailFailCount is the standalone reason).
- **First task in plan-phase MUST be the REQUIREMENTS.md + ROADMAP.md edit commit.** Treat this as plan 13-00 or as the opening commit of plan 13-01 — whichever fits the planner's task structure.

</scope_changes>

<decisions>
## Implementation Decisions

### Rollout & Feature Gating

- **D-01:** **Silent auto-on for all eligible drives.** On extension/app launch, iterate drives; for each drive call `inspectThumbnailPrefix`; if state ∈ {.empty, .matchesOurs} set `ThumbnailSettings.enabled = true` and persist via `SharedData.saveThumbnailSettings`. Drives that hit `.conflicting` stay `enabled = false` (no UI surfaces this in Phase 13 — invisible-to-user). No user-visible toggle in Phase 13.
- **D-02:** **Once-per-drive collision re-check.** First time the extension/app launches with v3.1 (i.e., `enabled` field never written for this drive), run `inspectThumbnailPrefix` and persist the verdict. Subsequent launches read `enabled` from `thumbnail-settings.json` without re-checking. Re-check ONLY on drive add/remove (drive-add already runs this check via Phase 11's wizard integration; drive-removal moot). This delivers Phase 12 D-26's intent ("re-check at feature-enable time") without paying ListObjectsV2 per drive on every cold start.
- **D-03:** **Completely silent first-run UX.** No NSUserNotification, no toast, no "What's New" card, no badge. User just notices thumbnails populating in Finder over time. Aligns with the THUMB-24 drop above.
- **D-04:** **Disable = leave existing thumbnails in place.** If a drive ends up with `enabled = false` (collision conflict, future user-toggle in Phase 14), stop generating + stop fetching (`fetchThumbnails` returns nil → default UTType icon). `.thumbnails/` keys are NOT swept on disable. If user re-enables later, existing keys are reused (free re-warm). Reversible, cheapest, matches "don't poison the bucket" principle.
- **D-05:** **Kill-switch via SharedData JSON only.** Power users can disable per-drive by editing `thumbnail-settings.json` in the App Group container. No UI for this in Phase 13. Phase 14 may add a Preferences toggle if the iOS settings UI work motivates symmetry.

### Upload-Time Generation (THUMB-06)

- **D-06:** **Fire-and-forget `Task.detached` in `createItem` / `modifyItem` post-PUT.** Right after the original-file PUT succeeds and the response ETag is in hand, kick off `Task.detached { try? await thumbnailUploader.generateAndUpload(localURL: ..., sourceETag: response.eTag, drive: ..., originalKey: ...) }`. The Task is fully isolated from the createItem/modifyItem completion handler — the file-upload contract returns success before thumbnail work even starts. Errors are logged + the SyncedItem is marked `.failed` (with strike-count incremented) by the uploader's error path. Matches THUMB-06 word-for-word.
- **D-07:** **`ThumbnailUploader` is a separate, simpler type — NOT shared with the coordinator.** New file `DS3Lib/Sources/DS3Lib/Thumbnails/ThumbnailUploader.swift` (struct, not actor — pure pipeline). API:
  ```swift
  public struct ThumbnailUploader: Sendable {
      public init(s3Client: DS3S3Client, metadataStore: MetadataStore)
      #if os(macOS)
      public func generateAndUpload(
          localURL: URL,
          drive: DS3Drive,
          sourceETag: String,
          originalKey: String
      ) async throws
      #endif
  }
  ```
  Renders via `ThumbnailRenderer`, computes `thumbnailKey` via `S3PathUtils.thumbnailKey(forOriginalKey:drivePrefix:)`, single-part PUTs, marks SyncedItem `.uploaded`. This is the ONE caller that already has the local file URL + fresh source ETag — no need for fetch-pending / batching.
  Coordinator covers the BFS/backfill side (fetch-pending → download original → render → put). Two callers, two needs, two types.
- **D-08:** **Pre-filter via `S3PathUtils.isRasterExtension(_:) -> Bool`** (new static helper on `S3PathUtils`, suffix-based, allow-list = jpg/jpeg/png/heic/heif/webp/gif/tiff). Upload-hook checks this BEFORE kicking `ThumbnailUploader`. Non-raster: silently mark SyncedItem `.notApplicable`, return. Avoids paying a render attempt on every PDF/video/archive upload.
- **D-09:** **`ThumbnailUploader` is `#if os(macOS)`-gated** (the public func, not the type — type is cross-platform Sendable so iOS can hold a reference). On iOS the function body is unreachable; iOS path uses the same `S3PathUtils.isRasterExtension` pre-check but skips the render step and marks `.pending` (Phase 14 will fill in the iOS render via `ForegroundBackfillDriver`). Phase 13 only ships the macOS path.
- **D-10:** **Modify cascade is the same code path.** `modifyItem` post-PUT runs the identical fire-and-forget `ThumbnailUploader` flow. New ETag → renderer renders → PUT overwrites existing `.thumbnails/<key>.jpg` with new `x-amz-meta-source-etag`. Stale metadata is clobbered. No HEAD-compare, no staleness detection logic — re-render unconditionally on modify. Justified: `modifyItem` only fires on actual content/metadata changes, so the redundant render rate is bounded by user-actual-edit rate.

### Consume Path (THUMB-11, 12, 13, 14)

- **D-11:** **Cache-first miss → return nil + mark `.pending` in MetadataStore.** `fetchThumbnails` rewrite calls `getThumbnailBytes`. On nil (404): mark `thumbnailStatus = .pending` (idempotent if already pending), return failure (see D-13 for error mapping → Finder draws default icon). Next BFS pass picks it up. No inline-render, no inline-S3-download, no synchronous coordinator nudge. Matches THUMB-23 (no full-file downloads on consume path).
- **D-12:** **`ThumbnailFetchLimiter` is a DS3DriveProvider actor wrapping the `fetchThumbnails` handler.** macOS=4 (THUMB-14). Every `fetchThumbnails` invocation `await`s a slot before doing anything (cache check, S3 GET, error mapping). Inside the limited region, `getThumbnailBytes` does its single S3 GET. **Upload-path generation does NOT pass through the limiter** (different lane, doesn't compete with consume work). **Backfill coordinator has its own concurrency = 1** (sequential per Phase 12 D-31).
- **D-13:** **Error mapping at the File Provider boundary** (consume path only):
  - 404 / `NoSuchKey` → `NSFileProviderError.noSuchItem` (Finder retries on next browse, draws default icon meanwhile)
  - Soto network / 5xx / SlowDown → `NSFileProviderError.serverUnreachable` (Finder retries later)
  - Auth / credential errors → `NSFileProviderError.cannotSynchronize` (drive enters error state, existing error UI surfaces)
  - Renderer-internal errors NEVER cross the boundary (consume path doesn't render; only the coordinator and uploader render, and they keep errors below the seam).
  - Stays inside CLAUDE.md's `NSFileProviderErrorDomain` / `NSCocoaErrorDomain`-only rule.
- **D-14:** **No SlowDown inline retry.** Map directly to `serverUnreachable` and let Finder retry naturally. Holding a limiter slot on retry sleeps would compound the throttling we're trying to avoid.
- **D-15:** **Sync status badges (THUMB-12).** Existing badge rendering (cloud / synced / syncing / error) sits on top of the OS-supplied thumbnail compositing. Phase 13 changes nothing about badge code paths — the rewrite only changes WHERE thumbnail bytes come from. Verification: a folder of cloud-only images shows correct badges + thumbnails simultaneously after a few BFS passes complete the backfill.

### Backfill Orchestration (THUMB-15, 21, 23)

- **D-16:** **One coordinator per drive, owned by `BreadthFirstIndexer`.** Add a `lazy var thumbnailCoordinator: ThumbnailBackfillCoordinator` on the indexer (or whatever extension-side state holder owns BFS). Initialized with `(metadataStore:, s3Client:, drive:)` per Phase 12 D-30. Pause/resume + drive deletion automatically clean up the coordinator (it's tied to the indexer's lifetime).
- **D-17:** **BFS hook fires after every successful BFS pass tail.** At the end of `runOneBFSPass` (after deltas applied, before the next-pass scheduler arms), if `thumbnailSettings.enabled == true && drive.status != .paused`: `try? await thumbnailCoordinator.runBatch(maxItems: 5)`. One invocation per pass. Fire-and-forget at the BFS layer (don't extend BFS pass duration — let coordinator run after pass scheduler arms next pass). Aligns with THUMB-15 "opportunistically during BFS enumeration passes" + THUMB-23 "no eager full-bucket scan".
- **D-18:** **Fixed `maxItems = 5`.** Matches Phase 12 D-31's stated default. Add a constant to `DefaultSettings.Thumbnail`:
  ```swift
  public static let backfillBatchSize = 5
  ```
  Tune-ability for future phases without re-touching the BFS hook. No adaptive-batch logic in Phase 13.
- **D-19:** **Thermal gating: skip when `ProcessInfo.processInfo.thermalState >= .serious`.** Coordinator reads thermalState at the top of `runBatch`; if `.serious` or `.critical`, return `BatchResult(processed: 0, ..., skipped: 0, failed: 0)` without doing any work. No per-item check inside the loop (thermal escalation is rare; reading once per batch suffices).
- **D-20:** **Pause = don't start next batch + cancel in-flight Task at next render boundary.** Coordinator's `runBatch` checks `drive.status == .paused` (a) at function entry, (b) at the start of each item loop iteration. Inside the loop, calls `try Task.checkCancellation()` between phases (download, render, put, persist). On pause mid-batch: complete the current item's already-started PUT (avoid corrupting in-progress upload), then exit. Resume picks up at next BFS pass tail.

### Cascades (THUMB-17, 18)

- **D-21:** **Delete cascade — fire-and-forget Task in `FileProviderExtension+Delete`** after successful original-delete:
  ```swift
  Task.detached { [s3Client, drive, originalKey] in
      let thumbKey = S3PathUtils.thumbnailKey(forOriginalKey: originalKey, drivePrefix: drive.prefix)
      try? await s3Client.deleteThumbnail(bucket: drive.bucket, key: thumbKey)
  }
  ```
  No tracking, no queue, no retry. `deleteThumbnail` is silent on 404 (Phase 12 D-14). Failures fall to orphan sweep. Matches THUMB-17 ordering rule.

- **D-22:** **Rename / move cascade — server-side S3 copy + delete old.** `FileProviderExtension+Modify` (rename path) fire-and-forget:
  ```swift
  Task.detached { [s3Client, drive, oldKey, newKey] in
      let oldThumb = S3PathUtils.thumbnailKey(forOriginalKey: oldKey, drivePrefix: drive.prefix)
      let newThumb = S3PathUtils.thumbnailKey(forOriginalKey: newKey, drivePrefix: drive.prefix)
      do {
          try await s3Client.copyThumbnail(bucket: drive.bucket, fromKey: oldThumb, toKey: newThumb)
          try? await s3Client.deleteThumbnail(bucket: drive.bucket, key: oldThumb)
      } catch {
          // copy failed — mark new key .pending, let backfill regenerate
          try? metadataStore.setThumbnailStatus(s3Key: newKey, driveId: drive.id, status: .pending)
      }
  }
  ```
  Server-side copy = no bytes leave S3. If the copy fails, fallback path is mark `.pending` and let backfill re-render from the new original. If copy succeeds + delete fails, orphan sweep cleans up.
- **D-23:** **`copyThumbnail` ships in Phase 13** as a new method on `DS3S3Client+Thumbnails.swift` (Phase 12 didn't ship it; Phase 12 D-15 anticipated this kind of follow-up). Signature:
  ```swift
  public func copyThumbnail(
      bucket: String,
      fromKey: String,
      toKey: String
  ) async throws
  ```
  Implementation: Soto's `S3.copyObject(CopyObjectRequest)` with `metadataDirective: .copy` to preserve `x-amz-meta-source-etag` and `x-amz-meta-ds3drive-thumb-version`. Single-part by definition (server-side). Add to `DS3S3ClientProtocol` for mockability.
- **D-24:** **Move cascade is the same path as rename.** macOS File Provider treats both as `modifyItem` with a parent / filename change → both flow through D-22.

### Orphan Sweep (THUMB-19)

- **D-25:** **Tied to BFS pass tail; piggybacks on enumeration data.** When BFS finishes a pass with the full drive key set in hand (the indexer already builds this set during enumeration), run `S3Lib.listObjectsV2(prefix: <drive.prefix>.thumbnails/, maxKeys: 1000)` for that drive. For each thumbnail key returned, compute the implied original key via `S3PathUtils.originalKey(fromThumbnailKey:drivePrefix:)`. If implied original ∉ enumerated key set: it's an orphan → bulk-delete (max 50 per pass to bound work). Per-drive, no global timer.
- **D-26:** **Sweep cap per pass = 50 orphan deletes.** New `DefaultSettings.Thumbnail.maxOrphanDeletesPerPass = 50`. Prevents a freshly-disabled-then-re-enabled-then-corrupted edge case from issuing 100,000 deletes in one BFS pass. The natural BFS cadence cleans up the rest over subsequent passes.
- **D-27:** **Sweep is gated by `enabled == true`.** A disabled drive doesn't sweep — D-04 says we leave thumbnails alone when disabled.
- **D-28:** **No HEAD method needed.** `copyThumbnail` does its own validation server-side; orphan sweep uses the BFS-enumerated key set as the authority on "does this original exist". Phase 12 D-15's deferred HEAD method stays deferred; no consumer in Phase 13.

### Terminating Reconciliation (THUMB-20)

- **D-29:** **Schema V4 adds `thumbnailFailCount: Int = 0`** on `SyncedItemSchemaV4.SyncedItem`. Lightweight V3 → V4 migration (mirrors V1 → V2 → V3). Coordinator (and uploader, on its own failure path) increments the count on render-or-PUT failure; transitions `thumbnailStatus = .failed` when `count >= 3`.
- **D-30:** **`fetchPendingThumbnails` predicate excludes `.failed`** (already does — `.pending` only). With `.failed` as terminal, the query naturally drains. The 3-strike rule's whole job is to stop these items from re-entering the query forever.
- **D-31:** **Reset condition: original ETag changes.** When BFS observes a SyncedItem whose persisted ETag differs from the freshly-listed ETag (existing reconciliation logic), the upsert path (existing in MetadataStore) resets `thumbnailFailCount = 0` AND `thumbnailStatus = .pending`. This re-arms the file for retry on legitimate change. Document the reset in the upsert call site comments.
- **D-32:** **No timestamp / cooldown tracking.** Retries happen on the natural BFS pass cadence — failed-once items stay `.pending` (with incremented count) and re-eligible immediately. After 3 strikes → `.failed` (terminal until ETag change). Simple, predictable, no time-based predicate.
- **D-33:** **Schema V4 migration test** mirrors the V2→V3 test pattern (Phase 12 D-36): seed a V3 store, open as V4, assert `thumbnailFailCount == 0` on every row.

### Concurrency, Errors, Tests

- **D-34:** **Test strategy: heavy unit tests at component boundaries + minimal integration smoke.** Each new piece (`ThumbnailUploader`, `ThumbnailFetchLimiter`, BFS hook, cascade hooks, orphan sweep, 3-strike logic, Schema V4 migration) gets unit tests with mocked `DS3S3Client` (via existing protocol seam) + mocked / real-but-in-memory `MetadataStore`. Plus 2-3 integration smoke tests in `DS3LibTests` exercising round-trip flows (upload-hook → marked uploaded → fetch → cache hit). No real-S3 integration tests in CI.
- **D-35:** **Renderer errors never cross the File Provider boundary.** Renderer-internal errors (CGImage failures, format rejects) result in `nil` from `ThumbnailRenderer.renderJPEG`, which the uploader / coordinator translates to `thumbnailStatus = .notApplicable` (allow-list reject) or `.failed + count++` (retryable failure). The consume path doesn't render — it only reads `.thumbnails/<key>.jpg` from S3.
- **D-36:** **`ThumbnailFetchLimiter` lives in DS3DriveProvider** (extension-side, not DS3Lib) because it's a UI-pacing concern, not a DS3Lib primitive. New file `DS3DriveProvider/ThumbnailFetchLimiter.swift`. Actor with a slot semaphore.

### Folded Todos
None — `gsd-sdk query todo.match-phase 13` returned 0 matches.

### Claude's Discretion
- Exact file layout under `DS3Lib/Sources/DS3Lib/Thumbnails/` (new files vs. extension files for `ThumbnailUploader`).
- Whether to extract a tiny `ThumbnailRollout` helper from the launch-time auto-on iteration logic (D-01, D-02) or inline it in `FileProviderExtension+Lifecycle`.
- Exact placement of the BFS hook callout (D-17) — at the end of `runOneBFSPass` directly, or via a delegate / callback. Pick whatever is cleanest.
- Whether to share an actor-isolated `OrphanSweeper` type with the coordinator or inline orphan-sweep logic in the BFS hook callout (D-25). Recommend a small dedicated type for testability.
- Whether to add a small `BatchScheduler` actor that owns `runBatch` cadence + thermal gating, or keep that logic inside `ThumbnailBackfillCoordinator.runBatch`. Recommend the latter (smaller surface).
- Naming of the new `S3PathUtils.isRasterExtension(_:)` helper — could also be `S3PathUtils.isRasterFilename(_:)` if the implementation looks at full filename.
- Concurrency primitive inside `ThumbnailFetchLimiter` (counting semaphore, async-channel, or `withTaskGroup` style — pick what reads cleanest in actor land).
- Test file naming and grouping inside `DS3LibTests` and `DS3DriveProviderTests`.

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Project & Milestone Specs
- `.planning/PROJECT.md` — v3.1 Thumbnails milestone definition, out-of-scope list, constraints (macOS 14+ / iOS 17+), no-custom-backend principle.
- `.planning/REQUIREMENTS.md` §v3.1 Requirements → THUMB-06, 11, 12, 13, 14, 15, 17, 18, 19, 20, 21, 23 (Phase 13 scope after THUMB-24 drop). **MUST be edited as plan task #0** to remove THUMB-24.
- `.planning/ROADMAP.md` §"Phase 13: macOS Generation, Consumption & Lifecycle" — goal, success criteria. **Success criterion #5 MUST be rewritten as plan task #0** to drop the tray-progress and skipped-counter clauses (see `<scope_changes>` above).

### Prior Phase Context (load-bearing)
- `.planning/phases/11-foundation-filtering/11-CONTEXT.md` — D-11 (`S3KeyFilter.isUserVisible`), D-13 (S3PathUtils thumbnail helpers), D-15 (append-`.jpg` key rule), D-16/D-17 (DefaultSettings.S3 thumbnail constants), D-19 (full generator hardening — extracted into Phase 12's renderer).
- `.planning/phases/12-renderer-storage-schema/12-CONTEXT.md` — D-08–D-15 (`DS3S3Client+Thumbnails` API: `putThumbnail`, `getThumbnailBytes`, `deleteThumbnail`; required `sourceETag`; metadata headers; silent-on-404 contract), D-22 (`fetchPendingThumbnails(driveId:limit:)`), D-23–D-27 (`SharedData+thumbnailSettings`, default `enabled = false`), D-28–D-33 (`ThumbnailBackfillCoordinator` actor, `runBatch(maxItems:) → BatchResult`, sequential, render-fail policy, original-file download path), `<deferred>` — Phase 13 must implement: cache-first `fetchThumbnails`, upload hook, cascades, orphan sweep, BFS hook, `ThumbnailFetchLimiter`, 3-strike rule. Phase 13 EXTENDS Phase 12 with `copyThumbnail` and Schema V4 (Phase 12 was V3).
- `.planning/phases/12-renderer-storage-schema/12-PLAN.md`, `12-VERIFICATION.md`, `12-VALIDATION.md` — confirm what actually shipped (vs. what CONTEXT promised).

### Milestone Research
- `.planning/research/STACK.md` §"ImageIO — `CGImageSource` thumbnail extraction" — the four mandatory ImageIO flags + memory characteristics (already in renderer); §"Soto v6 range GETs" → "New small API surface needed" — confirms `copyObject` is the right primitive for `copyThumbnail`; §"Platform-Specific Patterns" — drives the `#if os(macOS)` gate on `ThumbnailUploader.generateAndUpload`.
- `.planning/research/PITFALLS.md` §Pitfall 1 (iOS jetsam — motivates the macOS-gate on uploader's render path), §Pitfall 5 (EXIF orientation — preserved by renderer), §Pitfall 13 (autoreleasepool + memory guard — already in renderer), §Pitfall 15 (collision detection — drives D-02's once-per-drive re-check).
- `.planning/research/ARCHITECTURE.md` §"Component Inventory" → DS3Lib row and `DS3DriveProvider` row — Phase 13 adds the most extension-side mass of any phase (limiter, BFS hook, cascade hooks, orphan sweep — all extension-side except `ThumbnailUploader` and `copyThumbnail`).
- `.planning/research/FEATURES.md` — generator, storage, consumer, lifecycle feature rows.

### Existing Code — Phase 11/12 Delivered (the substrate)
- `DS3Lib/Sources/DS3Lib/Thumbnails/ThumbnailRenderer.swift` (Phase 12) — `#if os(macOS)`-gated; `init(maxDimension:jpegQuality:)`, `renderJPEG(from: URL) -> Data?`. Used by `ThumbnailUploader` and the coordinator.
- `DS3Lib/Sources/DS3Lib/Thumbnails/ThumbnailBackfillCoordinator.swift` (Phase 12 scaffold) — `public actor`, `init(metadataStore:s3Client:drive:)`, `runBatch(maxItems:) → BatchResult`. Phase 13 ADDS: thermal-gate at top, pause-check at top + per iteration, `Task.checkCancellation()` between phases, strike-count increment on failure, `.failed` transition at count >= 3. Phase 13 also wires the actual fetch-pending → download original → render → put → mark-uploaded loop (Phase 12 left it as a runnable scaffold; Phase 13 turns it into the real backfill engine).
- `DS3Lib/Sources/DS3Lib/DS3S3Client+Thumbnails.swift` (Phase 12) — `putThumbnail`, `getThumbnailBytes`, `deleteThumbnail`. Phase 13 EXTENDS this file with `copyThumbnail(bucket:fromKey:toKey:)`. Update `DS3S3ClientProtocol` accordingly.
- `DS3Lib/Sources/DS3Lib/Metadata/SyncedItem.swift` (Phase 12 V3) — Phase 13 ADDS `SyncedItemSchemaV4` with `thumbnailFailCount: Int = 0`, lightweight V3→V4 migration, updated `typealias SyncedItem = V4.SyncedItem`.
- `DS3Lib/Sources/DS3Lib/Metadata/MetadataStore+Queries.swift` (Phase 12) — `fetchPendingThumbnails`, `setThumbnailStatus`. Phase 13 may add a `setThumbnailFailure(s3Key:driveId:)` convenience that increments count + transitions to `.failed` if count >= 3 (or callers can do it manually).
- `DS3Lib/Sources/DS3Lib/SharedData/SharedData+thumbnailSettings.swift` (Phase 12) — `loadThumbnailSettings`, `saveThumbnailSettings`. Phase 13 reads on launch (D-01, D-02), writes after collision re-check.
- `DS3Lib/Sources/DS3Lib/DS3S3Client+ThumbnailPrefix.swift` (Phase 11) — `inspectThumbnailPrefix`. Phase 13 calls this in the launch-time auto-on path (D-01).
- `DS3Lib/Sources/DS3Lib/Utils/S3PathUtils.swift` (Phase 11) — `thumbnailKey(forOriginalKey:drivePrefix:)`, `originalKey(fromThumbnailKey:drivePrefix:)`. Phase 13 ADDS a static `isRasterExtension(_:) -> Bool` helper.
- `DS3Lib/Sources/DS3Lib/Utils/S3KeyFilter.swift` (Phase 11) — `isUserVisible(key:drivePrefix:)`. No changes; consume path inherits its filtering.
- `DS3Lib/Sources/DS3Lib/Constants/DefaultSettings.swift` — `DefaultSettings.S3.thumbnailsPrefix` / `thumbnailMaxDimension` / `thumbnailJPEGQuality` (Phase 11), `DefaultSettings.Thumbnail` namespace (Phase 12 D-11). Phase 13 ADDS: `Thumbnail.backfillBatchSize = 5`, `Thumbnail.maxOrphanDeletesPerPass = 50`, `Thumbnail.maxFailStrikes = 3`.

### Existing Code — Extension-Side Touch Points
- `DS3DriveProvider/FileProviderExtension+Create.swift` — `createItem` handler. Phase 13 adds the post-PUT fire-and-forget `ThumbnailUploader` invocation, gated by `S3PathUtils.isRasterExtension`.
- `DS3DriveProvider/FileProviderExtension+Modify.swift` — `modifyItem` handler. Phase 13 adds (a) the same post-PUT uploader for content-change modifies, and (b) the rename/move cascade (`copyThumbnail` + `deleteThumbnail`) for filename / parent changes.
- `DS3DriveProvider/FileProviderExtension+Delete.swift` — `deleteItem` handler. Phase 13 adds the post-delete fire-and-forget `deleteThumbnail` cascade.
- `DS3DriveProvider/FileProviderExtension+Thumbnails.swift:157-249` — current `fetchThumbnails` consumer (download-and-generate-from-original). **Phase 13 rewrites this entirely** to cache-first: call `getThumbnailBytes`, on hit return bytes via the completion handler, on nil mark `.pending` + return `.noSuchItem`, on transient error map to `.serverUnreachable` (D-13). Old generator-based fallback at this site is GONE (Phase 12 already pointed it at the renderer; Phase 13 deletes the fallback path).
- `DS3DriveProvider/FileProviderExtension+Lifecycle.swift` — extension entry point. Phase 13 adds the launch-time rollout: iterate drives, run once-per-drive collision re-check, persist enabled flag (D-01, D-02).
- `DS3DriveProvider/BreadthFirstIndexer.swift` — `runOneBFSPass` (line ~85). Phase 13 adds (a) the coordinator hook at pass tail with thermal-gating + pause-check (D-17, D-19, D-20), and (b) the orphan-sweep callout using the enumerated key set (D-25, D-26).
- `DS3DriveProvider/S3Enumerator.swift` — already filters via `S3KeyFilter.isUserVisible` (Phase 11). No changes.
- `DS3DriveProvider/S3Lib+Thumbnails.swift` — existing extension wrapper for the old generator path. Likely shrinks or is deleted in Phase 13.
- `DS3DriveProvider/NotificationsManager.swift` — sync-status notifications. Phase 13 does NOT extend this (no thumbnail-status notifications surface — silent UX per D-03).

### File Provider Error Rules (non-negotiable)
- `CLAUDE.md` (repo root) §"File Provider Error Handling" — errors crossing the File Provider boundary MUST be `NSFileProviderErrorDomain` or `NSCocoaErrorDomain`. Phase 13's consume path (D-13) maps strictly into this set. Renderer / S3 / Soto errors stay below the boundary (in DS3Lib or in the upload-hook Task that's logged-and-swallowed).

### Soto v6 Reference
- Soto v6 S3 docs (https://soto.codes/) — `S3.copyObject(CopyObjectRequest)` for `copyThumbnail` (D-23). `metadataDirective: .copy` preserves source metadata.

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- **Phase 12's `ThumbnailRenderer`** is the verbatim render primitive used by both `ThumbnailUploader` (new in Phase 13) and the existing coordinator. No further hardening needed.
- **Phase 12's `DS3S3Client+Thumbnails`** API surface (`put`/`get`/`delete`) covers ~80% of Phase 13's S3 needs. Phase 13 only adds `copyThumbnail`.
- **Phase 12's `ThumbnailBackfillCoordinator` scaffold** is a runnable shell — Phase 13 fills in the per-iteration logic (download original via existing `DS3S3Client+Transfers`, render, put, mark uploaded, increment-or-fail on error). The scaffold's `BatchResult` type is reused as-is.
- **Phase 11's `S3PathUtils.thumbnailKey` / `originalKey`** round-trip is used in cascades and orphan sweep. No changes.
- **Phase 11's `inspectThumbnailPrefix`** is reused for the once-per-drive rollout re-check (D-02).
- **Phase 12's `SharedData+thumbnailSettings`** is the persistence primitive for the rollout flag.
- **Existing `BreadthFirstIndexer.runOneBFSPass`** structure already has a clean tail point where coordinator hook + orphan sweep can be invoked without restructuring BFS internals.
- **Existing `DS3S3Client+Transfers.swift`** has `getObjectToFile` (or equivalent) that the coordinator uses to download originals to a temp URL for rendering.
- **Existing fire-and-forget `Task.detached` pattern** is already used in the codebase (e.g., NotificationsManager, several upload paths) — Phase 13's cascade hooks follow the same posture.

### Established Patterns
- **`#if os(macOS)`-gated whole functions or types** for thumbnail rendering. `ThumbnailRenderer` (Phase 12) uses whole-type gating; `ThumbnailUploader.generateAndUpload` uses whole-function gating. iOS extension build asserts on importing the macOS render path.
- **Fire-and-forget Task.detached for non-user-visible work.** Upload hooks, cascade hooks, BFS-tail coordinator invocation all follow this. Errors logged, never propagated.
- **Sequential coordinator processing.** Phase 12 D-31 + Phase 13 D-12 keep the coordinator at concurrency=1; consume path uses the limiter for parallelism. Two distinct concurrency lanes for two distinct workloads.
- **Schema migration via `MigrationStage.lightweight`.** V1→V2, V2→V3, V3→V4 all use the same additive-field pattern. Phase 13 D-29 adds nothing new to the migration framework.
- **`DS3S3ClientProtocol` mockability.** Every new S3 method (`copyThumbnail` in Phase 13) is added to both the concrete client AND the protocol; tests use canned mocks.

### Integration Points
- **Launch-time rollout (D-01, D-02)** runs in the extension's lifecycle path (`FileProviderExtension+Lifecycle`); also potentially in the main app's launch path if the auto-on logic should also fire when the extension isn't running. Recommend extension-side only — extension is what writes to S3, main-app rollout adds nothing.
- **BFS hook (D-17)** at `BreadthFirstIndexer.runOneBFSPass` tail. Single touchpoint, fires per-pass.
- **Cascade hooks (D-21, D-22)** in `FileProviderExtension+Delete` and `FileProviderExtension+Modify`. Three touchpoints (delete, content-modify, rename/move).
- **Consume path rewrite (D-11, D-12, D-13)** at `FileProviderExtension+Thumbnails.swift:157-249`. One large rewrite of a single function.
- **Orphan sweep (D-25)** at the same BFS pass tail as the coordinator hook. May share state with the BFS-built key set.

### Constraints
- **Swift 6 strict concurrency.** New types (`ThumbnailUploader`, `ThumbnailFetchLimiter`) must be `Sendable` or actor-isolated. `Schema.Version` non-Sendable footgun (per MEMORY.md) applies to `SyncedItemSchemaV4.versionIdentifier` — use `nonisolated static let` exactly as V1/V2/V3 do. CI Xcode 16.2 is stricter than local — verify.
- **macOS 14+ / iOS 17+** baselines. `ProcessInfo.thermalState` available since macOS 10.10.
- **App Group identifier** `group.X889956QSM.io.cubbit.DS3Drive` for `SharedData` JSON access.
- **NEVER return custom error types to File Provider** (MEMORY.md). D-13's mapping is the strict policy.
- **SwiftLint file-length limits** apply — `FileProviderExtension+Thumbnails.swift` was already at the limit pre-Phase-12. Phase 13's rewrite shrinks it (no more inline render fallback) so should fit, but the cascade additions in `+Modify.swift` may need an `+ThumbnailCascade.swift` extract if the file grows.
- **OSLog dynamic strings** require `privacy: .public` per MEMORY.md to be visible.

</code_context>

<specifics>
## Specific Ideas

- **Silent end-to-end on macOS** is the user's deliberate posture, consistent with the Phase 11/12 silent-payload design. Phase 13 ships zero new UI on macOS. Tray progress (THUMB-24) is dropped, not deferred — see `<scope_changes>`.
- **Fire-and-forget is the right primitive** for everything that's not the consume path. Upload hook, cascade hooks, coordinator hook, orphan sweep all use `Task.detached` with `try?` to swallow errors. This protects the user-visible upload contract (THUMB-06) and the user-visible delete/rename contracts (THUMB-17, 18) absolutely. Failures fall to the orphan-sweep + 3-strike-cap backstops.
- **Three concurrency lanes**, distinct on purpose: (1) upload-hook = unbounded fire-and-forget Tasks (rate-limited naturally by upload rate); (2) consume-path = `ThumbnailFetchLimiter` with 4 slots on macOS; (3) backfill coordinator = sequential, one item at a time per drive, thermal-gated, pause-aware. No cross-lane contention.
- **The 3-strike rule has standalone value** even without tray UI. Without it, a permanently-broken file (corrupt JPEG that ImageIO can't decode but isn't filtered by extension allow-list) gets re-tried every BFS pass forever, paying S3 GET cost on every retry. The strike count caps that.
- **Schema V4 is justified for one field** because failure-count is the right place for the strike state — it's per-item, persisted, queried alongside `thumbnailStatus`. Putting it in a sidecar negative-cache JSON would be more code for the same outcome.
- **Phase 13 deliberately does NOT add `MetadataStore.countPendingThumbnails`.** With THUMB-24 dropped, no consumer needs the count. Phase 14 can add it if iOS Settings UI requires it.
- **Re-render on every modifyItem** (D-10) is correct because `modifyItem` only fires on actual file changes — there's no "no-op modify" fan-out risk. The redundant-render rate is bounded by the user-actual-edit rate, which is tiny relative to backfill volume.
- **`copyThumbnail` belongs in Phase 13, not as a Phase 12 follow-up.** Phase 12 is merged; the rename cascade is a Phase 13 concern; adding the method here keeps phase boundaries clean and the change atomic with its consumer.
- **The orphan sweep cap of 50 / pass** is intentionally conservative. The natural BFS cadence cleans up the rest over subsequent passes. If a user has 10,000 orphans (which would be a bug-induced state, not a normal one), they get cleaned up in ~200 passes — still finite.

</specifics>

<deferred>
## Deferred Ideas

- **Tray progress UI on macOS (THUMB-24)** — *dropped from v3.1*, not deferred to a later milestone. See `<scope_changes>`.
- **`MetadataStore.countPendingThumbnails`** — Phase 14 if iOS Settings progress UI needs it; otherwise stays deferred.
- **Per-drive enabled toggle in Preferences UI** — Phase 14 may add for symmetry with iOS Settings UI; Phase 13 ships kill-switch via JSON only.
- **HEAD method on `DS3S3Client`** — still deferred (Phase 12 D-15). No consumer in Phase 13 (orphan sweep uses BFS-enumerated key set; ETag staleness is handled by re-render on modify).
- **Adaptive batch size for backfill** — Phase 14+ if throughput becomes an issue. Phase 13 ships fixed `maxItems = 5`.
- **Exponential backoff between strikes** — not in Phase 13. BFS cadence IS the backoff.
- **Cellular gating + manual "Generate now"** — Phase 14 (iOS-only).
- **iOS `BGProcessingTask` + `ForegroundBackfillDriver`** — Phase 14.
- **iOS Settings progress UI ("123 of 456 thumbnails generated" + force-quit caveat copy)** — Phase 14.
- **Parallel renders inside coordinator** — Phase 14+ when iOS overnight task or macOS settings tuning needs it. Phase 13 ships sequential per Phase 12 D-31.
- **EXIF thumbnail fast-path (range-GET first ~64 KB)** — beyond v3.1.
- **PNG fallback for line-art / screenshots** — beyond v3.1 (JPEG Q0.7 ringing is a known limitation per Phase 11).
- **Video / PDF / RAW thumbnail support** — out of scope per REQUIREMENTS.
- **WebP / AVIF thumbnail format** — beyond v3.1. `DefaultSettings.Thumbnail.formatVersion = 1` is the extension point.
- **Promoting `BucketListingLimiter` → `S3RequestLimiter`** — beyond v3.1.

</deferred>

---

*Phase: 13-macos-generation-consumption-lifecycle*
*Context gathered: 2026-04-25*
