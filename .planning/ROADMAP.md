# Roadmap: DS3 Drive

## Overview

DS3 Drive is a brownfield macOS sync app that needs its foundation stabilized before features can be reliably added. The roadmap follows a correctness-first approach: fix crashes and add persistent metadata tracking (Phase 1), build a reliable sync engine on that foundation (Phase 2), add conflict resolution to prevent data loss (Phase 3), update authentication and platform APIs to current specs (Phase 4), then surface everything to users through polished UI (Phase 5). Each phase delivers a verifiable capability that the next phase depends on.

## Phases

**Phase Numbering:**
- Integer phases (1, 2, 3): Planned milestone work
- Decimal phases (2.1, 2.2): Urgent insertions (marked with INSERTED)

Decimal phases appear between their surrounding integers in numeric order.

- [ ] **Phase 1: Foundation** - Rename app, add structured logging, fix extension crashes, set up SwiftData metadata database
- [ ] **Phase 2: Sync Engine** - Build metadata-driven sync with remote change detection, deletion tracking, and on-demand file access
- [ ] **Phase 3: Conflict Resolution** - Detect version conflicts via ETag comparison and create conflict copies to prevent data loss
- [ ] **Phase 4: Auth & Platform** - Update auth flow to current IAM v1 APIs, add multitenancy, auto-manage API keys, make endpoints configurable
- [ ] **Phase 5: UX Polish** - Add Finder sync badges, menu bar status/speed/history, quick actions, and streamlined drive setup wizard

## Phase Details

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
- [ ] 03-03-PLAN.md -- Conflict notifications: IPC from extension to main app, UNUserNotificationCenter with batching, integration tests

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
**Plans**: TBD

Plans:
- [ ] 04-01: TBD
- [ ] 04-02: TBD

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
**Plans**: TBD

Plans:
- [ ] 05-01: TBD
- [ ] 05-02: TBD
- [ ] 05-03: TBD

## Progress

**Execution Order:**
Phases execute in numeric order: 1 -> 2 -> 3 -> 4 -> 5
Note: Phase 4 depends only on Phase 1 and could theoretically run in parallel with Phases 2-3, but serial execution is recommended for a solo developer.

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 1. Foundation | 4/4 | Complete | 2026-03-12 |
| 2. Sync Engine | 3/3 | Complete | 2026-03-12 |
| 3. Conflict Resolution | 2/3 | In Progress | - |
| 4. Auth & Platform | 0/2 | Not started | - |
| 5. UX Polish | 0/3 | Not started | - |

---
*Roadmap created: 2026-03-11*
*Last updated: 2026-03-12 (Phase 3: 2/3 plans complete)*
