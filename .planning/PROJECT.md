# DS3 Drive

## What This Is

DS3 Drive is a native macOS (and later iOS/iPadOS) desktop sync application for Cubbit DS3 distributed cloud storage. It integrates with Finder via Apple's File Provider framework to present S3 buckets as native drives with on-demand sync — similar to Dropbox or Google Drive, but backed by Cubbit's geo-distributed, sovereign storage platform.

## Core Value

Files sync reliably and transparently between the user's Mac and Cubbit DS3, with zero friction — login, API key management, and S3 configuration happen under the hood so the experience feels like Dropbox.

## Requirements

### Validated

- ✓ File Provider extension syncs files with S3 backend — existing
- ✓ Challenge-response authentication (Curve25519/ED25519) — existing
- ✓ Multipart upload for large files (>5MB) — existing
- ✓ Menu bar tray icon with sync status — existing (partially working)
- ✓ Drive setup wizard (project → bucket → prefix selection) — existing
- ✓ 2FA support — existing
- ✓ Multiple drives (up to 3) — existing

### Active

- [ ] Revamp to work with current Cubbit DS3 APIs (IAM v1 + Composer Hub)
- [ ] Multitenancy — tenant field in login, auto-discover S3 endpoint from Composer Hub APIs
- [ ] Configurable coordinator URL — separate API base URL for DS3 Composer operations
- [ ] Local metadata database (SwiftData) for reliable sync state tracking (ETag, LastModified, local hash, sync status)
- [ ] Conflict resolution via conflict copies (compare version/ETag before writes)
- [ ] Remote deletion tracking in change enumeration
- [ ] On-demand sync (cloud files downloaded only when opened, like iCloud)
- [ ] Stable, performant sync engine (fix blocking issues, improve throughput)
- [ ] Menu bar tray: sync status per drive, transfer speed, recent files, quick actions (add drive, preferences, open in Finder, pause sync)
- [ ] Rename app to "DS3 Drive"
- [ ] Simplified UX: automatic API key creation/management hidden from user
- [ ] Improved File Provider error handling and logging/debugging infrastructure
- [ ] Finder status overlays (sync badges per file)

### Out of Scope

- iOS/iPadOS — macOS first, extend later using same codebase
- OAuth login (Google, Microsoft) — v2, depends on tenant config
- v3 organization-based auth — rolling out soon, but not until tenant→org migration complete
- Versioned bucket support — future
- Object locking — future
- Zero Knowledge drives — future
- Public ACL links — future
- Thumbnails in Finder — future
- Spotlight integration — future
- Multi-cloud support (non-Cubbit S3) — not planned
- Bandwidth throttling — future

## Context

### Existing Codebase (Brownfield)

The app exists as `CubbitDS3Sync` — a SwiftUI macOS app with a File Provider extension (`Provider/`) and shared library (`DS3Lib/`). It's experimental and has known issues:

- Sync engine sometimes blocks (likely due to missing local state DB and poor error recovery)
- DS3 APIs have changed since initial development
- Menu bar tray not working correctly
- File Provider extension is hard to debug (no structured logging infrastructure)
- No conflict detection or remote deletion tracking
- Performance issues with large directories (no pagination caching, no incremental sync)

### Platform Architecture (Cubbit DS3)

- **Coordinator**: Control plane managing metadata, auth, orchestration. Can be Cubbit-managed (`api.cubbit.eu`) or self-hosted
- **Tenants**: Logically isolated domains with dedicated S3 gateways at `s3.<tenant-name>.cubbit.eu`
- **Swarms**: Geo-distributed storage fabric (nodes, agents, nexuses)
- **Gateways**: S3-compatible access points (public or private)
- Default tenant (NGC): endpoint `s3.cubbit.eu` — currently the only supported tenant

### API Services Used

- **IAM** (`/iam/v1/`): Authentication (challenge-response), token management, account info, IAM users
- **Composer Hub** (`/composer-hub/v1/`): Projects, tenant routing, S3 endpoint discovery
- **Keyvault** (`/keyvault/api/v3/`): API key CRUD for IAM users (separate service)
- **S3** (via Soto): All file operations against tenant S3 gateway

### Competitive Landscape

Main competitors: ExpanDrive (File Provider + S3, free for personal use), Mountain Duck (Smart Sync + File Provider), rclone (open-source CLI). DS3 Drive differentiates by being open-source, Cubbit-native, and consumer-focused.

### Design

Figma available (starting point, not definitive): https://www.figma.com/design/E0QXd1ecdYVm9mDKjOntIK/Sync-Share-2.0

## Constraints

- **Platform**: macOS 14+ (Sonoma), aarch64-darwin (Apple Silicon). iOS/iPadOS deferred
- **Framework**: SwiftUI + File Provider (NSFileProviderReplicatedExtension)
- **S3 Client**: Soto v6 (keep existing dependency)
- **Local DB**: SwiftData (cross-platform ready for iOS/iPadOS)
- **Auth**: IAM v1 challenge-response (email + password + tenant_id). Keep extensible for v3 org-based auth
- **Backend**: No custom backend — S3 + existing Cubbit coordinator APIs only
- **Signing**: Requires provisioning profiles and matching App Group between main app and extension
- **Assets**: Git LFS for images
- **License**: GPL

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| macOS first, iOS/iPadOS later | Reduce scope, File Provider is most mature on macOS | — Pending |
| SwiftData for local metadata DB | Cross-platform (macOS/iOS), modern Swift API, SQLite-backed | — Pending |
| Conflict copies (not last-write-wins) | S3 has no locking; conflict copies prevent data loss (Dropbox pattern) | — Pending |
| Keep Soto v6 | Works, mature, no benefit to switching to aws-sdk-swift | — Pending |
| v1 auth with tenant_id field | v3 org-based auth not ready (tenant→org migration pending) | — Pending |
| Auto-discover S3 endpoint | Composer Hub APIs return gateway URL per tenant/project | — Pending |
| On-demand sync (not full sync) | File Provider on-demand is the modern Apple pattern, saves disk space | — Pending |
| Rename to DS3 Drive | Match Cubbit product naming standards | — Pending |

---
*Last updated: 2026-03-11 after initialization*
