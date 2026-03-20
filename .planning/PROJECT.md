# DS3 Drive

## What This Is

DS3 Drive is a native macOS, iOS, and iPadOS sync application for Cubbit DS3 distributed cloud storage. It integrates with Finder (macOS) and Files app (iOS/iPadOS) via Apple's File Provider framework to present S3 buckets as native drives with on-demand sync. Users log in, set up drives, and files sync transparently -- similar to Dropbox or Google Drive, but backed by Cubbit's geo-distributed, sovereign storage platform.

## Core Value

Files sync reliably and transparently between the user's Mac, iPhone, iPad and Cubbit DS3, with zero friction -- login, API key management, and S3 configuration happen under the hood so the experience feels like Dropbox.

## Requirements

### Validated

- ✓ File Provider extension syncs files with S3 backend — v1.0
- ✓ Challenge-response authentication (Curve25519/ED25519) with tenant support — v1.0
- ✓ Multipart upload for large files (>5MB) with ETag validation — v1.0
- ✓ Menu bar tray icon with per-drive sync status, speed, recent files, quick actions — v1.0
- ✓ Drive setup wizard (project -> bucket -> prefix selection) — v1.0
- ✓ 2FA support — v1.0
- ✓ Multiple drives (up to 3) — v1.0
- ✓ Conflict detection via ETag comparison and conflict copies — v1.0
- ✓ Remote deletion tracking and on-demand sync — v1.0
- ✓ Configurable coordinator URL and multitenancy — v1.0
- ✓ Structured OSLog logging across all targets — v1.0
- ✓ Finder sync badges (synced/syncing/error/cloud-only) — v1.0
- ✓ Pause/resume drive sync — v1.0
- ✓ Platform abstraction (IPCService, SystemService, LifecycleService) for cross-platform code — v2.0
- ✓ iOS File Provider extension with streaming I/O and memory safety — v2.0
- ✓ iOS companion app with login, drive setup, sync dashboard, settings — v2.0
- ✓ iPad adaptive layout (NavigationSplitView, Split View, Stage Manager) — v2.0
- ✓ Share Extension for uploading files from any iOS app — v2.0
- ✓ Sync status badges in iOS Files app — v2.0
- ✓ CI pipeline for both macOS and iOS builds — v2.0
- ✓ Background App Refresh for periodic iOS sync — v2.0

### Active

- [ ] OAuth login (Google, Microsoft) based on tenant configuration
- [ ] v3 organization-based authentication (username + organization_name)
- [ ] Versioned bucket support (browse/restore previous versions)
- [ ] Bandwidth throttling (user-configurable upload/download limits)
- [ ] iOS home screen widgets for drive status (WidgetKit)
- [ ] PushKit server-push sync for instant iOS remote change detection

### Out of Scope

- Multi-cloud support (non-Cubbit S3) — product is Cubbit-native, not a generic S3 client
- Built-in file editor/viewer — OS handles file operations, not the sync client
- Windows/Linux clients — Apple platforms first, other platforms not planned
- Real-time collaboration — S3 has no locking; sync client, not collaboration tool
- Custom file system (FUSE) — using Apple File Provider exclusively
- In-app file browser on iOS — Files app IS the file browser, companion app is dashboard only
- Camera upload / document scanning — separate product domain, not core to file sync
- iOS offline editing — S3 has no conflict-free merge; on-demand sync is the pattern
- Object locking — future, not planned for current cycle
- Zero Knowledge drives — future
- Public ACL link sharing — future
- Spotlight integration — future
- Siri Shortcuts — future

## Context

### Current State

Shipped v2.0 with full macOS and iOS/iPadOS support.

**Tech stack:** Swift/SwiftUI, File Provider (NSFileProviderReplicatedExtension), Soto v6 (S3), SwiftData, OSLog
**Platforms:** macOS 14+ (Sonoma), iOS 17+, iPadOS 17+
**Architecture:** Main app (SwiftUI) + File Provider extension + DS3Lib (shared SPM package) + Share Extension (iOS)
**Tests:** 156 unit tests (DS3Lib)

**Known issues / tech debt:**
- FOUN-04 (SwiftData metadata database shared via App Group) still pending — sync state tracked in-memory
- Phase 5 plans 05-04, 05-05 unexecuted (menu bar tray overhaul, Italian localization)
- ROADMAP checkboxes were not fully updated during v2.0 execution

### Platform Architecture (Cubbit DS3)

- **Coordinator**: Control plane managing metadata, auth, orchestration
- **Tenants**: Logically isolated domains with dedicated S3 gateways at `s3.<tenant-name>.cubbit.eu`
- **Gateways**: S3-compatible access points

### API Services Used

- **IAM** (`/iam/v1/`): Authentication, token management, account info
- **Composer Hub** (`/composer-hub/v1/`): Projects, tenant routing, S3 endpoint discovery
- **Keyvault** (`/keyvault/api/v3/`): API key CRUD for IAM users
- **S3** (via Soto): All file operations against tenant S3 gateway

## Constraints

- **Platforms**: macOS 14+ (Sonoma), iOS 17+, iPadOS 17+ — Apple Silicon and Intel
- **Framework**: SwiftUI + File Provider (NSFileProviderReplicatedExtension)
- **S3 Client**: Soto v6
- **Local DB**: SwiftData (cross-platform)
- **Auth**: IAM v1 challenge-response (email + password + tenant_id)
- **Backend**: No custom backend — S3 + existing Cubbit coordinator APIs only
- **Signing**: Requires provisioning profiles and matching App Group between all targets
- **Assets**: Git LFS for images
- **License**: GPL

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| macOS first, iOS/iPadOS later | Reduce scope, File Provider is most mature on macOS | ✓ Good — both platforms now shipped |
| SwiftData for local metadata DB | Cross-platform (macOS/iOS), modern Swift API, SQLite-backed | ⚠️ Revisit — FOUN-04 still pending, sync state is in-memory |
| Conflict copies (not last-write-wins) | S3 has no locking; conflict copies prevent data loss (Dropbox pattern) | ✓ Good |
| Keep Soto v6 | Works, mature, no benefit to switching to aws-sdk-swift | ✓ Good |
| v1 auth with tenant_id field | v3 org-based auth not ready (tenant->org migration pending) | ✓ Good — works, extensible |
| Auto-discover S3 endpoint | Composer Hub APIs return gateway URL per tenant/project | ✓ Good |
| On-demand sync (not full sync) | File Provider on-demand is the modern Apple pattern, saves disk space | ✓ Good |
| Protocol abstractions for cross-platform | IPCService/SystemService/LifecycleService enable shared code | ✓ Good — clean separation |
| Darwin notifications for iOS IPC | Lightweight, no framework dependency, fits App Group pattern | ✓ Good |
| Streaming I/O for iOS extension | Stay under 20MB memory limit with zero-copy ByteBuffer | ✓ Good |
| Share Extension with mirrored tokens | Target isolation prevents cross-target file sharing issues | ✓ Good |
| Sequential uploads in Share Extension | Conserve memory in ~120MB extension limit | ✓ Good |

---
*Last updated: 2026-03-20 after v2.0 milestone*
