# Roadmap: DS3 Drive

## Milestones

- 🚧 **v1.0 macOS App** - Phases 1-5 (in progress, 95% complete)
- ✅ **v2.0 iOS & iPadOS Universal App** - Phases 6-9 (shipped 2026-03-20)
- ✅ **v3.0 Sharing & Collaboration** - Phase 10 (shipped 2026-04-10)
- 📋 **v3.1 Thumbnails** - Phases 11-14 (planned)

## Phases

<details>
<summary>v1.0 macOS App (Phases 1-5) - IN PROGRESS</summary>

**Phase Numbering:**
- Integer phases (1, 2, 3): Planned milestone work
- Decimal phases (2.1, 2.2): Urgent insertions (marked with INSERTED)

Decimal phases appear between their surrounding integers in numeric order.

- [x] **Phase 1: Foundation** - Rename app, add structured logging, fix extension crashes, set up SwiftData metadata database
- [x] **Phase 2: Sync Engine** - Build metadata-driven sync with remote change detection, deletion tracking, and on-demand file access
- [x] **Phase 3: Conflict Resolution** - Detect version conflicts via ETag comparison and create conflict copies to prevent data loss
- [x] **Phase 4: Auth & Platform** - Update auth flow to current IAM v1 APIs, add multitenancy, auto-manage API keys, make endpoints configurable
- [ ] **Phase 5: UX Polish** - Add Finder sync badges, menu bar status/speed/history, quick actions, and streamlined drive setup wizard

### Phase 1: Foundation
**Goal**: The app has a stable, observable foundation -- no silent crashes, structured logging across all targets, persistent metadata storage shared between main app and extension
**Depends on**: Nothing (first phase)
**Requirements**: FOUN-01, FOUN-02, FOUN-03, FOUN-04, SYNC-07, SYNC-08
**Success Criteria** (what must be TRUE):
  1. App launches as "DS3 Drive" with correct bundle identifiers and branding throughout
  2. Log output in Console.app shows structured entries with categories (sync, auth, transfer, extension) from all three targets
  3. File Provider extension initializes gracefully when shared data is missing or corrupted -- no crashes, errors logged
  4. SwiftData database is accessible from both main app and extension via App Group container, with SyncedItem records persisting across launches
  5. Multipart uploads validate the ETag returned by CompleteMultipartUpload, and S3 errors map to correct NSFileProviderError codes for system retry
**Plans:** 4 plans

Plans:
- [x] 01-01-PLAN.md -- Rename app to DS3 Drive, convert DS3Lib to SPM, update identifiers and CI
- [x] 01-02-PLAN.md -- Add structured OSLog logging with domain categories, fix code quality bugs
- [x] 01-03-PLAN.md -- Fix extension crashes, implement S3 error mapping, add multipart ETag validation
- [x] 01-04-PLAN.md -- Set up SwiftData metadata store, add SwiftLint/SwiftFormat, enable Swift 6 concurrency

### Phase 2: Sync Engine
**Goal**: The File Provider extension reliably detects and reflects remote changes -- new files appear, modified files update, deleted files disappear, and files download on demand when opened
**Depends on**: Phase 1
**Requirements**: SYNC-01, SYNC-04, SYNC-05, SYNC-06
**Success Criteria** (what must be TRUE):
  1. Each synced item in the metadata database tracks S3 key, ETag, LastModified, local hash, sync status, parent key, content type, and size
  2. Files deleted on S3 disappear from Finder within one sync cycle (no ghost files that reappear)
  3. Sync anchor advances after each successful enumeration batch and survives extension restarts
  4. Files appear as cloud placeholders in Finder and download only when the user opens them (on-demand sync)
**Plans:** 3 plans

Plans:
- [x] 02-01-PLAN.md -- Schema V2 migration (isMaterialized + SyncAnchorRecord), MetadataStore ModelActor, exponential backoff, NetworkMonitor
- [x] 02-02-PLAN.md -- SyncEngine actor with full reconciliation logic and TDD test suite
- [x] 02-03-PLAN.md -- Integrate SyncEngine into File Provider extension, CRUD metadata writes, signalEnumerator, on-demand download

### Phase 3: Conflict Resolution
**Goal**: Concurrent edits from multiple devices never cause silent data loss -- conflicts are detected before writes and both versions are preserved as separate files
**Depends on**: Phase 2
**Requirements**: SYNC-02, SYNC-03
**Success Criteria** (what must be TRUE):
  1. Before uploading a modified file, the extension performs a HEAD request to compare the local version against the remote ETag -- mismatches trigger conflict handling instead of blind overwrite
  2. When a conflict is detected, a conflict copy named "filename (Conflict on [device] [date]).ext" appears alongside the original in Finder, preserving both the local and remote versions
**Plans:** 3 plans

Plans:
- [x] 03-01-PLAN.md -- TDD: ConflictNaming utility and ETag normalization with full test coverage
- [x] 03-02-PLAN.md -- Core conflict detection: ETag extraction, pre-flight HEAD checks in modifyItem/createItem/deleteItem, conflict copy upload
- [x] 03-03-PLAN.md -- Conflict notifications: IPC from extension to main app, UNUserNotificationCenter with batching, integration tests

### Phase 4: Auth & Platform
**Goal**: Users can log in with tenant-aware credentials against current Cubbit APIs, with API keys managed automatically and all endpoints derived from configurable coordinator URLs
**Depends on**: Phase 1
**Requirements**: AUTH-01, AUTH-02, AUTH-03, AUTH-04, PLAT-01, PLAT-02, PLAT-03, PLAT-04
**Success Criteria** (what must be TRUE):
  1. User can log in by entering email, password, and tenant -- the app authenticates via IAM v1 challenge-response and discovers the S3 endpoint from Composer Hub automatically
  2. During drive setup, API keys are created and managed without any user interaction -- the user never sees API key details
  3. Token expiration during an active sync session is handled transparently -- the refresh flow completes without interrupting file transfers or showing errors
  4. Users with 2FA enabled can complete login with their second factor
  5. A configurable coordinator URL setting allows pointing the app at a self-hosted DS3 Composer instance, and all API URLs derive from that base
**Plans:** 4 plans

Plans:
- [x] 04-01-PLAN.md -- Refactor CubbitAPIURLs to instance-based class, extend SharedData with tenant/coordinator persistence, add NSFileCoordinator to token files
- [x] 04-02-PLAN.md -- Inject CubbitAPIURLs into DS3Authentication/DS3SDK, add tenant_id to auth requests, proactive token refresh
- [x] 04-03-PLAN.md -- Login UI Advanced section (tenant + coordinator URL), tray menu Connection Info/Sign Out, app-level refresh timer
- [x] 04-04-PLAN.md -- Extension dynamic URLs from SharedData, proactive refresh in extension, S3 403 self-healing with API key recreation

### Phase 5: UX Polish
**Goal**: Users have full visibility into sync state and control over their drives through Finder badges, a rich menu bar experience, and a streamlined setup wizard
**Depends on**: Phase 2, Phase 4
**Requirements**: UX-01, UX-02, UX-03, UX-04, UX-05, UX-06, UX-07
**Success Criteria** (what must be TRUE):
  1. Each file in Finder shows a sync status badge (synced/syncing/error/cloud-only) that updates in real time as sync progresses
  2. The menu bar tray icon shows per-drive sync status with colored indicators (green=synced, blue=syncing, red=error)
  3. The menu bar tray displays real-time upload and download speed while transfers are active
  4. The menu bar tray shows a list of recently synced files
  5. Quick actions in the menu bar (add drive, open in Finder, preferences, pause sync) work correctly
  6. The drive setup wizard guides the user through tenant-aware project and bucket selection in a simplified flow
  7. Users cannot create more than 3 drives
**Plans:** 5 plans (3 executed)

Plans:
- [x] 05-01-PLAN.md -- Design system foundation (colors, typography, spacing, shimmer) and Finder sync badges via NSFileProviderItemDecorating
- [x] 05-02-PLAN.md -- Pause state data layer (SharedData persistence, extension gate) and recent files ring buffer tracker
- [x] 05-03-PLAN.md -- Drive setup wizard 2-step refactor, login centered card redesign, preferences tabbed redesign
- [x] 05-04-PLAN.md -- Menu bar tray overhaul: colored indicators, speed display, side panels, gear menu, tray icon animation
- [x] 05-05-PLAN.md -- Common component design system sweep, copy audit, Italian localization, final human verification

</details>

<details>
<summary>v2.0 iOS & iPadOS Universal App (Phases 6-9) -- SHIPPED 2026-03-20</summary>

- [x] Phase 6: Platform Abstraction (4/4 plans) -- completed 2026-03-18
- [x] Phase 7: iOS File Provider Extension (4/4 plans) -- completed 2026-03-18
- [x] Phase 8: iOS Companion App (6/6 plans) -- completed 2026-03-18
- [x] Phase 9: iOS Polish & Distribution (3/3 plans) -- completed 2026-03-20

See `.planning/milestones/v2.0-ROADMAP.md` for full details.

</details>

## v3.0 Sharing & Collaboration

- [x] **Phase 10: Presigned URL sharing (issue #104)** - Right-click context menu action to generate and copy presigned S3 URLs with three duration presets (completed 2026-04-10)

### Phase 10: Presigned URL sharing (issue #104)
**Goal:** Users can right-click any file in Finder or the iOS Files app and copy a time-limited presigned S3 URL to their clipboard, with three duration presets (1h / 1d / 7d) and a system notification confirming the expiry
**Depends on:** Phase 5, Phase 9
**Requirements**: SHARE-01
**Plans:** 2/2 plans complete

Plans:
- [x] 10-01-PLAN.md -- TDD: DS3S3Client+Presign.swift presignedGetURL method with unit tests
- [x] 10-02-PLAN.md -- Info.plist entries, notification helper, custom action handler, human verification

## v3.1 Thumbnails (issue #109)

Closes GitHub issue #109. Image files in Finder (macOS) and the iOS Files app show real thumbnail previews, backed by a `.thumbnails/` S3 prefix that is transparent to the user. Both macOS and iOS can independently generate thumbnails — no platform is a required peer.

- [ ] **Phase 11: Foundation & Filtering** - DS3Lib primitives, centralized `.thumbnails/` filter, drive-setup collision check, fix latent ImageIO memory bug. Zero user-visible change.
- [ ] **Phase 12: Renderer, Storage & Schema** - `ThumbnailRenderer` (macOS-gated), `ThumbnailS3Service`, Schema V3 with `thumbnailStatus`, `SharedData+thumbnailSettings`, `ThumbnailBackfillCoordinator` scaffolded. Zero user-visible change.
- [ ] **Phase 13: macOS Generation, Consumption & Lifecycle** - Upload-path hook, cache-first `fetchThumbnails` rewrite, delete/rename cascade, BFS backfill, orphan sweep, 3-strike terminating reconciliation. **First user-visible thumbnails — fully silent rollout (no tray UI).**
- [ ] **Phase 14: iOS Generation & Polish** - `BGProcessingTask` + `ForegroundBackfillDriver`, cellular gating, manual "Generate now" action, iOS settings UI with progress + force-quit caveat copy.

### Phase 11: Foundation & Filtering
**Goal**: The `.thumbnails/` S3 prefix becomes a first-class, user-invisible namespace across every list-S3 code path, and drive setup refuses to enable the feature on buckets whose `.thumbnails/` content would collide with ours — all shipped as a silent no-op payload before any byte is written.
**Depends on**: Phase 9 (iOS File Provider extension), Phase 10 (active v3 work)
**Requirements**: THUMB-01, THUMB-02, THUMB-03, THUMB-05
**Success Criteria** (what must be TRUE):
  1. Users browsing any drive in Finder or the iOS Files app never see a `.thumbnails/` folder in any enumeration surface — regular listing, search, changes delta, or BFS indexer — even if `.thumbnails/` objects exist in the bucket
  2. Attempting drive setup against a bucket that already contains non-DS3Drive `.thumbnails/` content is refused with a clear, actionable error message; setup succeeds on clean buckets and on buckets that only contain DS3Drive-generated thumbnails
  3. The `ThumbnailKey` mapping for any original key is unambiguous and collision-free (an `a.jpg` original and an `a.png` original at the same folder map to distinct thumbnail keys because the original extension is appended, not substituted)
  4. All subsequent phases import a single canonical `S3KeyFilter.isUserVisible(key:)` from DS3Lib and a single canonical `DefaultSettings.S3.thumbnailsPrefix` / size / quality constant — no scattered literals, no parallel filters
  5. The latent `kCGImageSourceShouldCache: false` bug in `+ThumbnailGenerators.swift:11` is fixed and covered by regression test, eliminating the v2.0 memory footgun before any new generation code is added on top
**Plans:** 5 plans

Plans:
- [ ] 11-01-PLAN.md -- DS3Lib primitives: DefaultSettings constants, S3PathUtils thumbnail helpers, S3KeyFilter (TDD)
- [ ] 11-02-PLAN.md -- Collision detection: ThumbnailPrefixState enum, inspectThumbnailPrefix function (TDD)
- [ ] 11-03-PLAN.md -- Filter routing: S3Lib+Thumbnails wrapper, ListObjectsV2 call-site audit, all 9 sites filtered
- [ ] 11-04-PLAN.md -- Wizard integration: macOS + iOS conflict warning UI, EN + IT localization
- [ ] 11-05-PLAN.md -- Generator hardening: ImageIO memory safety, format allow-list, Git LFS test fixtures

### Phase 12: Renderer, Storage & Schema
**Goal**: DS3Lib exposes a platform-gated, memory-safe thumbnail renderer, an S3 put/get/delete service with staleness metadata, a Schema V3 migration that tracks per-item thumbnail status, and a scaffolded backfill coordinator — all wired into unit tests but not yet invoked from any user-facing code path.
**Depends on**: Phase 11
**Requirements**: THUMB-04, THUMB-07, THUMB-08, THUMB-09, THUMB-10
**Success Criteria** (what must be TRUE):
  1. The MetadataStore can answer "which items in this drive still need a thumbnail?" and persists per-item thumbnail state (`.notApplicable` / `.pending` / `.uploaded` / `.failed`) across extension and app restarts, with Schema V2→V3 migration succeeding on existing installs
  2. Importing `ThumbnailRenderer` from the iOS File Provider extension target fails to compile — the type is hard-gated with `#if os(macOS)` around every ImageIO / CoreImage call site, making accidental iOS-extension decode unrepresentable
  3. Unit tests on Git LFS fixtures prove the renderer produces right-side-up JPEGs for portrait iPhone photos (EXIF orientation 6 HEIC + JPEG fixtures) and silently returns nil for unsupported formats without throwing
  4. `ThumbnailS3Service.put` writes every thumbnail as a single-part PUT carrying both `x-amz-meta-source-etag` (for stale-thumbnail detection) and `x-amz-meta-ds3drive-thumb-version` (for future format migrations) — verified via mock S3 tests
  5. `SharedData+thumbnailSettings` round-trips the feature-enabled flag across the App Group boundary, and the `ThumbnailBackfillCoordinator` actor exists with a runnable (though unused) batch entry point, ready for Phase 13 to call into
**Plans:** 5 plans

Plans:
- [ ] 12-01-PLAN.md -- Schema V3 + ThumbnailStatus enum + fetchPendingThumbnails/setThumbnailStatus query surface
- [ ] 12-02-PLAN.md -- DefaultSettings.Thumbnail namespace + SharedData+thumbnailSettings 1:1 mirror
- [ ] 12-03-PLAN.md -- DS3S3Client+Thumbnails: putThumbnail/getThumbnailBytes/deleteThumbnail on protocol extension
- [ ] 12-04-PLAN.md -- ThumbnailRenderer extraction (macOS-gated whole type) + test relocation + consumer rewrite
- [ ] 12-05-PLAN.md -- ThumbnailBackfillCoordinator actor scaffold (cross-platform shell, macOS-only render)

### Phase 13: macOS Generation, Consumption & Lifecycle
**Goal**: Finder shows real thumbnails for image files on every macOS drive — instantly for newly uploaded files, opportunistically backfilled for existing content — and the thumbnail lifecycle tracks the original through deletes, renames, moves, and pause/resume without ever breaking the user-visible upload contract or poisoning the system with stuck progress or custom error domains. iOS Files automatically benefits because iOS consumes the same `.thumbnails/` prefix macOS writes.
**Depends on**: Phase 12
**Requirements**: THUMB-06, THUMB-11, THUMB-12, THUMB-13, THUMB-14, THUMB-15, THUMB-17, THUMB-18, THUMB-19, THUMB-20, THUMB-21, THUMB-23 (THUMB-24 dropped 2026-04-25 — fully silent macOS rollout)
**Success Criteria** (what must be TRUE):
  1. A user dragging an image into a DS3 Drive folder in Finder sees the file appear instantly with a real thumbnail (within a few seconds), while a corrupt or unsupported image file uploads successfully with no error and falls back to the default UTType icon — the upload contract is never blocked, broken, or flickered by thumbnail work
  2. A user browsing a folder of cloud-only images uploaded from another device sees thumbnails appear progressively as the macOS extension opportunistically backfills them during BFS enumeration passes, with existing sync status badges (cloud / synced / syncing / error) still rendering correctly on top — and the same folder viewed on iOS Files also shows those thumbnails without the iOS extension ever decoding anything
  3. Deleting, renaming, or moving an image in Finder correctly cascades to its thumbnail within one sync cycle, and a periodic orphan sweep guarantees that `.thumbnails/` entries whose originals have disappeared (due to failed cascades or external bucket edits) are eventually reclaimed
  4. Pausing a drive halts thumbnail backfill for that drive immediately; resuming continues from where it left off; backfill never eager-scans the full bucket on feature launch and never triggers a full-file download on the consumption path
  5. Concurrent thumbnail fetches from Finder never trigger S3 `SlowDown` thanks to the bounded `ThumbnailFetchLimiter`, and every failure path funnels through `NSFileProviderErrorDomain` / `NSCocoaErrorDomain` — never a custom domain. Permanently unprocessable items terminate after 3 strikes (silently — no progress UI surfaces them on macOS).
**Plans:** 11 plans

Plans:
- [ ] 13-01-PLAN.md — Scope-change ratification (drop THUMB-24) + DefaultSettings.Thumbnail constants + S3PathUtils.isRasterExtension
- [ ] 13-02-PLAN.md — ThumbnailUploader (DS3Lib struct, macOS-gated render+PUT pipeline)
- [x] 13-03-PLAN.md — DS3S3Client.copyThumbnail (server-side copy preserving staleness metadata)
- [ ] 13-04-PLAN.md — Schema V4 + thumbnailFailCount + setThumbnailFailure + ETag-reset + uploader retrofit
- [ ] 13-05-PLAN.md — ThumbnailBackfillCoordinator extensions (thermal/pause/cancel/strike integration)
- [ ] 13-06-PLAN.md — ThumbnailFetchLimiter actor + cache-first fetchThumbnails rewrite + error mapping
- [ ] 13-07-PLAN.md — Upload-hook in createItem + modifyItem (content-change branch)
- [ ] 13-08-PLAN.md — Delete + rename/move cascades via +ThumbnailCascade helper
- [ ] 13-09-PLAN.md — BFS pass-tail coordinator hook + OrphanSweeper + 50-cap
- [ ] 13-10-PLAN.md — Silent launch-time rollout (once-per-drive collision re-check, persisted)
- [ ] 13-11-PLAN.md — Phase 13 integration smoke tests + dead-code cleanup audit + human verification
**UI hint**: no

### Phase 13.1: Thumbnail subsystem hardening - Phase 13 audit fixes (INSERTED)

**Goal:** Phase 13 audit fixes — Findings 2, 4, 5, and parent-folder progress propagation, restoring THUMB-13, THUMB-18, THUMB-19 conformance under real-world load
**Requirements**: THUMB-13, THUMB-18, THUMB-19 (no new requirements; bugs violate existing ones)
**Depends on:** Phase 13
**Plans:** 7 plans

Plans:
- [ ] 13.1-01-PLAN.md — Parent-folder progress root-cause spike (Wave 0; D-13)
- [ ] 13.1-02-PLAN.md — OrphanSweeper MetadataStore freshness backstop (Finding 4; D-01..D-05)
- [ ] 13.1-03-PLAN.md — Cascade NoSuchKey demote + log opacity fix (Finding 5; D-06..D-08)
- [ ] 13.1-04-PLAN.md — ThumbnailRenderer eager Data snapshot (Finding 2; D-09..D-12)
- [ ] 13.1-05-PLAN.md — Codebase-wide describeSotoError sweep (Finding 5b; D-06)
- [ ] 13.1-06-PLAN.md — Parent-folder progress propagation fix (depends on 13.1-01 spike)
- [ ] 13.1-07-PLAN.md — Phase 13.1 ship gate (D-18, D-19)

### Phase 13.2: Dropbox-like thumbnail UX (INSERTED)

**Goal:** Replace the BFS-driven thumbnail subsystem with a reactive, Apple-API-driven 3-lane `fetchThumbnails` model (cache hit → fallback render → background backfill PUT), eliminating ~2400 LoC of BFS/coordinator/sweeper machinery while preserving THUMB-15, THUMB-19, THUMB-20, THUMB-21 conformance via reframed semantics.
**Requirements**: THUMB-15, THUMB-19, THUMB-20, THUMB-21 (reframed; no new requirements)
**Depends on:** Phase 13.1
**Plans:** 10 plans

Plans:
- [ ] 13.2-01-PLAN.md — TDD: ThumbnailFallbackLimiter actor (2-slot FIFO + in-memory 3-strike state) — D-02, D-19, D-20
- [ ] 13.2-02-PLAN.md — fetchThumbnails cache-miss fallback fork (consumeThumbnailFallback) — D-01..D-04, D-12, D-24
- [ ] 13.2-03-PLAN.md — Upload-hook post-PUT signalEnumerator + ThumbnailUploadHookContext.domain — D-12
- [ ] 13.2-04-PLAN.md — Memory smoke test (8x50MB HEIC under 50MB peak) — D-17, D-18
- [ ] 13.2-05-PLAN.md — Drop tray .indexing case; collapse to .sync — D-16
- [ ] 13.2-06-PLAN.md — Delete BFS stack (BreadthFirstIndexer + BFSThumbnailHookRunner + callsites) — D-11
- [ ] 13.2-07-PLAN.md — Delete coordinator + sweeper + warmCacheThenStartBFS + runThumbnailRolloutIfNeeded — D-09, D-10, D-25
- [ ] 13.2-08-PLAN.md — Schema V5: drop thumbnailFailCount + setThumbnailFailure + migration test — D-05, D-06, D-07
- [ ] 13.2-09-PLAN.md — Schema V6: drop thumbnailStatus + fetchPendingThumbnails + markPending + migration test — D-05, D-08, D-23
- [ ] 13.2-10-PLAN.md — Phase ship gate: orphan audit + error-domain audit + manual smoke + phase summary

### Phase 14: iOS Generation & Polish
**Goal**: iPhone and iPad users can contribute thumbnails for images uploaded from their iOS devices (and for any bucket content that macOS hasn't already processed) via a foreground-primary backfill driver with an opportunistic `BGProcessingTask` overnight supplement, with clear UI copy about the force-quit caveat and a manual "Generate now" escape valve on both platforms.
**Depends on**: Phase 13
**Requirements**: THUMB-16, THUMB-22, THUMB-25, THUMB-26
**Success Criteria** (what must be TRUE):
  1. While the iOS main app is foregrounded on Wi-Fi, the `ForegroundBackfillDriver` processes pending thumbnails at a rate the user can see in the Settings progress view — without jetsam kills, cellular data usage, or UI stalls — and the same code path runs inside `BGProcessingTask` overnight when the device is charging and idle
  2. A user on cellular sees backfill paused by default with an explicit opt-in toggle; flipping the toggle immediately resumes generation; disabling it immediately suspends generation — both on the current connection and on future cellular connections
  3. A power user on either platform can tap "Generate thumbnails now" in settings and see backfill kick off for the selected drive, with a first-use bandwidth / cost warning that never fires again once acknowledged
  4. iOS Settings shows a user-facing progress readout ("123 of 456 thumbnails generated") together with a plain-English explanation that force-quitting the app disables overnight background generation until next manual launch — closing the single most common "thumbnails are broken" support question from v2.0 iOS
**Plans**: TBD
**UI hint**: yes

## Progress

**Execution Order:**
- v1.0: 1 -> 2 -> 3 -> 4 -> 5
- v2.0: 6 -> 7 -> 8 -> 9
- v3.0: 10
- v3.1: 11 -> 12 -> 13 -> 14

| Phase | Milestone | Plans Complete | Status | Completed |
|-------|-----------|----------------|--------|-----------|
| 1. Foundation | v1.0 | 4/4 | Complete | 2026-03-12 |
| 2. Sync Engine | v1.0 | 3/3 | Complete | 2026-03-12 |
| 3. Conflict Resolution | v1.0 | 3/3 | Complete | - |
| 4. Auth & Platform | v1.0 | 4/4 | Complete | 2026-03-13 |
| 5. UX Polish | v1.0 | 12/14 | In Progress|  |
| 6. Platform Abstraction | v2.0 | 4/4 | Complete | 2026-03-18 |
| 7. iOS File Provider Extension | v2.0 | 4/4 | Complete | 2026-03-18 |
| 8. iOS Companion App | v2.0 | 6/6 | Complete | 2026-03-18 |
| 9. iOS Polish & Distribution | v2.0 | 3/3 | Complete | 2026-03-20 |
| 10. Presigned URL sharing | v3.0 | 2/2 | Complete    | 2026-04-11 |
| 11. Foundation & Filtering | v3.1 | 0/5 | In Progress | - |
| 12. Renderer, Storage & Schema | v3.1 | 0/0 | Not started | - |
| 13. macOS Generation, Consumption & Lifecycle | v3.1 | 0/0 | Not started | - |
| 14. iOS Generation & Polish | v3.1 | 0/0 | Not started | - |

---
*Roadmap created: 2026-03-11*
*v2.0 milestone added: 2026-03-17*
*v2.0 milestone shipped: 2026-03-20*
*v3.0 milestone added: 2026-04-09*
*v3.1 Thumbnails milestone added: 2026-04-11*
