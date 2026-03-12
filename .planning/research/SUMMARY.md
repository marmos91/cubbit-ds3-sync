# Project Research Summary

**Project:** DS3 Drive (macOS cloud file sync with S3 backend)
**Domain:** macOS File Provider sync application with S3-compatible storage
**Researched:** 2026-03-11
**Confidence:** HIGH

## Executive Summary

DS3 Drive is a macOS cloud sync client using Apple's File Provider framework to integrate S3-compatible storage (Cubbit DS3) with Finder. Research reveals this domain requires a **foundation-first approach**: a local metadata database tracking sync state (SwiftData), robust conflict detection using S3 ETags, and careful error handling to prevent data loss. The existing codebase has critical gaps—missing metadata persistence, no conflict resolution, and force-unwrapped optionals that cause silent extension crashes.

The recommended stack keeps **Soto v6** (not v7) to avoid premature Swift 6 migration, adopts **SwiftData** for metadata tracking (one database per drive to avoid concurrent write conflicts), and leverages **OSLog** for debugging File Provider extensions. The architecture follows a **three-layer sync model** where the File Provider extension mediates between S3 (remote state) and macOS filesystem (local state), with the metadata database as the source of truth for reconciliation.

**Key risk**: File Provider extensions are difficult to debug (separate process, limited tooling) and easy to get wrong (sync state corruption, data loss from blind overwrites). Mitigation: build the metadata foundation first, implement conflict detection before adding features, and invest heavily in structured logging (OSLog) for production debugging.

## Key Findings

### Recommended Stack

The stack must support Swift async/await for S3 operations, persistent metadata tracking for sync state, and native macOS frameworks for File Provider integration. **Critical decision: stay on Soto v6.13.0** (not v7) because v7 requires Swift 6.0+ and removes EventLoopFuture APIs. The project needs to stabilize core sync logic on Swift 5.10 before tackling Swift 6 migration.

**Core technologies:**
- **Soto v6.13.0** (S3 client) — Proven async/await support without Swift 6 complexity, 8 years of S3-compatible endpoint experience
- **SwiftData** (metadata database) — Modern Swift-first API, cross-platform ready (iOS/iPadOS future), sufficient for metadata CRUD operations
- **NSFileProviderReplicatedExtension** (sync protocol) — Apple's two-way sync API, required for bidirectional sync and conflict detection
- **OSLog** (structured logging) — Native Console.app integration, critical for debugging extension processes
- **CryptoKit + Security.framework** (auth/credentials) — Already in use for Curve25519 challenge-response and Keychain storage

**Migration path:**
1. Upgrade Soto v6.8.0 → v6.13.0 (low risk, patch releases)
2. Add SwiftData models for sync metadata
3. Future: Swift 6 migration → Soto v7.x upgrade

### Expected Features

**Must have (table stakes):**
- **Conflict resolution** — Multiple devices editing same file must not cause silent data loss (currently MISSING)
- **File status indicators** — Users must see sync state per file (syncing/synced/error) (currently MISSING)
- **Local metadata database** — Track ETags, sync status, version identifiers for conflict detection (currently MISSING)
- **Remote deletion tracking** — Deleted remote files must disappear locally, not reappear (currently MISSING)
- **Stable sync engine** — Fix blocking issues (force-unwraps, multipart ETag validation, sync anchor management)
- **Menu bar status** — Persistent indicator of sync state (exists but broken)
- **Simplified auth UX** — Hide API keys/tenants, auto-discover endpoints (currently exposes too much complexity)

**Should have (competitive advantage):**
- **Multiple independent drives** — Up to 3 sync folders from different projects/tenants (partially implemented)
- **Cubbit-native integration** — Auto-discover S3 endpoints via Composer Hub (reduces setup friction)
- **Open source (GPL)** — Key differentiator vs ExpanDrive/Mountain Duck
- **Transfer speed visibility** — Real-time upload/download speeds in menu bar

**Defer (v2+):**
- **Version history** — Requires versioned S3 bucket support (backend dependency)
- **Zero-knowledge encryption** — High complexity, separate security initiative
- **Block-level sync** — Performance optimization, not correctness issue
- **Bandwidth throttling** — Not requested by users yet

### Architecture Approach

Production File Provider apps follow a **three-layer sync model**: remote state (S3 bucket as authoritative source), middle state (File Provider extension with metadata database tracking known remote state), and local state (macOS filesystem). The extension is the "sync broker" responsible for detecting divergence and reconciling changes bidirectionally. Each drive runs in a **separate extension process**, requiring one SwiftData database per domain to avoid concurrent write conflicts.

**Major components:**
1. **MetadataTracker (SwiftData)** — Stores per-file sync state: itemIdentifier, remoteETag, localHash, syncStatus, lastSyncDate, errorDescription
2. **S3SyncEngine (Extension)** — Orchestrates sync cycles: detect remote changes → compare with local state → resolve conflicts → execute transfers
3. **ConflictResolver (Extension)** — Detects ETag mismatches, creates conflict copies ("filename (Conflict Copy YYYY-MM-DD).ext"), preserves both versions
4. **DownloadManager / UploadManager (Extension)** — Queue-based parallel transfers, multipart upload state machine, progress tracking
5. **DS3DriveManager (Main App)** — Drive lifecycle, domain registration, status aggregation from DistributedNotificationCenter

**Critical pattern:** Store S3 ETags as `versionIdentifier` in NSFileProviderItemVersion. Before upload, compare `baseVersion` with stored ETag to detect conflicts. On mismatch, create conflict copy instead of blind overwrite.

### Critical Pitfalls

1. **Missing local metadata database causes sync state corruption** — Without tracking ETags and sync status persistently, the extension cannot detect conflicts, track remote deletions, or resume interrupted uploads. Every enumeration becomes a full S3 comparison, causing files to re-download and remote changes to overwrite local edits (data loss).

2. **Force-unwrapped optionals in extension initialization cause silent crashes** — Extensions run in separate processes. Force-unwraps (`!`, `as!`) crash the extension, macOS silently restarts it, creating infinite crash loops with no user-visible error. Existing code has critical bugs at FileProviderExtension.swift:32-53.

3. **No conflict resolution = data loss from concurrent edits** — Before uploading, must compare remote ETag with local version. If mismatch (concurrent edit), blindly uploading overwrites remote changes. Must create conflict copy with both versions preserved.

4. **Remote deletion tracking not implemented** — S3 ListObjectsV2 only returns existing objects. To detect deletions, must compare S3 listing against metadata database. Without this, deleted remote files reappear locally (infinite loop).

5. **Multipart upload ETag validation missing** — CompleteMultipartUpload response is discarded (S3Lib.swift:631). ETag must be extracted and validated to detect corrupted uploads. S3 can return HTTP 200 with assembly errors in response body.

## Implications for Roadmap

Based on research, suggested phase structure prioritizes **correctness and reliability** (metadata database, conflict resolution) before **performance** (transfer speeds, optimization) or **polish** (UI enhancements).

### Phase 1: Foundation & Metadata Database
**Rationale:** All sync operations depend on persistent metadata tracking. Must build this foundation before adding features or fixing bugs, otherwise changes build on unstable ground.

**Delivers:**
- SwiftData schema (SyncedItem, SyncAnchor, ConflictCopy models)
- MetadataTracker service (CRUD operations, status queries)
- One database per drive (App Group container: `MetadataDB-{domainIdentifier}.sqlite`)
- Migration from in-memory state to persistent storage

**Addresses:**
- Table stakes: Local metadata database
- Pitfall #1: Sync state corruption from missing database
- Pitfall #2: Force-unwraps crash extension (replace with guard/logging)
- Pitfall #5: Multipart ETag validation (parse CompleteMultipartUpload response)

**Avoids:** Building new features on unstable foundation (metadata is prerequisite for conflict detection, remote deletion tracking, resume logic)

### Phase 2: Sync Engine Core & Remote Change Detection
**Rationale:** With metadata foundation in place, implement reliable remote change detection. This unblocks conflict detection (Phase 3) and ensures remote changes are discovered correctly.

**Delivers:**
- S3Client improvements (ETag extraction, retry logic, continuation token pagination)
- Remote change detector (classify items: new/modified/deleted/unchanged)
- Sync anchor persistence (reload from database, advance after enumeration)
- Remote deletion tracking (compare S3 listing with database state)
- Enumerator refactor (use MetadataTracker as source of truth)

**Uses:**
- Soto v6.13.0 (upgraded from v6.8.0)
- SwiftData queries from Phase 1

**Implements:**
- Three-layer sync model (middle state reconciliation)
- S3SyncEngine state machine

**Addresses:**
- Pitfall #3: Sync anchor state management
- Pitfall #4: Remote deletion tracking
- Pitfall #8: Working set container signaling

### Phase 3: Conflict Detection & Resolution
**Rationale:** Must complete before allowing uploads. Without conflict detection, data loss is inevitable in multi-device scenarios.

**Delivers:**
- Version tracking (store ETag as versionIdentifier)
- ConflictResolver service
- Conflict copy creation ("filename (Conflict Copy YYYY-MM-DD).ext")
- ETag comparison before modifyItem()
- ConflictCopy table tracking for UI

**Addresses:**
- Table stakes: Conflict resolution
- Pitfall #6: Data loss from concurrent edits

**Avoids:** Enabling uploads before conflict detection exists (data loss risk)

### Phase 4: Transfer Managers & Progress Tracking
**Rationale:** With conflict detection protecting against data loss, implement robust upload/download queues with resumption.

**Delivers:**
- DownloadManager (queue-based parallel downloads, SHA256 validation)
- UploadManager (multipart state machine, uploadId/parts persistence)
- Progress tracking (NSProgress updates per part)
- Retry logic with exponential backoff
- Abort incomplete uploads on failure

**Addresses:**
- Table stakes: Network resilience, large file support
- Pitfall #10: No progress reporting
- Pitfall #14: Hardcoded multipart part size (make adaptive)

**Implements:**
- Transfer state machine from architecture research
- Multipart upload with ETag validation

### Phase 5: Main App Integration & Status Visibility
**Rationale:** Extension sync engine is working. Now surface status to users and enable manual control.

**Delivers:**
- Drive Manager improvements (DistributedNotificationCenter subscription)
- Tray Menu enhancements (status per drive, transfer progress, manual sync trigger)
- Error handling UI (surface NSFileProviderError, retry mechanism)
- File status indicators (Finder overlays via NSFileProviderItemDecorations)

**Addresses:**
- Table stakes: File status indicators, menu bar status, pause/resume sync
- Pitfall #12: Error code misuse (map S3 errors correctly)

**Uses:**
- OSLog for debugging (Console.app integration)
- DistributedNotificationCenter for extension → app communication

### Phase 6: Multitenancy & Simplified Auth
**Rationale:** Can develop in parallel with Phases 3-5. Improves UX without touching core sync logic.

**Delivers:**
- Tenant discovery (Composer Hub API: discoverS3Endpoint)
- Store S3 endpoint per drive (support multiple tenants simultaneously)
- Simplified login flow (hide API keys, auto-create behind scenes)
- Tenant-aware auth (validate tenant via IAM)

**Addresses:**
- Differentiator: Cubbit-native integration
- Table stakes: Simplified auth UX (reduce exposed complexity)

**Implements:**
- Multitenancy flow from architecture research

### Phase Ordering Rationale

**Critical path:** Phase 1 → 2 → 3 → 4 (Foundation before sync engine, conflict detection before transfers, all before UI)

**Parallel work opportunity:** Phase 5 (UI) and Phase 6 (Multitenancy) can overlap with Phase 4 (different codebases, minimal dependencies)

**Why this order:**
- **Phase 1 first** — All other phases depend on metadata database (conflict detection needs ETags, remote deletion tracking needs state comparison, resume logic needs stored uploadIds)
- **Phase 2 before 3** — Must reliably detect remote changes before comparing versions for conflicts
- **Phase 3 before 4** — Must protect against data loss (conflict detection) before enabling bulk uploads
- **Phase 5 after 1-4** — UI should reflect working sync engine, not mask broken foundation
- **Phase 6 parallel** — Independent of sync logic (auth and discovery don't touch File Provider code)

### Research Flags

**Phases likely needing deeper research during planning:**
- **Phase 4 (Transfer Managers)** — Multipart upload state machine complexity, S3-compatible endpoint quirks (Cubbit DS3 vs AWS S3 behavior differences)
- **Phase 5 (Finder Overlays)** — NSFileProviderItemDecorations API is newer, less documented than core File Provider

**Phases with standard patterns (skip research-phase):**
- **Phase 1 (SwiftData)** — Well-documented, WWDC sessions, App Group sharing established
- **Phase 2 (S3 Client)** — Soto library documentation, standard S3 API patterns
- **Phase 3 (Conflict Resolution)** — Dropbox-style conflict copies, documented ETag comparison pattern
- **Phase 6 (Multitenancy)** — Standard REST API integration, no File Provider complexity

## Confidence Assessment

| Area | Confidence | Notes |
|------|------------|-------|
| Stack | HIGH | Soto v6 is current dependency (verified in codebase), SwiftData official Apple framework, File Provider well-documented |
| Features | HIGH | Competitive analysis from Dropbox/Google Drive/OneDrive, gaps confirmed in existing DS3 Sync codebase |
| Architecture | MEDIUM | Three-layer model is best practice (verified in production apps like Mountain Duck, ExpanDrive), but SwiftData integration with File Provider has fewer examples |
| Pitfalls | HIGH | Based on official Apple docs, developer community patterns, and critical bugs found in existing codebase analysis |

**Overall confidence:** HIGH

### Gaps to Address

**SwiftData with File Provider concurrency:**
- SwiftData maturity with concurrent extension processes is less proven than Core Data
- Mitigation: One database per domain eliminates concurrent write conflicts
- Validation needed during Phase 1: test with 3 drives running simultaneously

**S3-compatible endpoint quirks:**
- Cubbit DS3 may have behavioral differences from AWS S3 (eventual consistency, multipart upload response format)
- Mitigation: Integration testing with real Cubbit DS3 tenant during Phase 4
- Flag for research-phase during Transfer Managers implementation

**File Provider testing at scale:**
- Testing with 10,000+ files, 100MB/s transfers, 10+ drives is difficult to automate
- Mitigation: Manual testing protocols, Console.app log analysis
- Consider TestFlight beta for real-world validation before v1.0 release

## Sources

### Primary (HIGH confidence)
- [Soto v7.0.0 release notes](https://soto.codes/2024/07/v7-release.html) — Swift 6 requirement verified
- [Soto GitHub releases](https://github.com/soto-project/soto/releases) — v6.13.0 latest stable v6 release
- [SwiftData documentation](https://developer.apple.com/documentation/swiftdata) — macOS 14+ requirement, schema versioning
- [NSFileProviderReplicatedExtension docs](https://developer.apple.com/documentation/fileprovider/nsfileproviderreplicatedextension) — Official API reference
- [Build your own cloud sync using FileProvider](https://claudiocambra.com/posts/build-file-provider-sync/) — Comprehensive production architecture guide
- Existing codebase analysis (`.planning/codebase/CONCERNS.md`, force-unwrap bugs verified)

### Secondary (MEDIUM confidence)
- [Dropbox Engineering: Rewriting the heart of our sync engine](https://dropbox.tech/infrastructure/rewriting-the-heart-of-our-sync-engine) — Nucleus architecture patterns
- [Tracking File Changes in S3 Using ETags](https://geeklogbook.com/tracking-file-changes-in-s3-using-etags/) — ETag-based conflict detection
- [OSLog and Unified logging best practices](https://www.avanderlee.com/debugging/oslog-unified-logging/) — Extension debugging patterns
- Competitive analysis (ExpanDrive, Mountain Duck, rclone feature comparison)

### Tertiary (LOW confidence)
- General Swift concurrency patterns (not verified with 2026 sources, may have evolved)
- SwiftData scaling behavior with 10,000+ records (limited production data)

---
*Research completed: 2026-03-11*
*Ready for roadmap: yes*
