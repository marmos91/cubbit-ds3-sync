# Roadmap: DS3 Drive

## Milestones

- 🚧 **v1.0 macOS App** - Phases 1-5 (in progress, 95% complete)
- 📋 **v2.0 iOS & iPadOS Universal App** - Phases 6-9 (planned)

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
- [ ] 01-03-PLAN.md -- Fix extension crashes, implement S3 error mapping, add multipart ETag validation
- [ ] 01-04-PLAN.md -- Set up SwiftData metadata store, add SwiftLint/SwiftFormat, enable Swift 6 concurrency

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
**Plans:** 3/5 plans executed

Plans:
- [ ] 05-01-PLAN.md -- Design system foundation (colors, typography, spacing, shimmer) and Finder sync badges via NSFileProviderItemDecorating
- [ ] 05-02-PLAN.md -- Pause state data layer (SharedData persistence, extension gate) and recent files ring buffer tracker
- [ ] 05-03-PLAN.md -- Drive setup wizard 2-step refactor, login centered card redesign, preferences tabbed redesign
- [ ] 05-04-PLAN.md -- Menu bar tray overhaul: colored indicators, speed display, side panels, gear menu, tray icon animation
- [ ] 05-05-PLAN.md -- Common component design system sweep, copy audit, Italian localization, final human verification

</details>

## v2.0 iOS & iPadOS Universal App (Phases 6-9)

**Milestone Goal:** DS3 Drive works on iPhone and iPad with the same reliability as macOS -- users can log in, set up drives, and access their S3 files through the native Files app

- [ ] **Phase 6: Platform Abstraction** - Extract macOS-specific APIs behind protocols so DS3Lib and the extension compile for iOS with zero regressions on macOS
- [ ] **Phase 7: iOS File Provider Extension** - Multi-platform extension target that compiles, loads, and syncs files on iOS within memory and background execution constraints
- [x] **Phase 8: iOS Companion App** - iOS/iPadOS app with login, drive setup, sync dashboard, and preferences -- users manage drives here, browse files in Files app (completed 2026-03-18)
- [ ] **Phase 9: iOS Polish & Distribution** - Share Extension for uploading from other apps, sync badges in Files app, and CI pipeline for iOS builds

## Phase Details

### Phase 6: Platform Abstraction
**Goal**: DS3Lib and the File Provider extension compile for both macOS and iOS, with platform-specific behavior hidden behind protocol abstractions -- macOS continues to work identically
**Depends on**: Phase 5 (v1.0 complete)
**Requirements**: ABST-01, ABST-02, ABST-03, ABST-04
**Success Criteria** (what must be TRUE):
  1. DS3Lib builds successfully for both macOS and iOS targets with no compilation errors
  2. The existing macOS app and extension continue to function identically after all abstraction changes -- no regressions in sync, auth, or IPC
  3. Platform-specific code (DistributedNotificationCenter, SMAppService, NSWorkspace, Host.current()) is reachable only through protocol abstractions, not called directly anywhere in shared code
  4. An iOS implementation of IPC (Darwin notifications + App Group file payloads) can send and receive messages between two processes in a unit test
**Plans:** 4 plans

Plans:
- [x] 06-01-PLAN.md -- IPCService protocol, macOS/iOS implementations, DarwinNotificationCenter wrapper, unit tests
- [x] 06-02-PLAN.md -- SystemService and LifecycleService protocols, guard macOS-only imports, fix SwiftUI->Observation
- [ ] 06-03-PLAN.md -- Wire IPCService/SystemService into consumers, update Package.swift for iOS, add CI build step
- [ ] 06-04-PLAN.md -- Full automated verification suite and manual macOS regression smoke test

### Phase 7: iOS File Provider Extension
**Goal**: The File Provider extension runs on iOS, loads in the Files app, and can enumerate, download, and upload files against S3 within iOS resource constraints
**Depends on**: Phase 6
**Requirements**: IEXT-01, IEXT-02, IEXT-03, IEXT-04
**Success Criteria** (what must be TRUE):
  1. The File Provider extension loads in the iOS Files app and enumerates S3 bucket contents as browsable folders and files
  2. A user can open (download) a file from Files app on iOS and the content matches what is stored in S3
  3. A user can create, rename, move, and delete files through Files app on iOS with changes reflected in S3
  4. The extension stays under the 20MB memory limit during upload/download of files larger than 50MB (streaming I/O, no full-file buffering)
  5. Remote changes are detected during enumeration without background polling -- no periodic timers running in the extension on iOS
**Plans:** 4 plans

Plans:
- [x] 07-00-PLAN.md -- Wave 0: test stub scaffolds for StreamingIO, CacheTTL, and PlatformConditional test suites
- [x] 07-01-PLAN.md -- Streaming I/O fixes (zero-copy ByteBuffer writes, streaming uploads), memory logging, platform-adaptive fetch semaphore
- [x] 07-02-PLAN.md -- Platform guards for polling/BFS (#if os(macOS)), cache-first + 60s TTL enumeration (both platforms)
- [x] 07-03-PLAN.md -- Stub iOS app target, multi-platform extension configuration, iOS entitlements, CI iOS Simulator build

### Phase 8: iOS Companion App
**Goal**: Users can log in, create drives, and monitor sync status on iPhone and iPad -- the companion app is a dashboard for drive management, not a file browser
**Depends on**: Phase 7
**Requirements**: IAPP-01, IAPP-02, IAPP-03, IAPP-04, IAPP-05, IAPP-06
**Success Criteria** (what must be TRUE):
  1. A user can log in on iOS with email, password, and tenant using the same auth flow as macOS, including 2FA
  2. A user can create a new drive by selecting project, bucket, and prefix -- the drive then appears in the Files app as a browsable location
  3. The iOS dashboard shows per-drive sync status (synced/syncing/error) and transfer speed that updates in real time via Darwin notification IPC
  4. A user can manage preferences (view account info, clear cache, log out) from the iOS settings screen
  5. On iPad, the app adapts to Split View and Stage Manager with a NavigationSplitView sidebar layout
**Plans:** 6/6 plans complete

Plans:
- [x] 08-01-PLAN.md -- iOS design system (colors, typography, spacing, button styles), app entry point, adaptive layout skeleton, orientation lock
- [x] 08-02-PLAN.md -- iOS login view with email/password/2FA, inline errors, iPad card layout, Advanced section
- [x] 08-03-PLAN.md -- Dashboard: drive list, drive cards with real-time IPC status, drive detail, empty state
- [x] 08-04-PLAN.md -- Drive setup wizard: project/bucket/prefix drill-down, searchable lists, drive confirm and creation
- [x] 08-05-PLAN.md -- Settings screen (account/general/about), Background App Refresh, cache management, signalEnumerator fix
- [x] 08-06-PLAN.md -- Xcode project integration (add files to pbxproj), accent color asset, build verification, human verify

### Phase 9: iOS Polish & Distribution
**Goal**: The iOS app is production-ready with share sheet integration, visual sync feedback in Files app, and automated CI builds
**Depends on**: Phase 8
**Requirements**: IPOL-01, IPOL-02, IPOL-03
**Success Criteria** (what must be TRUE):
  1. A user can share a file from any iOS app (Photos, Safari, etc.) to a DS3 drive via the system share sheet, and the file appears in the selected drive's S3 bucket
  2. Files in the iOS Files app show sync status decorations (synced/syncing/error badges) matching the macOS Finder badge behavior
  3. The GitHub Actions CI pipeline builds and tests both macOS and iOS targets on every push and PR, with iOS simulator tests passing
**Plans:** 3 plans

Plans:
- [x] 09-01-PLAN.md -- Fix sync badge decoration identifiers, add Cubbit logo to iOS login, apply smooth animations
- [ ] 09-02-PLAN.md -- Share Extension target foundation: UIViewController host, upload view model, root SwiftUI view, entitlements
- [ ] 09-03-PLAN.md -- Share Extension polished UI views (drive/folder picker, progress, unauthenticated), URL scheme, CI pipeline update

## Progress

**Execution Order:**
- v1.0: 1 -> 2 -> 3 -> 4 -> 5
- v2.0: 6 -> 7 -> 8 -> 9

| Phase | Milestone | Plans Complete | Status | Completed |
|-------|-----------|----------------|--------|-----------|
| 1. Foundation | v1.0 | 4/4 | Complete | 2026-03-12 |
| 2. Sync Engine | v1.0 | 3/3 | Complete | 2026-03-12 |
| 3. Conflict Resolution | v1.0 | 3/3 | Complete | - |
| 4. Auth & Platform | v1.0 | 4/4 | Complete | 2026-03-13 |
| 5. UX Polish | v1.0 | 3/5 | In Progress | - |
| 6. Platform Abstraction | v2.0 | 2/4 | In Progress | - |
| 7. iOS File Provider Extension | v2.0 | 4/4 | Complete | 2026-03-18 |
| 8. iOS Companion App | v2.0 | 6/6 | Complete | 2026-03-18 |
| 9. iOS Polish & Distribution | v2.0 | 1/3 | In Progress | - |

---
*Roadmap created: 2026-03-11*
*v2.0 milestone added: 2026-03-17*
