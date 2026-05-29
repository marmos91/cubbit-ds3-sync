# Roadmap: DS3 Drive

## Milestones

- 🚧 **v1.0 macOS App** - Phases 1-5 (in progress, 95% complete)
- ✅ **v2.0 iOS & iPadOS Universal App** - Phases 6-9 (shipped 2026-03-20)
- ✅ **v3.0 Sharing & Collaboration** - Phase 10 (shipped 2026-04-10)
- 📋 **v3.1 Thumbnails** - Phases 11-14 (planned)
- 📋 **v2.0.0 Cross-Platform Rewrite** - Phases 15-18 (planned)

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

<details>
<summary>v3.0 Sharing & Collaboration (Phase 10) -- SHIPPED 2026-04-10</summary>

- [x] **Phase 10: Presigned URL sharing (issue #104)** - Right-click context menu action to generate and copy presigned S3 URLs with three duration presets (completed 2026-04-10)

### Phase 10: Presigned URL sharing (issue #104)

**Goal:** Users can right-click any file in Finder or the iOS Files app and copy a time-limited presigned S3 URL to their clipboard, with three duration presets (1h / 1d / 7d) and a system notification confirming the expiry
**Depends on:** Phase 5, Phase 9
**Requirements**: SHARE-01
**Plans:** 2/2 plans complete

Plans:

- [x] 10-01-PLAN.md -- TDD: DS3S3Client+Presign.swift presignedGetURL method with unit tests
- [x] 10-02-PLAN.md -- Info.plist entries, notification helper, custom action handler, human verification

</details>

<details>
<summary>v3.1 Thumbnails (Phases 11-14) -- PLANNED</summary>

Closes GitHub issue #109. Image files in Finder (macOS) and the iOS Files app show real thumbnail previews, backed by a `.thumbnails/` S3 prefix that is transparent to the user. Both macOS and iOS can independently generate thumbnails -- no platform is a required peer.

- [ ] **Phase 11: Foundation & Filtering** - DS3Lib primitives, centralized `.thumbnails/` filter, drive-setup collision check, fix latent ImageIO memory bug. Zero user-visible change.
- [ ] **Phase 12: Renderer, Storage & Schema** - `ThumbnailRenderer` (macOS-gated), `ThumbnailS3Service`, Schema V3 with `thumbnailStatus`, `SharedData+thumbnailSettings`, `ThumbnailBackfillCoordinator` scaffolded. Zero user-visible change.
- [ ] **Phase 13: macOS Generation, Consumption & Lifecycle** - Upload-path hook, cache-first `fetchThumbnails` rewrite, delete/rename cascade, BFS backfill, orphan sweep, 3-strike terminating reconciliation. **First user-visible thumbnails -- fully silent rollout (no tray UI).**
- [ ] **Phase 14: iOS Generation & Polish** - `BGProcessingTask` + `ForegroundBackfillDriver`, cellular gating, manual "Generate now" action, iOS settings UI with progress + force-quit caveat copy.

### Phase 11: Foundation & Filtering

**Goal**: The `.thumbnails/` S3 prefix becomes a first-class, user-invisible namespace across every list-S3 code path, and drive setup refuses to enable the feature on buckets whose `.thumbnails/` content would collide with ours -- all shipped as a silent no-op payload before any byte is written.
**Depends on**: Phase 9 (iOS File Provider extension), Phase 10 (active v3 work)
**Requirements**: THUMB-01, THUMB-02, THUMB-03, THUMB-05
**Success Criteria** (what must be TRUE):

  1. Users browsing any drive in Finder or the iOS Files app never see a `.thumbnails/` folder in any enumeration surface -- regular listing, search, changes delta, or BFS indexer -- even if `.thumbnails/` objects exist in the bucket
  2. Attempting drive setup against a bucket that already contains non-DS3Drive `.thumbnails/` content is refused with a clear, actionable error message; setup succeeds on clean buckets and on buckets that only contain DS3Drive-generated thumbnails
  3. The `ThumbnailKey` mapping for any original key is unambiguous and collision-free (an `a.jpg` original and an `a.png` original at the same folder map to distinct thumbnail keys because the original extension is appended, not substituted)
  4. All subsequent phases import a single canonical `S3KeyFilter.isUserVisible(key:)` from DS3Lib and a single canonical `DefaultSettings.S3.thumbnailsPrefix` / size / quality constant -- no scattered literals, no parallel filters
  5. The latent `kCGImageSourceShouldCache: false` bug in `+ThumbnailGenerators.swift:11` is fixed and covered by regression test, eliminating the v2.0 memory footgun before any new generation code is added on top

**Plans:** 5 plans

Plans:

- [ ] 11-01-PLAN.md -- DS3Lib primitives: DefaultSettings constants, S3PathUtils thumbnail helpers, S3KeyFilter (TDD)
- [ ] 11-02-PLAN.md -- Collision detection: ThumbnailPrefixState enum, inspectThumbnailPrefix function (TDD)
- [ ] 11-03-PLAN.md -- Filter routing: S3Lib+Thumbnails wrapper, ListObjectsV2 call-site audit, all 9 sites filtered
- [ ] 11-04-PLAN.md -- Wizard integration: macOS + iOS conflict warning UI, EN + IT localization
- [ ] 11-05-PLAN.md -- Generator hardening: ImageIO memory safety, format allow-list, Git LFS test fixtures

### Phase 12: Renderer, Storage & Schema

**Goal**: DS3Lib exposes a platform-gated, memory-safe thumbnail renderer, an S3 put/get/delete service with staleness metadata, a Schema V3 migration that tracks per-item thumbnail status, and a scaffolded backfill coordinator -- all wired into unit tests but not yet invoked from any user-facing code path.
**Depends on**: Phase 11
**Requirements**: THUMB-04, THUMB-07, THUMB-08, THUMB-09, THUMB-10
**Success Criteria** (what must be TRUE):

  1. The MetadataStore can answer "which items in this drive still need a thumbnail?" and persists per-item thumbnail state (`.notApplicable` / `.pending` / `.uploaded` / `.failed`) across extension and app restarts, with Schema V2->V3 migration succeeding on existing installs
  2. Importing `ThumbnailRenderer` from the iOS File Provider extension target fails to compile -- the type is hard-gated with `#if os(macOS)` around every ImageIO / CoreImage call site, making accidental iOS-extension decode unrepresentable
  3. Unit tests on Git LFS fixtures prove the renderer produces right-side-up JPEGs for portrait iPhone photos (EXIF orientation 6 HEIC + JPEG fixtures) and silently returns nil for unsupported formats without throwing
  4. `ThumbnailS3Service.put` writes every thumbnail as a single-part PUT carrying both `x-amz-meta-source-etag` (for stale-thumbnail detection) and `x-amz-meta-ds3drive-thumb-version` (for future format migrations) -- verified via mock S3 tests
  5. `SharedData+thumbnailSettings` round-trips the feature-enabled flag across the App Group boundary, and the `ThumbnailBackfillCoordinator` actor exists with a runnable (though unused) batch entry point, ready for Phase 13 to call into

**Plans:** 5 plans

Plans:

- [ ] 12-01-PLAN.md -- Schema V3 + ThumbnailStatus enum + fetchPendingThumbnails/setThumbnailStatus query surface
- [ ] 12-02-PLAN.md -- DefaultSettings.Thumbnail namespace + SharedData+thumbnailSettings 1:1 mirror
- [ ] 12-03-PLAN.md -- DS3S3Client+Thumbnails: putThumbnail/getThumbnailBytes/deleteThumbnail on protocol extension
- [ ] 12-04-PLAN.md -- ThumbnailRenderer extraction (macOS-gated whole type) + test relocation + consumer rewrite
- [ ] 12-05-PLAN.md -- ThumbnailBackfillCoordinator actor scaffold (cross-platform shell, macOS-only render)

### Phase 13: macOS Generation, Consumption & Lifecycle

**Goal**: Finder shows real thumbnails for image files on every macOS drive -- instantly for newly uploaded files, opportunistically backfilled for existing content -- and the thumbnail lifecycle tracks the original through deletes, renames, moves, and pause/resume without ever breaking the user-visible upload contract or poisoning the system with stuck progress or custom error domains. iOS Files automatically benefits because iOS consumes the same `.thumbnails/` prefix macOS writes.
**Depends on**: Phase 12
**Requirements**: THUMB-06, THUMB-11, THUMB-12, THUMB-13, THUMB-14, THUMB-15, THUMB-17, THUMB-18, THUMB-19, THUMB-20, THUMB-21, THUMB-23
**Success Criteria** (what must be TRUE):

  1. A user dragging an image into a DS3 Drive folder in Finder sees the file appear instantly with a real thumbnail (within a few seconds), while a corrupt or unsupported image file uploads successfully with no error and falls back to the default UTType icon -- the upload contract is never blocked, broken, or flickered by thumbnail work
  2. A user browsing a folder of cloud-only images uploaded from another device sees thumbnails appear progressively as the macOS extension opportunistically backfills them during BFS enumeration passes, with existing sync status badges (cloud / synced / syncing / error) still rendering correctly on top -- and the same folder viewed on iOS Files also shows those thumbnails without the iOS extension ever decoding anything
  3. Deleting, renaming, or moving an image in Finder correctly cascades to its thumbnail within one sync cycle, and a periodic orphan sweep guarantees that `.thumbnails/` entries whose originals have disappeared (due to failed cascades or external bucket edits) are eventually reclaimed
  4. Pausing a drive halts thumbnail backfill for that drive immediately; resuming continues from where it left off; backfill never eager-scans the full bucket on feature launch and never triggers a full-file download on the consumption path
  5. Concurrent thumbnail fetches from Finder never trigger S3 `SlowDown` thanks to the bounded `ThumbnailFetchLimiter`, and every failure path funnels through `NSFileProviderErrorDomain` / `NSCocoaErrorDomain` -- never a custom domain. Permanently unprocessable items terminate after 3 strikes (silently -- no progress UI surfaces them on macOS).

**Plans:** 11 plans

Plans:

- [ ] 13-01-PLAN.md -- Scope-change ratification (drop THUMB-24) + DefaultSettings.Thumbnail constants + S3PathUtils.isRasterExtension
- [ ] 13-02-PLAN.md -- ThumbnailUploader (DS3Lib struct, macOS-gated render+PUT pipeline)
- [x] 13-03-PLAN.md -- DS3S3Client.copyThumbnail (server-side copy preserving staleness metadata)
- [ ] 13-04-PLAN.md -- Schema V4 + thumbnailFailCount + setThumbnailFailure + ETag-reset + uploader retrofit
- [ ] 13-05-PLAN.md -- ThumbnailBackfillCoordinator extensions (thermal/pause/cancel/strike integration)
- [ ] 13-06-PLAN.md -- ThumbnailFetchLimiter actor + cache-first fetchThumbnails rewrite + error mapping
- [ ] 13-07-PLAN.md -- Upload-hook in createItem + modifyItem (content-change branch)
- [ ] 13-08-PLAN.md -- Delete + rename/move cascades via +ThumbnailCascade helper
- [ ] 13-09-PLAN.md -- BFS pass-tail coordinator hook + OrphanSweeper + 50-cap
- [ ] 13-10-PLAN.md -- Silent launch-time rollout (once-per-drive collision re-check, persisted)
- [ ] 13-11-PLAN.md -- Phase 13 integration smoke tests + dead-code cleanup audit + human verification

### Phase 14: iOS Generation & Polish

**Goal**: iPhone and iPad users can contribute thumbnails for images uploaded from their iOS devices (and for any bucket content that macOS hasn't already processed) via a foreground-primary backfill driver with an opportunistic `BGProcessingTask` overnight supplement, with clear UI copy about the force-quit caveat and a manual "Generate now" escape valve on both platforms.
**Depends on**: Phase 13
**Requirements**: THUMB-16, THUMB-22, THUMB-25, THUMB-26
**Success Criteria** (what must be TRUE):

  1. While the iOS main app is foregrounded on Wi-Fi, the `ForegroundBackfillDriver` processes pending thumbnails at a rate the user can see in the Settings progress view -- without jetsam kills, cellular data usage, or UI stalls -- and the same code path runs inside `BGProcessingTask` overnight when the device is charging and idle
  2. A user on cellular sees backfill paused by default with an explicit opt-in toggle; flipping the toggle immediately resumes generation; disabling it immediately suspends generation -- both on the current connection and on future cellular connections
  3. A power user on either platform can tap "Generate thumbnails now" in settings and see backfill kick off for the selected drive, with a first-use bandwidth / cost warning that never fires again once acknowledged
  4. iOS Settings shows a user-facing progress readout ("123 of 456 thumbnails generated") together with a plain-English explanation that force-quitting the app disables overnight background generation until next manual launch -- closing the single most common "thumbnails are broken" support question from v2.0 iOS

**Plans**: TBD
**UI hint**: yes

</details>

## v2.0.0 Cross-Platform Rewrite (Phases 15-18)

**Milestone Goal:** Add a shared Rust core and a Windows native shell. Incrementally swap Apple DS3Lib internals to use Rust via UniFFI. Windows is the first new platform target.

**Design spec:** `docs/superpowers/specs/2026-05-26-cross-platform-rewrite-design.md`
**GitHub tracking issue:** #175

- [x] **Phase 15: Rust Core + FFI Foundation** - Cargo workspace with 6 crates, UniFFI Swift XCFramework, csbindgen C# bindings, integration tests against real Cubbit S3 (completed 2026-05-27)
- [ ] **Phase 16: Apple Incremental Swap** - Replace DS3S3Client, DS3Authentication, DS3SDK internals with Rust via UniFFI; remove Soto and CryptoKit from DS3Lib
- [ ] **Phase 17: Windows Shell** - WinUI 3 tray app with cfapi Cloud Filter integration, Explorer sidebar, on-demand hydration, upload, remote sync, MSI installer
- [ ] **Phase 18: Polish + Beta Hardening** - Cross-FFI logging, error mapping, DPAPI credentials, multi-drive, auto-update, ARM64 Windows, tray flyout, conflict resolution

### Phase 15: Rust Core + FFI Foundation

**Goal**: A working Rust core library with proven FFI to both Swift (UniFFI XCFramework) and C# (csbindgen P/Invoke) -- all FFI patterns established, integration tests passing against real Cubbit S3, before any app-level code depends on it
**Depends on**: Nothing (first phase of milestone)
**Requirements**: CORE-01, CORE-02, CORE-03, CORE-04, CORE-05, CORE-06, CORE-07, CORE-08, CORE-09, CORE-10
**Success Criteria** (what must be TRUE):

  1. A Swift test harness can call `DS3Session.authenticate()` with real Cubbit credentials via UniFFI, receive a valid JWT, and then call `listObjects()` / `uploadObject()` / `downloadObject()` against a real Cubbit S3 endpoint -- proving the full auth + S3 path works end-to-end through the XCFramework
  2. A C# console app can call `ds3_authenticate()` + `ds3_list_objects()` via the generated P/Invoke bindings against the same Cubbit endpoint -- proving the csbindgen path works end-to-end with correct UTF-8 string marshalling and handle lifecycle
  3. Multipart uploads (>5MB) initiated from either FFI surface complete with correct ETag validation and invoke progress callbacks that the caller can observe (percentage, bytes transferred)
  4. The `ds3-sync` crate computes a correct diff between a remote S3 tree snapshot and a local tree snapshot, generating create/update/delete/conflict actions including deterministic conflict key names -- verified by unit tests with known tree fixtures
  5. Panic in any Rust function does not crash the calling process -- UniFFI catches panics on the Swift path, and every `extern "C" fn` wraps its body in `catch_unwind` returning an error code on the C# path

**Plans**: 7 plans

Plans:
**Wave 1**

- [x] 15-01-PLAN.md -- Mono-repo restructure: move Apple code to apple/, scaffold windows/, update CI paths
- [x] 15-02-PLAN.md -- Cargo workspace with 6 crates, ds3-models crate with all domain types

**Wave 2** *(blocked on Wave 1 completion)*

- [x] 15-03-PLAN.md -- ds3-http (SharedHttpClient, URLs, projects, keys) + ds3-auth (crypto, challenge, login, refresh, session)
- [x] 15-04-PLAN.md -- ds3-s3 crate (S3 CRUD, multipart uploads, .ds3keep markers)

**Wave 3** *(blocked on Wave 2 completion)*

- [x] 15-05-PLAN.md -- ds3-sync crate TDD (diff computation, conflict key generation)

**Wave 4** *(blocked on Wave 3 completion)*

- [x] 15-06-PLAN.md -- ds3-ffi crate (UniFFI exports, C exports, panic guards, csbindgen, XCFramework script)

**Wave 5** *(blocked on Wave 4 completion)*

- [x] 15-07-PLAN.md -- Integration tests (Rust + Swift harness + C# harness), panic safety, CI finalization

### Phase 16: Apple Incremental Swap

**Goal**: Existing macOS and iOS apps function identically to users, but all S3 operations and authentication flow through the Rust core via UniFFI -- Soto and CryptoKit are removed from DS3Lib, and the FileProvider extension is untouched
**Depends on**: Phase 15
**Requirements**: APPLE-01, APPLE-02, APPLE-03, APPLE-04, APPLE-05, APPLE-06
**Success Criteria** (what must be TRUE):

  1. User can log in on macOS and iOS with the same credentials as before -- the challenge-response flow, 2FA, and token refresh all work identically from the user's perspective, now backed by Rust `ds3-auth` via UniFFI
  2. All existing unit tests (156+) pass without modification, and Finder/Files.app sync behavior (upload, download, rename, move, delete, conflict copy) is identical to the pre-swap build -- verified by side-by-side manual smoke test
  3. Soto and CryptoKit no longer appear in DS3Lib's Package.swift dependencies -- the only S3 client dependency is the `DS3CoreFFI` XCFramework
  4. Existing `drives.json` and `credentials.json` files in the App Group container are read transparently by the Rust-backed code without any migration step -- a user upgrading from the Swift-only build experiences zero data loss or re-login

**Plans:** 6/7 plans executed

Plans:
**Wave 1**

- [x] 16-01-PLAN.md -- XCFramework wiring (SPM .binaryTarget + Xcode Run Script Phase + CI prebuild) + FFI assumption audit (A1/A2/A10)

**Wave 2** *(blocked on Wave 1)*

- [x] 16-02-PLAN.md -- Close 7 Rust FFI gaps (download_to_memory, upload_from_memory, presign_upload_part, current_session, copy_object metadata, CancellationHandle, ds3_error_code) + reqwest retry middleware

**Wave 3** *(blocked on Wave 2)*

- [x] 16-03-PLAN.md -- DS3S3Client + DS3S3Error swap + FileProvider extension catch-block migration (30+ sites)

**Wave 4** *(blocked on Wave 3)*

- [x] 16-04-PLAN.md -- DS3Authentication + DS3SDK internals swap with @Observable shell preserved + 2FA path verbatim (D-15)

**Wave 5** *(blocked on Wave 4)*

- [x] 16-05-PLAN.md -- Remove Soto + CryptoKit from Package.swift; replace SyncAnchorHash CryptoKit->CommonCrypto with fixture-locked SHA256

**Wave 6** *(blocked on Wave 5 -- shares Package.swift)*

- [x] 16-06-PLAN.md -- CI parity gate: JSON fixtures + Rust serde tests + Swift Codable tests + cargo --tests in CI

**Wave 7** *(blocked on Waves 5 + 6)*

- [ ] 16-07-PLAN.md -- Side-by-side smoke test + Rust-backed integration tests (real Cubbit S3) + CI integration job

### Phase 17: Windows Shell

**Goal**: Windows users can log in, set up drives, and sync files with Cubbit DS3 through native Explorer integration -- files appear in the Explorer sidebar, hydrate on demand, upload on save, and reflect remote changes via periodic polling
**Depends on**: Phase 15
**Requirements**: WIN-01, WIN-02, WIN-03, WIN-04, WIN-05, WIN-06, WIN-07, WIN-08, WIN-09
**Success Criteria** (what must be TRUE):

  1. User can log in via a native WinUI 3 form (email, password, tenant, optional 2FA) with credentials stored securely via DPAPI -- never plaintext in config files
  2. User can set up a drive by selecting project, bucket, and prefix through a wizard, and the drive appears as a named entry in the Explorer navigation pane sidebar with a Cubbit icon
  3. User can double-click a cloud-only file in Explorer and it hydrates on demand with a progress bar visible in Explorer's status column, streaming data in chunks to avoid the cfapi 30-second timeout
  4. User can save or create files in the synced folder and they upload to S3 automatically (triggered by `NOTIFY_FILE_CLOSE_COMPLETION`, not `ReadDirectoryChangesW` -- no spurious re-upload on hydration)
  5. Remote changes made from another device or the web console appear as updated placeholders within one polling cycle, and the system tray icon reflects sync status (idle/syncing/error)

**Plans:** 10/12 plans executed
**UI hint**: yes

Plans:
**Wave 0**

- [x] 17-01-PLAN.md -- Rust C ABI gap closure (download_to_memory, presign_get, delete_objects, get_challenge, ds3_error_code, cancellation, ds3_set_log_callback) + tracing-to-C log_bridge.rs + Windows DLL build scripts
- [x] 17-02-PLAN.md -- Solution scaffold (DS3Drive.sln, App/Sync/Core/Tests projects), central package management, DS3Core.Build.targets cargo invocation, NuGet legitimacy checkpoint for Vanara + H.NotifyIcon
- [x] 17-03-PLAN.md -- CI windows-build.yml + xunit.runner.json (parallelizeAssembly=false) + CubbitCredentials fixture + manual-smoke-D-33.md checklist
- [x] 17-04-PLAN.md -- Sparse identity package manifest (Cubbit.DS3Drive, AllowExternalContent, runFullTrust, cfapi extension) + build-sparse.ps1 (MakeAppx + SignTool)

**Wave 1**

- [x] 17-05-PLAN.md -- DS3Drive.Core P/Invoke facade (DS3Native csbindgen-style bindings, DS3Session : IDisposable, Exceptions w/ 1007 to TwoFactorRequired per D-15, Records, CredentialStore via Advapi32 CredWrite/Read, ConfigStore)
- [x] 17-06-PLAN.md -- SyncDatabase (Microsoft.Data.Sqlite at %LOCALAPPDATA%) + 001_initial.sql (5 tables) + PlaceholderStore CRUD + EnumerationDiff port of Apple algorithm + schema-recovery
- [x] 17-07-PLAN.md -- POL-01 logging bridge: RustLogBridge (Channel+drainer, Pitfall 5 compliant) + RustCoreEventSource (Cubbit-DS3Drive-Core ETW) + AppEventSource (Cubbit-DS3Drive-App)

**Wave 2**

- [x] 17-08-PLAN.md -- App shell: DI host, Mica MainWindow, Tokens.xaml (UI-SPEC Rev1+2+3: 4 sizes 12/14/24/32, 2 weights Regular/SemiBold, spacing 4/8/16/24/32/48), Figtree fonts, BrandPrimaryButton, Login + 2FA + Tutorial pages, SingleInstanceService (named Mutex per-user SID)
- [x] 17-09-PLAN.md -- Drive setup wizard (Project to Bucket to Prefix to Confirm), DS3SdkService (API-key reconciliation byte-for-byte port of DS3SDK.swift), DriveManagementService (persistence triple PATTERNS section 3.3), DrivesListPage with 3-drive cap (D-23)

**Wave 3**

- [x] 17-10-PLAN.md -- cfapi sync engine: SyncRootRegistration (sparse identity required, Pitfall 1), CallbackTable (FETCH_DATA streaming 4KB-aligned, NOTIFY_FILE_CLOSE_COMPLETION with IsDirty guard Pitfall 3, NOTIFY_RENAME, NOTIFY_DELETE), SyncEngine (60s polling D-18, ds3_compute_diff per D-17), DriveStatusBroadcaster (verbatim port of NotificationsManager.swift), PathValidation, SemaphoreSlim(20,20) per PATTERNS section 3.5
- [ ] 17-11-PLAN.md -- Tray + flyout: H.NotifyIcon TaskbarIcon with state-swap, Acrylic 360x540 TrayFlyoutWindow, TrayDriveRow (IsHitTestVisible=False discipline per project memory), StatusPill 5 variants, TransferSpeedLabel, RecentFilesService, SettingsPage 4 sections

**Wave 4**

- [ ] 17-12-PLAN.md -- WiX v4 MSI installer: Product.wxs with NTFS guard (Pitfall 8), MajorUpgrade (Pitfall 7), Add-AppxPackage custom action (Pitfall 1), HKCU Run key (D-26), build-msi.ps1, windows-release.yml tag-triggered, final D-33 smoke checklist sign-off

### Phase 18: Polish + Beta Hardening

**Goal**: Both Apple and Windows platforms are release-quality -- structured cross-platform logging, correct error surfaces, multi-drive support, auto-update, and a production installer that enterprise IT can deploy silently
**Depends on**: Phase 16, Phase 17
**Requirements**: POL-01, POL-02, POL-03, POL-04, POL-05, POL-06, POL-07, POL-08
**Success Criteria** (what must be TRUE):

  1. Rust `tracing` events appear in macOS Console.app (via `os_log` bridge with correct subsystem/category) and in Windows Event Viewer (via ETW) -- a developer can filter logs by subsystem on both platforms using native OS tools
  2. Errors originating in Rust surface correctly on each platform: as `NSFileProviderErrorDomain` codes on Apple (so the system retries or shows the right Finder badge) and as typed C# exceptions on Windows (so the tray can show actionable toast notifications)
  3. User can manage up to 3 drives on Windows with independent sync roots in Explorer, each with its own sidebar entry, sync status, and pause/resume control in the tray flyout -- matching the macOS multi-drive experience
  4. Windows tray flyout shows an activity center with per-drive sync status, recent files, pause/resume toggle, and settings -- matching the macOS menu bar tray feature set
  5. The WiX MSI installer supports silent install (`/qn`), auto-starts the app on login, and an ARM64 Windows build is included in the release matrix for Snapdragon X laptops

**Plans**: TBD
**UI hint**: yes

## Progress

**Execution Order:**

- v1.0: 1 -> 2 -> 3 -> 4 -> 5
- v2.0: 6 -> 7 -> 8 -> 9
- v3.0: 10
- v3.1: 11 -> 12 -> 13 -> 14
- v2.0.0: 15 -> 16 + 17 (parallel) -> 18

| Phase | Milestone | Plans Complete | Status | Completed |
|-------|-----------|----------------|--------|-----------|
| 1. Foundation | v1.0 | 4/4 | Complete | 2026-03-12 |
| 2. Sync Engine | v1.0 | 3/3 | Complete | 2026-03-12 |
| 3. Conflict Resolution | v1.0 | 3/3 | Complete | - |
| 4. Auth & Platform | v1.0 | 4/4 | Complete | 2026-03-13 |
| 5. UX Polish | v1.0 | 12/14 | In Progress | - |
| 6. Platform Abstraction | v2.0 | 4/4 | Complete | 2026-03-18 |
| 7. iOS File Provider Extension | v2.0 | 4/4 | Complete | 2026-03-18 |
| 8. iOS Companion App | v2.0 | 6/6 | Complete | 2026-03-18 |
| 9. iOS Polish & Distribution | v2.0 | 3/3 | Complete | 2026-03-20 |
| 10. Presigned URL sharing | v3.0 | 2/2 | Complete | 2026-04-11 |
| 11. Foundation & Filtering | v3.1 | 0/5 | In Progress | - |
| 12. Renderer, Storage & Schema | v3.1 | 0/0 | Not started | - |
| 13. macOS Generation, Consumption & Lifecycle | v3.1 | 0/0 | Not started | - |
| 14. iOS Generation & Polish | v3.1 | 0/0 | Not started | - |
| 15. Rust Core + FFI Foundation | v2.0.0 | 7/7 | Complete   | 2026-05-27 |
| 16. Apple Incremental Swap | v2.0.0 | 6/7 | In Progress|  |
| 17. Windows Shell | v2.0.0 | 10/12 | In Progress|  |
| 18. Polish + Beta Hardening | v2.0.0 | 0/0 | Not started | - |

---
*Roadmap created: 2026-03-11*
*v2.0 milestone added: 2026-03-17*
*v2.0 milestone shipped: 2026-03-20*
*v3.0 milestone added: 2026-04-09*
*v3.1 Thumbnails milestone added: 2026-04-11*
*v2.0.0 Cross-Platform Rewrite milestone added: 2026-05-26*
*Phase 15 planned: 2026-05-27 (7 plans, 4 waves)*
