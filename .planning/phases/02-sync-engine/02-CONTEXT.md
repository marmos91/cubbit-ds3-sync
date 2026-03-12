# Phase 2: Sync Engine - Context

**Gathered:** 2026-03-12
**Status:** Ready for planning

<domain>
## Phase Boundary

Build a metadata-driven sync engine that reliably detects and reflects remote changes. New files appear in Finder, modified files update, deleted files disappear within one sync cycle, and files download on demand when opened. The engine uses SwiftData (MetadataStore) to track per-item state and compares it against S3 listings for change detection. Conflict resolution is explicitly out of scope (Phase 3).

</domain>

<decisions>
## Implementation Decisions

### Deletion Behavior
- Immediate disappearance from Finder at next sync cycle when files are deleted on S3
- Full reconciliation on every `enumerateChanges()` call: S3 `listObjectsV2` compared against MetadataStore to detect deletions
- Individual S3 `DeleteObject` calls per `deleteItem()` invocation (no batching) -- File Provider framework requires per-item completion handlers
- Hard delete of SyncedItem records from MetadataStore when remote deletion detected (consistent with Phase 1 drive removal pattern)
- Threshold warning: if >50% of items in a drive are detected as deleted in one cycle, log a warning but still proceed with deletion
- Empty folder auto-cleanup: folders disappear when all contents are deleted (follows S3 semantics -- empty prefixes don't exist)
- In-use files: delegate to File Provider framework (it won't remove open files; deletion applied when file is closed)

### Sync Frequency
- System-managed: let File Provider framework control when `enumerateChanges()` is called -- no custom polling timer
- Signal after local changes: call `NSFileProviderManager.signalEnumerator()` after local upload/delete/rename completes to trigger eager re-enumeration
- Full reconciliation on every `enumerateChanges()` call (not periodic -- every call does complete S3 listing vs MetadataStore diff)
- Paginate through all objects using S3 `listObjectsV2` continuation tokens -- no cap on item count
- Exponential backoff on S3 errors: increase delay between retries (1s, 2s, 4s, 8s... up to max) after consecutive failures, reset on success
- NWPathMonitor integration: monitor network status, pause enumeration when offline, resume when connectivity returns

### On-Demand Download
- Cloud placeholders via `.downloadLazily` content policy -- files appear with cloud icon, download on double-click (already partially working)
- Basic pinning support: allow "Keep Downloaded" on files/folders using `.downloadLazilyAndKeepDownloaded` policy
- Auto-retry with exponential backoff on download failure; after all retries fail, show error state on file; user can retry by re-opening
- Track materialization in MetadataStore: add `isMaterialized` field to SyncedItem so app can show "X of Y files downloaded"
- Partial downloads for large files: use S3 range GET requests + File Provider `fetchPartialContents` for files above a threshold

### Error Recovery
- Per-drive error status: drive shows "error" in menu bar tray after failures; no per-file error badges yet (Phase 5)
- 3 consecutive sync cycle failures = drive marked as error state
- Auto-recover: when NWPathMonitor detects connectivity restored, reset error count and resume sync
- Track per-item errors in MetadataStore: set `syncStatus` to `error` on failed file operations; enables Phase 5 error badges
- 3 retries per file operation with exponential backoff, then mark as error and skip until next full reconciliation
- API key expiry handling deferred to Phase 4 (Auth & Platform); if key is invalid in Phase 2, drive enters error state

### Code Structure
- Extract new `SyncEngine` class that orchestrates reconciliation: S3 listing, MetadataStore diff, deletion detection, change reporting
- `SyncEngine` lives in `DS3Lib/Sources/DS3Lib/Sync/` -- accessible from both app and extension
- Migrate `MetadataStore` from `@MainActor` to `ModelActor` for background thread execution (File Provider extension runs off main actor)
- New `SyncAnchorRecord` SwiftData entity: separate from SyncedItem, contains `driveId`, `lastSyncDate`, and additional tracking fields -- one per drive
- `SyncEngine` uses async/await with `SyncEngineDelegate` protocol or `AsyncStream` for status updates (not DistributedNotificationCenter for intra-process)
- `S3Enumerator` delegates to `SyncEngine` for reconciliation; `S3Item` stays as pure File Provider item representation
- `SyncEngine` owns all MetadataStore writes -- S3Item does not interact with persistence
- Basic unit test coverage for SyncEngine: new items detected, modified items detected, deleted items detected, sync anchor advancement; use in-memory SwiftData container

### Claude's Discretion
- Partial download threshold (recommend somewhere between 5MB and 100MB based on performance testing)
- Exact exponential backoff parameters (max delay, jitter)
- ModelActor implementation details (custom actor vs. SwiftData's @ModelActor macro)
- SyncEngine internal state machine design
- S3Enumerator refactoring approach (how much logic to move vs. keep)
- Test framework choice (XCTest vs. Swift Testing)

</decisions>

<specifics>
## Specific Ideas

- Full reconciliation on every cycle is preferred over incremental -- user wants changes to appear reliably, not "eventually"
- Pinning support was added to scope despite being borderline UX -- user wants at minimum the ability to keep files downloaded
- Partial downloads for large files requested -- this is technically complex (fetchPartialContents) but the user wants it for v1
- The existing `// TODO: process remotely deleted files` comment in S3Enumerator is the core gap this phase fills

</specifics>

<code_context>
## Existing Code Insights

### Reusable Assets
- `MetadataStore` (DS3Lib/Metadata/): SyncedItem CRUD operations -- needs ModelActor migration but core operations are ready
- `SyncedItem` (DS3Lib/Metadata/): Schema v1 with versioned migration plan -- needs `isMaterialized` field addition (schema v2)
- `withRetries()` (DS3Lib/Utils/ControlFlow.swift): Retry utility -- extend with exponential backoff support
- `NotificationManager` (DS3DriveProvider/): DistributedNotificationCenter wrapper -- keep for app-extension communication, SyncEngine uses async callbacks internally
- `S3Lib.listS3Items()` (DS3DriveProvider/S3Lib.swift): S3 listing with continuation tokens -- SyncEngine will call this for reconciliation

### Established Patterns
- `@Observable` for view model state management
- Guard-let chain init in extension methods (from Phase 1)
- `S3ErrorType.toFileProviderError()` mapping (from Phase 1)
- Structured OSLog with subsystem/category (from Phase 1)
- `UnsafeCallback<T>` wrapper for File Provider callbacks (pre-Swift-concurrency compatibility)

### Integration Points
- `S3Enumerator.enumerateChanges()` -- primary target for SyncEngine integration
- `S3Enumerator.enumerateItems()` -- initial enumeration will also use MetadataStore
- `FileProviderExtension.init(domain:)` -- MetadataStore initialization goes here
- `FileProviderExtension.fetchContents()` -- update to track materialization and support partial downloads
- `FileProviderExtension.createItem()/modifyItem()/deleteItem()` -- update to write SyncedItem records
- `SharedData.loadSyncAnchorOrCreate()` -- replace with SyncAnchorRecord from SwiftData

</code_context>

<deferred>
## Deferred Ideas

None -- discussion stayed within phase scope

</deferred>

---

*Phase: 02-sync-engine*
*Context gathered: 2026-03-12*
