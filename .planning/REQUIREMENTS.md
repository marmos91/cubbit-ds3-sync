# Requirements: DS3 Drive

**Defined:** 2026-03-11
**Core Value:** Files sync reliably and transparently between the user's Mac and Cubbit DS3, with zero friction

## v1 Requirements

### Foundation

- [x] **FOUN-01**: App renamed to "DS3 Drive" with updated bundle identifiers and branding
- [x] **FOUN-02**: OSLog-based structured logging with categories (sync, auth, transfer, extension) across all targets
- [x] **FOUN-03**: Force-unwrapped optionals removed from File Provider extension init (graceful error handling)
- [ ] **FOUN-04**: SwiftData metadata database shared between main app and extension via App Group container

### Sync Engine

- [x] **SYNC-01**: SwiftData schema tracks per-item: S3 key, ETag, LastModified, local file hash, sync status (pending/syncing/synced/error/conflict), parent key, content type, size
- [x] **SYNC-02**: Conflict detection compares local NSFileProviderItemVersion against remote ETag via HEAD request before writes
- [x] **SYNC-03**: Conflict copies created with pattern "filename (Conflict on [device] [date]).ext" when versions diverge
- [x] **SYNC-04**: Remote deletion tracking by comparing S3 listObjectsV2 results against local metadata DB
- [x] **SYNC-05**: Sync anchor persisted to SwiftData and advanced after each successful enumeration batch
- [x] **SYNC-06**: On-demand sync — files visible as cloud placeholders, downloaded only when opened by user
- [x] **SYNC-07**: Multipart upload validates ETag from CompleteMultipartUpload response
- [x] **SYNC-08**: File Provider error codes mapped correctly to NSFileProviderError for proper system retry behavior

### Authentication

- [x] **AUTH-01**: Login flow uses IAM v1 challenge-response with tenant_id field
- [x] **AUTH-02**: API keys auto-created and managed under the hood during drive setup (user never sees them)
- [x] **AUTH-03**: Token refresh handles expiration gracefully without disrupting active sync
- [x] **AUTH-04**: 2FA support maintained from existing implementation

### Platform

- [x] **PLAT-01**: Multitenancy — tenant field in login screen, S3 endpoint auto-discovered from Composer Hub APIs
- [x] **PLAT-02**: Configurable coordinator URL — user can set separate API base URL for DS3 Composer operations
- [x] **PLAT-03**: All API endpoints updated to current IAM/Composer Hub/Keyvault specs
- [x] **PLAT-04**: API URLs no longer hardcoded — derived from coordinator base URL + tenant config

### User Experience

- [x] **UX-01**: Finder status overlays showing sync state per file (synced/syncing/error/cloud-only)
- [ ] **UX-02**: Menu bar tray shows sync status per drive with colored indicators
- [ ] **UX-03**: Menu bar tray shows real-time transfer speed (upload/download)
- [ ] **UX-04**: Menu bar tray shows recently synced files
- [ ] **UX-05**: Menu bar tray quick actions: add drive, open in Finder, preferences, pause sync
- [ ] **UX-06**: Simplified drive setup wizard with tenant-aware project/bucket selection
- [x] **UX-07**: Drive limit maintained at 3 maximum

## v2 Requirements

### Authentication

- **AUTH-05**: OAuth login (Google, Microsoft) based on tenant configuration
- **AUTH-06**: v3 organization-based authentication (username + organization_name)

### Advanced Sync

- **SYNC-09**: Versioned bucket support (browse/restore previous versions)
- **SYNC-10**: Object locking support
- **SYNC-11**: Bandwidth throttling (user-configurable upload/download limits)
- **SYNC-12**: Spotlight integration (index synced file contents)
- **SYNC-13**: Thumbnail generation for Finder Quick Look

### Platform

- **PLAT-05**: iOS/iPadOS support using shared codebase
- **PLAT-06**: Zero Knowledge drive support

### UX

- **UX-08**: Public ACL link sharing from Finder context menu

## Out of Scope

| Feature | Reason |
|---------|--------|
| Multi-cloud support (non-Cubbit S3) | Product is Cubbit-native, not a generic S3 client |
| Built-in file editor/viewer | OS handles file operations, not the sync client |
| Windows/Linux clients | macOS first, other platforms not planned |
| Real-time collaboration | S3 has no locking; sync client, not collaboration tool |
| AI/ML features | Out of product scope |
| Custom file system (FUSE) | Using Apple File Provider exclusively |

## Traceability

| Requirement | Phase | Status |
|-------------|-------|--------|
| FOUN-01 | Phase 1 | Complete |
| FOUN-02 | Phase 1 | Complete |
| FOUN-03 | Phase 1 | Complete |
| FOUN-04 | Phase 1 | Pending |
| SYNC-01 | Phase 2 | Complete |
| SYNC-02 | Phase 3 | Complete |
| SYNC-03 | Phase 3 | Complete |
| SYNC-04 | Phase 2 | Complete |
| SYNC-05 | Phase 2 | Complete |
| SYNC-06 | Phase 2 | Complete |
| SYNC-07 | Phase 1 | Complete |
| SYNC-08 | Phase 1 | Complete |
| AUTH-01 | Phase 4 | Complete |
| AUTH-02 | Phase 4 | Complete |
| AUTH-03 | Phase 4 | Complete |
| AUTH-04 | Phase 4 | Complete |
| PLAT-01 | Phase 4 | Complete |
| PLAT-02 | Phase 4 | Complete |
| PLAT-03 | Phase 4 | Complete |
| PLAT-04 | Phase 4 | Complete |
| UX-01 | Phase 5 | Complete |
| UX-02 | Phase 5 | Pending |
| UX-03 | Phase 5 | Pending |
| UX-04 | Phase 5 | Pending |
| UX-05 | Phase 5 | Pending |
| UX-06 | Phase 5 | Pending |
| UX-07 | Phase 5 | Complete |

**Coverage:**
- v1 requirements: 27 total
- Mapped to phases: 27
- Unmapped: 0 ✓

---
*Requirements defined: 2026-03-11*
*Last updated: 2026-03-11 after initial definition*
