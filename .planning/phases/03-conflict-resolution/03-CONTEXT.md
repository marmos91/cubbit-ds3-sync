# Phase 3: Conflict Resolution - Context

**Gathered:** 2026-03-12
**Status:** Ready for planning

<domain>
## Phase Boundary

Detect version conflicts via ETag comparison before writes and create conflict copies to prevent silent data loss. When concurrent edits happen from multiple devices, both versions are preserved as separate files. Conflict resolution UI is out of scope (Phase 5); this phase creates the detection, preservation, and notification infrastructure.

</domain>

<decisions>
## Implementation Decisions

### Conflict Copy Ownership
- Remote version keeps the original filename (Dropbox pattern -- server is canonical)
- Local version is uploaded to S3 as the conflict copy
- Conflict copy naming: `"filename (Conflict on [hostname] [YYYY-MM-DD HH-MM-SS]).ext"` -- uses Mac hostname via `Host.current().localizedName` and includes time-of-day to distinguish multiple conflicts on the same file in one day
- Conflict copy placed in the same folder as the original (side-by-side in Finder)
- Each conflicting version creates its own copy (1 per conflict, no limit)
- Conflict copies are regular files after creation -- no special protection, can be edited/conflicted again normally
- After uploading local as conflict copy, signal File Provider to re-fetch remote version for the original filename (auto-download)
- Conflict resolution UI deferred to Phase 5 -- for now, users manually delete the copy they don't want

### Conflict Copy Tracking
- Conflict copy gets its own SyncedItem in MetadataStore with `syncStatus = .conflict`
- Enables future Phase 5 conflict resolution UI to query all .conflict items
- No separate conflict log needed -- MetadataStore status is the record

### Detection Scope
- Both enumeration-time and write-time detection (dual protection)
- During SyncEngine reconciliation: if local file is materialized and modified (local hash differs from stored), auto-create conflict copy proactively
- At modifyItem time: HEAD request compares stored ETag against remote ETag before uploading
- At createItem time: HEAD check to detect if file already exists on S3 from another client -- if so, local file gets conflict name (consistent with remote-wins-name)
- At deleteItem time: HEAD before DeleteObject -- if remote ETag changed, cancel delete and return NSFileProviderError (someone modified the file)
- At rename/move time: check source ETag before CopyObject+DeleteObject -- if changed, cancel and return error
- Skip folder operations -- S3 folders are key prefixes, no content conflicts possible
- Claude's Discretion: exact choice of which modifyItem/deleteItem/rename operations get checks (recommend: modifyItem + deleteItem at minimum)
- No grace period for conflict detection -- ETag comparison is definitive (S3 strong consistency)
- If HEAD request fails (network error, timeout), block the upload and return transient error for File Provider retry

### S3 Operations
- HEAD-then-upload approach (not conditional PUT with If-Match) -- better S3-compatible service compatibility
- Accept the millisecond race condition window between HEAD and PUT -- vanishingly rare in practice, next sync cycle catches it
- Always persist ETag to MetadataStore after every successful upload (standard + multipart) -- currently logged but not saved
- Extract ETag from remoteS3Item() HEAD response -- currently missing from HeadObjectOutput parsing

### Delete Conflict Behavior
- Local edit vs remote delete: re-upload the local version to S3 (user's edit wins, no conflict copy needed)
- Local delete vs remote edit: keep remote version, cancel local delete, return NSFileProviderError -- file reappears at next sync via standard File Provider error handling
- Both sides delete: silently succeed -- treat 404/NoSuchKey from S3 as success, remove local SyncedItem
- When delete is cancelled (remote was modified), return error and let File Provider framework handle file reappearance naturally

### Conflict Notification
- macOS notification via UNUserNotificationCenter: "Conflict detected: report.pdf -- Both versions saved."
- Clicking notification reveals the conflict copy in Finder (actionable notification)
- Batching: individual notifications for 1-3 conflicts; if more than 3, single summary: "5 conflicts detected -- click to view"
- IPC: extension posts conflict details via DistributedNotificationCenter, main app listens and shows macOS notification
- Best effort: if main app is not running, no notification shown (conflict copy still created, user discovers in Finder)
- Dedicated "conflict" notification category registered with UNUserNotificationCenter for independent grouping

### Testing
- Unit tests for conflict detection paths: ETag mismatch detection, conflict copy naming, delete-vs-edit handling
- Reuse in-memory SwiftData container pattern from Phase 2 tests

### Claude's Discretion
- Exact NSFileProviderError codes for conflict scenarios (recommend .versionOutOfDate or custom mapping)
- S3Item.itemVersion handling -- whether metadataVersion should differ from contentVersion
- SyncEngine internal conflict detection flow design
- Conflict copy upload retry strategy (reuse existing withRetries pattern)
- Exact notification content wording and formatting
- How to detect "local file is modified" during enumeration (file hash comparison approach)

</decisions>

<specifics>
## Specific Ideas

- Dropbox-style conflict copies: remote is canonical, local becomes the conflict copy -- this is what users expect from sync clients
- Hostname in conflict filename for multi-Mac identification (e.g., "amaterasu", "macbook-pro")
- Date+time in filename prevents collisions when multiple conflicts happen on the same file in one day
- "No data loss" is the absolute priority -- block operations rather than risk overwriting
- HEAD-then-upload is pragmatic: S3 conditional PUTs (If-Match) may not be supported by Cubbit's gateway

</specifics>

<code_context>
## Existing Code Insights

### Reusable Assets
- `MetadataStore.fetchItemEtag()`: retrieves stored ETag for pre-flight comparison
- `MetadataStore.upsertItem()`: persists ETag and sync status (needs .conflict writes)
- `SyncEngine.computeModifiedKeys()`: already compares remote vs local ETags during reconciliation
- `SyncStatus.conflict`: enum case defined but unused -- ready for activation
- `S3Lib.remoteS3Item()`: HEAD request via `s3.headObject()` -- needs ETag extraction added
- `NotificationManager`: DistributedNotificationCenter wrapper -- extend for conflict IPC
- `withRetries()`: retry utility for conflict copy upload attempts
- `S3ErrorType.toFileProviderError()`: error mapping framework -- extend for conflict errors

### Established Patterns
- Guard-let chain init in extension methods (Phase 1)
- Structured OSLog with subsystem/category for conflict logging
- `try?` for MetadataStore CRUD to avoid blocking S3 operations (Phase 2)
- In-memory SwiftData containers for unit testing (Phase 2)
- `S3ListingProvider` protocol for dependency injection in tests (Phase 2)

### Integration Points
- `FileProviderExtension.modifyItem()`: primary conflict detection point -- add HEAD check before upload
- `FileProviderExtension.deleteItem()`: add HEAD check before DeleteObject
- `FileProviderExtension.createItem()`: add HEAD check for existing file detection
- `S3Lib.putS3ItemStandard()` / `S3Lib.putS3ItemMultipart()`: persist ETag after upload
- `S3Lib.remoteS3Item()`: add ETag extraction from HeadObjectOutput
- `SyncEngine.reconcile()`: add conflict detection for materialized+modified files
- `S3Item.itemVersion`: uses ETag as contentVersion -- verify correct usage for conflict detection

</code_context>

<deferred>
## Deferred Ideas

- Conflict resolution UI (keep/discard/merge) -- Phase 5 (UX Polish)
- Conflict history view in main app -- Phase 5 (query MetadataStore for .conflict items)
- Menu bar conflict count badge -- Phase 5

</deferred>

---

*Phase: 03-conflict-resolution*
*Context gathered: 2026-03-12*
