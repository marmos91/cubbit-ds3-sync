# Phase 13: macOS Generation, Consumption & Lifecycle - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-04-25
**Phase:** 13 — macOS Generation, Consumption & Lifecycle
**Areas discussed:** Rollout & feature gating, Upload + consume hooks, Backfill orchestration, Lifecycle + tray UI

---

## Gray Area Selection

| Option | Description | Selected |
|--------|-------------|----------|
| Rollout & feature gating | How does ThumbnailSettings.enabled flip on for macOS users | ✓ |
| Upload + consume hooks | Where does inline generation fire post-upload + cache miss policy | ✓ |
| Backfill orchestration | BFS hook cadence + batch size + thermal/pause | ✓ |
| Lifecycle + tray UI | Cascades + orphan sweep + 3-strike + tray progress | ✓ |

**Note:** User selected ALL four areas (full discussion).

---

## Rollout & Feature Gating

### Q1: How does ThumbnailSettings.enabled flip on for macOS users in Phase 13?

| Option | Description | Selected |
|--------|-------------|----------|
| Silent auto-on, all drives (Recommended) | inspectThumbnailPrefix re-check on launch; auto-enable on .empty / .matchesOurs | ✓ |
| Auto-on + Settings toggle to disable | Same auto-on plus per-drive Preferences toggle | |
| Explicit per-drive opt-in via wizard | First-open-drive prompt | |
| Auto-on, no settings UI, kill switch via SharedData JSON only | Power-user JSON-edit kill switch | |

**User's choice:** Silent auto-on, all drives (Recommended)
**Notes:** Matches the Phase 11/12 silent-payload posture.

### Q2: When does Phase 13 call inspectThumbnailPrefix to gate auto-on?

| Option | Description | Selected |
|--------|-------------|----------|
| Once per drive on first launch after v3.1 install (Recommended) | Persist verdict; re-check only on drive add/remove | ✓ |
| Every extension launch | One ListObjectsV2/drive on cold start | |
| Lazy — first time we'd actually generate | Defer until upload/BFS path triggers | |
| Skip re-check — trust Phase 11 wizard | Cheapest but breaks Phase 12 D-26 contract | |

**User's choice:** Once per drive on first launch after v3.1 install (Recommended)

### Q3: First-run UX when thumbnails start appearing for the first time?

| Option | Description | Selected |
|--------|-------------|----------|
| Completely silent (Recommended) | Just notice them appearing | ✓ |
| One-time NotificationCenter toast per drive | NSUserNotification on first backfill kickoff | |
| Tutorial / onboarding card | Card on next app launch | |
| Tray menu badge + tooltip only | Subtle ambient signal | |

**User's choice:** Completely silent (Recommended)

### Q4: If a drive ends up disabled, what happens to existing thumbnails?

| Option | Description | Selected |
|--------|-------------|----------|
| Leave them (Recommended) | Stop generating + fetching; keys stay in S3 | ✓ |
| Sweep all `.thumbnails/` for that drive on disable | Reclaim storage, O(N) deletes | |
| Leave them but mark stale on re-enable | Force orphan sweep + ETag re-check on re-enable | |

**User's choice:** Leave them (Recommended)

---

## Upload + Consume Hooks

### Q1: Where does inline thumbnail generation fire after a successful image upload?

| Option | Description | Selected |
|--------|-------------|----------|
| Fire-and-forget Task in createItem/modifyItem post-PUT (Recommended) | Task.detached, isolated from upload contract | ✓ |
| Dedicated UploadThumbnailHook observer | Event-bus pattern | |
| Mark .pending + let backfill coordinator pick up next pass | Worst UX — no immediate thumbnail | |
| Synchronous — thumbnail PUT before createItem returns | Violates upload contract | |

**User's choice:** Fire-and-forget Task in createItem/modifyItem post-PUT (Recommended)

### Q2: Should upload-time generation share coordinator's logic, or be separate?

| Option | Description | Selected |
|--------|-------------|----------|
| Separate simpler path — own type 'ThumbnailUploader' (Recommended) | Pure pipeline struct; coordinator stays for backfill | ✓ |
| Share via coordinator — mark .pending + nudge runBatch with current item | Single code path | |
| Extend coordinator API to accept a pre-resolved local URL | Single type, two entry points | |

**User's choice:** Separate simpler path — own type 'ThumbnailUploader' (Recommended)

### Q3: fetchThumbnails behavior on cache miss?

| Option | Description | Selected |
|--------|-------------|----------|
| Return nil + mark .pending in MetadataStore (Recommended) | Honest fast fallback | ✓ |
| Return nil + actively kick coordinator to render this item now | Faster but expensive | |
| Inline-render IF original is already locally materialized | Save S3 GET when possible | |
| Synchronous full download + render + put | Defeats THUMB-23 | |

**User's choice:** Return nil + mark .pending in MetadataStore (Recommended)

### Q4: ThumbnailFetchLimiter placement?

| Option | Description | Selected |
|--------|-------------|----------|
| Wrapping fetchThumbnails handler in the extension (Recommended) | Actor in DS3DriveProvider gates entry to consume path | ✓ |
| Inside DS3S3Client+Thumbnails.getThumbnailBytes itself | Couples network primitive to UI pacing | |
| Both — outer limit + inner per-S3-client limit | Defense in depth | |

**User's choice:** "Choose the best" — interpreted as the recommended option (Wrapping fetchThumbnails in the extension)

---

## Backfill Orchestration

### Q1: When does runBatch get invoked from BreadthFirstIndexer?

| Option | Description | Selected |
|--------|-------------|----------|
| After every successful BFS pass tail (Recommended) | One coordinator call per pass | ✓ |
| Every Nth BFS pass | Counter-based throttle | |
| Only when enumerator visited folders containing pending images | Folder-level targeting | |
| Independent timer (every X minutes) | Decoupled from BFS | |

**User's choice:** After every successful BFS pass tail (Recommended)

### Q2: Per-pass batch budget?

| Option | Description | Selected |
|--------|-------------|----------|
| Fixed maxItems=5 per pass (Recommended) | Match Phase 12 D-31 default | ✓ |
| Higher fixed (e.g., 20) | 4x throughput | |
| Adaptive based on prior pass duration | Auto-tune | |
| Adaptive based on remaining pending count | Drain large drives faster | |

**User's choice:** "You choose best" — interpreted as the recommended option (Fixed maxItems=5)

### Q3: Thermal-state gating?

| Option | Description | Selected |
|--------|-------------|----------|
| Skip when thermal >= .serious (Recommended) | nominal/fair = run, serious/critical = skip | ✓ |
| Skip when thermal >= .fair | More conservative | |
| Never gate | Trust short-lived extension | |
| Skip only on .critical | Most permissive | |

**User's choice:** Skip when thermal >= .serious (Recommended)

### Q4: Pause/resume integration?

| Option | Description | Selected |
|--------|-------------|----------|
| Don't start next batch + cancel in-flight Task at next render boundary (Recommended) | Cooperative cancellation | ✓ |
| Don't start next batch — in-flight runs to completion | Simpler | |
| Hard cancel in-flight Task immediately | Most responsive | |

**User's choice:** Don't start next batch + cancel in-flight Task at next render boundary (Recommended)

---

## Lifecycle + Tray UI

### Q1: Delete cascade timing (THUMB-17)?

| Option | Description | Selected |
|--------|-------------|----------|
| Fire-and-forget Task in FileProviderExtension+Delete after original-delete succeeds (Recommended) | Idempotent, orphan-sweep backstops | ✓ |
| Queue + coordinator-managed cascade list | Persistent across restarts | |
| Synchronous — delete original AND thumbnail before deleteItem returns | Violates ordering principle | |

**User's choice:** Fire-and-forget Task in FileProviderExtension+Delete (Recommended)

### Q2: Rename / move cascade (THUMB-18)?

| Option | Description | Selected |
|--------|-------------|----------|
| Server-side S3 copy old→new, then delete old (Recommended) | No bytes leave S3; preserve thumbnail | ✓ |
| Mark new key as .pending + delete old | Re-render on next BFS pass | |
| Server-side copy only (no delete of old) | Orphan sweep cleans up later | |

**User's choice:** Server-side S3 copy old→new, then delete old (Recommended)

### Q3: Orphan sweep cadence?

| Option | Description | Selected |
|--------|-------------|----------|
| Tied to BFS pass tail, piggyback on enumeration data (Recommended) | Per-drive, no separate timer | ✓ |
| Independent daily timer, per-drive, ListObjectsV2-based | Adds HEAD requirement | |
| On-demand only — user explicitly triggers | Conservative but unacceptable | |
| Hybrid — BFS-tail piggyback + opportunistic monthly deeper sweep | Over-engineered | |

**User's choice:** Tied to BFS pass tail, piggyback on enumeration data (Recommended)

### Q4: 3-strike storage approach (THUMB-20)?

| Option | Description | Selected |
|--------|-------------|----------|
| Add thumbnailFailCount: Int field to SyncedItem (Schema V4) (Recommended) | Persistent, queryable | ✓ |
| Repurpose ThumbnailStatus.failed as terminal (no count) | 1-strike + ETag re-trigger | |
| In-memory counter on coordinator | Volatile across launches | |
| Separate negative cache file (App Group JSON) | Two sources of truth | |

**User's choice:** Add thumbnailFailCount: Int field to SyncedItem (Schema V4) (Recommended)

### Q5: Tray progress UI placement (THUMB-24)?

| Option | Description | Selected |
|--------|-------------|----------|
| Per-drive row, inline below sync status (Recommended) | Honest signal in TrayDriveRowView | |
| Drive submenu/disclosure item | Hidden under expand | |
| Aggregate app-level | One progress for all drives | |
| Notification badge only | No text | |

**User's choice:** "I wouldn't surface it at all" — DEVIATES from THUMB-24 / success criterion #5.

### Q5b: How to square the THUMB-24 conflict?

| Option | Description | Selected |
|--------|-------------|----------|
| Drop THUMB-24 + criterion #5 entirely — fully silent on macOS (Recommended) | Edit REQUIREMENTS.md + ROADMAP.md before plan | ✓ |
| Keep THUMB-24, ship the tiniest possible signal (tooltip only) | Hidden but exists | |
| Defer THUMB-24 to Phase 14 alongside iOS Settings progress UI | Move to Phase 14 | |
| Revisit: keep tray UI per option 1 | Reconsider | |

**User's choice:** Drop THUMB-24 + criterion #5 entirely (Recommended)
**Notes:** Significant scope change. CONTEXT.md `<scope_changes>` block flags this as a planner pre-condition — first task in plan-phase must be the REQUIREMENTS.md + ROADMAP.md edit.

### Q6: ETag staleness handling (modifyItem)?

| Option | Description | Selected |
|--------|-------------|----------|
| modifyItem upload-hook always re-runs ThumbnailUploader (Recommended) | Re-render unconditionally | ✓ |
| Detect staleness lazily during fetchThumbnails (HEAD compare) | Adds HEAD method requirement | |
| Periodic staleness sweep alongside orphan sweep | Bundled with sweep | |
| Accept staleness — modify cascades only on rename | Probably wrong | |

**User's choice:** modifyItem upload-hook always re-runs ThumbnailUploader (Recommended)

### Q7: Where does copyThumbnail land?

| Option | Description | Selected |
|--------|-------------|----------|
| Add copyThumbnail to DS3S3Client+Thumbnails as part of Phase 13 (Recommended) | Atomic with consumer | ✓ |
| Backport to Phase 12 as a small follow-up commit | Cleanly closes Phase 12 surface | |
| Avoid copyThumbnail entirely — re-render path on rename | Reverts D-22 | |

**User's choice:** Add copyThumbnail to DS3S3Client+Thumbnails as part of Phase 13 (Recommended)

### Q8: Coordinator instance lifecycle?

| Option | Description | Selected |
|--------|-------------|----------|
| One coordinator per drive, owned by the BFS indexer (Recommended) | Matches Phase 12 D-30 | ✓ |
| Single shared coordinator with internal driveId routing | Now-pointless (no aggregate UI) | |
| One per drive but pooled | Same as (1) effectively | |

**User's choice:** One coordinator per drive, owned by the BFS indexer (Recommended)

### Q9: Retry/backoff between strikes?

| Option | Description | Selected |
|--------|-------------|----------|
| Next BFS pass with no per-item delay (Recommended) | BFS cadence IS the backoff | ✓ |
| Exponential per-item backoff (1m, 5m, 30m) | Track lastAttemptedAt timestamp | |
| Strike counter resets after N successful items | Self-healing | |

**User's choice:** Next BFS pass with no per-item delay (Recommended)

### Q10: S3 SlowDown / 503 handling on consume?

| Option | Description | Selected |
|--------|-------------|----------|
| Wrap as NSFileProviderError.serverUnreachable + let Finder retry naturally (Recommended) | Honest, low-cost | ✓ |
| Inline retry with exponential backoff (3 attempts) inside fetchThumbnails | Holds limiter slot too long | |
| Inline retry once, then map to error | Common middle-ground | |

**User's choice:** Wrap as NSFileProviderError.serverUnreachable (Recommended)

### Q11: Format / classification on upload-path?

| Option | Description | Selected |
|--------|-------------|----------|
| Reuse the renderer's CGImageSourceGetType allow-list — cheap pre-check on file extension only (Recommended) | Single source of truth | ✓ |
| Try-and-fail — uploader always kicks renderer | Wasteful | |
| Content-type sniffing via UTType | More accurate, more imports | |

**User's choice:** Reuse the renderer's allow-list via S3PathUtils.isRasterExtension (Recommended)

### Q12: Test strategy?

| Option | Description | Selected |
|--------|-------------|----------|
| Heavy unit tests at component boundaries + minimal integration smoke (Recommended) | Mocked DS3S3Client + real schema | ✓ |
| Integration-heavy — spin up MinIO or LocalStack | CI dependency, slower runs | |
| Behavior-driven — Snapshot-style tests for user flows | Heavyweight rigging | |

**User's choice:** Heavy unit tests at component boundaries + minimal integration smoke (Recommended)

### Q13: File Provider error mapping policy?

| Option | Description | Selected |
|--------|-------------|----------|
| Map to .noSuchItem on miss/404; .serverUnreachable on transient; .cannotSynchronize on auth/config (Recommended) | Three buckets, never custom domain | ✓ |
| Always map to .noSuchItem | Hides legitimate problems | |
| Always map to .serverUnreachable | Triggers wrong sync-issues UI | |

**User's choice:** Map to .noSuchItem / .serverUnreachable / .cannotSynchronize buckets (Recommended)

---

## Claude's Discretion

The user accepted recommended defaults for several questions ("you choose best"):
- ThumbnailFetchLimiter placement (Q4 of upload+consume)
- Per-pass batch budget (Q2 of backfill)

These were locked to the (Recommended) option in each case.

## Deferred Ideas

- Tray progress UI (THUMB-24) — DROPPED from v3.1 (not deferred) per user decision.
- countPendingThumbnails query — Phase 14 if iOS Settings UI needs it.
- Per-drive Preferences toggle — Phase 14 for symmetry with iOS.
- HEAD method on DS3S3Client — still deferred (Phase 12 D-15); no consumer in Phase 13.
- Adaptive batch size — Phase 14+.
- Exponential backoff — not in Phase 13.
- Cellular gating, manual "Generate now", BGProcessingTask, ForegroundBackfillDriver, iOS Settings UI — Phase 14.
- Parallel renders inside coordinator — Phase 14+.
- EXIF thumbnail fast-path, PNG fallback, video/PDF/RAW, WebP/AVIF — beyond v3.1.
