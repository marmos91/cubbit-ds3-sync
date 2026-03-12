# Domain Pitfalls: macOS File Provider + S3 Sync

**Domain:** macOS File Provider (NSFileProviderReplicatedExtension) with S3 backend
**Researched:** 2026-03-11
**Confidence:** HIGH (based on Apple documentation, developer community patterns, existing codebase analysis)

## Critical Pitfalls

These mistakes cause data loss, sync failures, or require architectural rewrites.

---

### Pitfall 1: Missing Local Metadata Database Causes Sync State Corruption

**What goes wrong:**
Without a local database tracking sync state (ETag, LastModified, sync status, version identifiers), the extension cannot detect conflicts, track remote deletions, or recover from interrupted uploads. Every enumeration becomes a full comparison against S3, causing:
- Files thought to be synced get re-downloaded
- Modified local files overwrite newer remote versions (data loss)
- Deleted remote files reappear locally
- Multipart uploads fail mid-stream with no recovery path

**Why it happens:**
Developers assume File Provider's internal state is sufficient, or rely solely on S3 metadata. File Provider only tracks item hierarchy, not sync state. S3 is eventually consistent (despite strong consistency in AWS, S3-compatible implementations vary).

**Consequences:**
- Users lose work from blind overwrites
- Sync appears to work but silently drops changes
- No conflict detection → data loss
- Performance degrades (every change enumeration requires full S3 listing)

**Prevention:**
- Implement SwiftData schema with: `itemIdentifier`, `etag`, `lastModified`, `localHash`, `syncStatus` (enum: synced/uploading/downloading/conflict), `versionIdentifier`
- Update database atomically with File Provider operations
- Use database as source of truth for `enumerateChanges()` and `currentSyncAnchor()`
- Store sync anchors persistently (don't regenerate on each enumeration)

**Detection:**
- Same files repeatedly appear in `enumerateChanges()` output
- Users report "file reverted to old version"
- Extension logs show full S3 bucket listings on every sync
- Multipart uploads restart from scratch after app relaunch

**Phase mapping:** Phase 1 (Foundation) — metadata database is prerequisite for all sync operations

---

### Pitfall 2: Force-Unwrapped Optionals in Extension Initialization Cause Silent Crashes

**What goes wrong:**
File Provider extensions run in a separate process. If initialization fails (missing App Group data, corrupted JSON, invalid drive configuration), force-unwrapped optionals (`!`, `as!`) crash the extension process. macOS silently restarts it, creating an infinite crash loop. Users see Finder freeze or "unavailable" status with no error message.

**Why it happens:**
Extensions are harder to debug than main apps (no visible crash logs in Xcode, separate process lifecycle). Developers use force-unwraps during prototyping and forget to add error handling before production.

**Consequences:**
- Extension never initializes → drives don't appear in Finder
- Infinite crash loops drain battery and CPU
- No user-visible error (extension crash logs are buried in Console.app)
- Support requests with "sync doesn't work" and no actionable info

**Prevention:**
- Replace all force-unwraps in `init()` with `guard let ... else { logger.fault(...); return }`
- Return early from init if critical data is missing (don't crash)
- Add structured logging to extension (OSLog with subsystem identifier)
- Validate App Group data on main app launch, not in extension
- Use `Logger` with `.fault` level for initialization failures

**Detection:**
- Extension process appears/disappears rapidly in Activity Monitor
- Console.app shows repeated "FileProviderExtension terminated unexpectedly"
- Finder shows drive but files never appear
- Memory usage spikes then drops repeatedly

**Phase mapping:** Phase 1 (Foundation) — fix existing force-unwraps in Provider/FileProviderExtension.swift lines 32-53 before adding features

**Existing code example (CRITICAL BUG):**
```swift
// Provider/FileProviderExtension.swift:32-53
let drive = sharedData.loadDriveOrCreate(for: domain.identifier.rawValue)!
let project = sharedData.loadProjectOrCreate(for: drive.projectId)!
```

---

### Pitfall 3: Sync Anchor State Management Errors Break Change Enumeration

**What goes wrong:**
Sync anchors represent points-in-time in your backend. Common mistakes:
- **Stale anchors**: Loading anchor once at init, never refreshing (existing bug in S3Enumerator.swift:17)
- **Non-advancing anchors**: Returning same anchor after `finishEnumeratingChanges()`, causing infinite loops
- **Oversized anchors**: Exceeding 500-byte limit causes enumeration failure (Apple enforces this)
- **No persistence**: Regenerating anchors on each enumeration instead of storing them

**Why it happens:**
Anchor semantics are poorly documented. Developers treat anchors like timestamps instead of opaque state markers. The 500-byte limit is undocumented in most guides.

**Consequences:**
- System repeatedly enumerates same changes (infinite loop)
- Remote changes never detected (anchor doesn't advance)
- Enumeration fails silently (oversized anchor)
- High CPU usage from redundant S3 listings

**Prevention:**
- Store sync anchors in metadata database (not just in-memory)
- Anchor should encode: last enumeration timestamp, continuation token, highest processed modification time
- Keep anchor data under 500 bytes (use timestamps + S3 continuation token, not full file lists)
- Refresh anchor from database on each `enumerateChanges()` call, not just at init
- Advance anchor after every `finishEnumeratingChanges()` call
- Implement `currentSyncAnchor()` to return latest state before `enumerateChanges()` is called

**Detection:**
- Same files appear in multiple consecutive `enumerateChanges()` batches
- Logs show identical S3 ListObjectsV2 requests repeatedly
- System never calls `enumerateChanges()` again after first batch
- Extension CPU usage remains high during "idle" state

**Phase mapping:** Phase 2 (Sync Engine Revamp) — implement persistent anchor storage with database

**Existing code warning:**
```swift
// Provider/S3Enumerator.swift:17
let syncAnchor = SharedData.default().loadSyncAnchorOrCreate(for: drive, project: project)
// ⚠️ Never refreshed after init — stale anchor bug
```

---

### Pitfall 4: Remote Deletion Tracking Not Implemented (Silent Data Reappearance)

**What goes wrong:**
When files are deleted remotely (via web UI, API, or another device), `enumerateChanges()` only sees items that currently exist in S3. Locally cached files deleted remotely are never reported as deletions. Result: deleted files reappear in Finder, user deletes again, they reappear again (infinite loop).

**Why it happens:**
S3 ListObjectsV2 only returns existing objects. To detect deletions, you must compare current S3 listing against your local database of previously synced items. This is not obvious from Apple's File Provider documentation.

**Consequences:**
- Users cannot permanently delete files (they keep coming back)
- Storage quota inflates (deleted files still count as "synced")
- Confusion: "I deleted this file 5 times, why is it still here?"
- Breaks user trust in sync reliability

**Prevention:**
- In `enumerateChanges()`, load previous sync state from database
- Compare S3 listing against database: items in DB but not in S3 = deleted remotely
- Report deletions via `observer.didDelete(with: [itemIdentifier])`
- Update database to remove deleted items after reporting
- Handle deletion conflicts: if item modified locally but deleted remotely, create conflict copy

**Detection:**
- Users report "deleted files keep reappearing"
- Database shows items with old sync status that no longer exist in S3
- `enumerateChanges()` never calls `observer.didDelete()`
- Finder shows files that don't exist in S3 bucket

**Phase mapping:** Phase 2 (Sync Engine Revamp) — required for production-quality sync

**Existing code warning:**
```swift
// Provider/S3Enumerator.swift
// ⚠️ No deletion tracking implemented
// Only enumerates items returned by S3 ListObjectsV2
```

---

### Pitfall 5: Multipart Upload ETag Validation Missing (Silent Upload Failures)

**What goes wrong:**
After completing a multipart upload, the response includes an ETag representing the combined object. If you don't validate this ETag or compare it against local expectations, corrupted uploads succeed silently. S3 may return 200 OK even if parts were assembled incorrectly.

For multipart uploads, ETag format is `<combined-MD5>-<part-count>` (e.g., `33a01f6c513ec334bbdfbc606ad2cbe1-3`). If you discard the CompleteMultipartUpload response (existing bug in S3Lib.swift:631), you never verify the upload succeeded.

**Why it happens:**
Developers assume HTTP 200 = success. S3 can return 200 but include error details in XML response body. Multipart upload completion is asynchronous on some S3 implementations—response arrives before final assembly completes.

**Consequences:**
- Corrupted files uploaded successfully (user doesn't know)
- File size mismatch between local and remote
- Future downloads fail with data corruption
- No way to detect partial upload success

**Prevention:**
- Parse CompleteMultipartUpload response, don't discard it
- Extract and validate ETag from response
- Store ETag in metadata database for future conflict detection
- Compare remote ETag format: single-part = MD5 hash, multipart = `<hash>-<partCount>`
- If ETag validation fails, delete incomplete object and retry upload
- Log ETag mismatches at error level for monitoring

**Detection:**
- File uploads succeed but downloads are corrupted
- S3 object size differs from local file size
- Users report "file won't open after upload"
- Database shows no ETag for uploaded items

**Phase mapping:** Phase 1 (Foundation) — fix existing S3Lib.swift response handling before adding new features

**Existing code example (CRITICAL BUG):**
```swift
// Provider/S3Lib.swift:631
_ = try await s3.completeMultipartUpload(...)
// ⚠️ Response discarded — no ETag validation
```

---

### Pitfall 6: Conflict Resolution Without Version Comparison (Data Loss)

**What goes wrong:**
Before uploading local modifications, you must compare `versionIdentifier` (or ETag) against current remote state. If versions don't match (concurrent edits), blindly uploading overwrites remote changes. No conflict copy is created. Last write wins = data loss.

**Why it happens:**
Developers assume S3 object locking or server-side conflict detection exists. S3 has no built-in locking for standard buckets (only versioned buckets with conditional writes). File Provider expects *your* extension to handle conflicts.

**Consequences:**
- Users lose work from concurrent edits
- "My changes disappeared" support tickets
- No recovery path (no conflict copies generated)
- Breaks collaboration use cases (multiple devices syncing)

**Prevention:**
- Before `modifyItem()`, fetch current S3 object metadata (HeadObject to get ETag)
- Compare remote ETag against database `versionIdentifier`
- If mismatch: create conflict copy with naming pattern `<filename> (Conflict <timestamp>).<ext>`
- Upload conflict copy as new object, preserve both versions
- Signal `enumerateChanges()` to report both items
- Update UI to show conflict icon (future: Finder overlays)

**Detection:**
- Users report "my edits vanished"
- Database shows mismatched ETags vs S3 reality
- No conflict copies in S3 bucket despite concurrent edits
- Sync appears to work but changes are lost

**Phase mapping:** Phase 2 (Sync Engine Revamp) — conflict resolution is table-stakes for production

---

### Pitfall 7: Synchronous App Group File I/O Blocks Extension Thread (UI Freezes)

**What goes wrong:**
File Provider extensions share data with the main app via App Group containers. If you perform synchronous JSON serialization/deserialization on the extension's main thread (existing pattern in SharedData), heavy I/O (large drive lists, slow disk) blocks enumeration callbacks. System timeouts trigger, extension is killed, Finder shows "unavailable".

**Why it happens:**
App Group containers are convenience APIs. Easy to use synchronously. No obvious async alternative. Developers don't test with slow storage or large datasets.

**Consequences:**
- Finder freezes when opening drive folders
- Extension killed by watchdog timeout (system expects enumeration within seconds)
- Poor UX on spinning disks or network-mounted home directories
- Scales poorly with number of drives (3+ drives = noticeable lag)

**Prevention:**
- Move all App Group file I/O to background queues
- Use async/await for SharedData load/save operations
- Implement in-memory caching with invalidation strategy (don't reload on every access)
- Batch writes (don't save on every change)
- Consider Protocol Buffers or other binary formats instead of JSON for large data
- Test with 10+ drives and slow storage (external HDD)

**Detection:**
- Finder "beach ball" when expanding drive folders
- Console.app shows "FileProviderExtension timeout" errors
- Extension process CPU spikes during idle state
- Latency increases linearly with number of configured drives

**Phase mapping:** Phase 3 (Performance) — optimize after core sync is working

---

## Moderate Pitfalls

These cause degraded UX or reliability issues but don't result in data loss.

---

### Pitfall 8: Working Set Container Not Signaled for Remote Changes

**What goes wrong:**
When remote changes occur, you must call `NSFileProviderManager.signalEnumerator(for: .workingSet)` to trigger `enumerateChanges()`. If you signal specific folder containers instead, the system may not detect changes in other folders. Remote edits appear stale until manual refresh.

**Why it happens:**
Intuition says "signal the folder that changed". File Provider documentation is unclear about working set semantics.

**Prevention:**
- Always signal `.workingSet` for remote changes, not specific folders
- Only signal specific folders for UI-driven operations (user browsed a folder)
- Implement periodic background working set refresh (every 5-15 minutes)

**Detection:**
- Remote changes appear only after user manually refreshes Finder
- Logs show signaling for specific `NSFileProviderItemIdentifier` instead of `.workingSet`

**Phase mapping:** Phase 2 (Sync Engine Revamp)

---

### Pitfall 9: Pagination Size Ignored (Performance Degradation with Large Buckets)

**What goes wrong:**
Apple provides `suggestedPageSize` in enumeration callbacks. Returning 10,000+ items in a single batch causes:
- Memory spikes (all items materialized in extension process)
- Slow UI updates (Finder waits for entire batch)
- Extension timeout (system expects results within seconds)

System enforces maximum of 100x suggested size, but you should respect the suggestion.

**Why it happens:**
Developers want to "finish quickly" and return everything at once. S3 ListObjectsV2 supports 1000 items per request—tempting to return all in one batch.

**Prevention:**
- Respect `suggestedPageSize` (typically 200-500 items)
- Use S3 continuation tokens to implement pagination
- Return batches with `moreComing: true` until enumeration complete
- Test with buckets containing 50,000+ objects

**Detection:**
- Extension memory usage spikes during enumeration
- Finder slow to populate large folders
- System kills extension with "memory exceeded" errors

**Phase mapping:** Phase 3 (Performance)

---

### Pitfall 10: No Progress Reporting During Long Operations (User Confusion)

**What goes wrong:**
File Provider provides `NSProgress` objects for downloads/uploads. If you don't update `progress.completedUnitCount` during multipart uploads or large downloads, users see:
- Indeterminate progress spinners (no ETA)
- No indication if operation stalled vs progressing slowly
- Cannot cancel stalled operations (progress not observed for cancellation)

**Prevention:**
- Update `Progress.completedUnitCount` after each multipart upload part
- Monitor `progress.isCancelled` and abort early if true
- Report realistic `totalUnitCount` based on file size and part size
- Use Finder's native progress UI (automatically wired if Progress updated correctly)

**Detection:**
- Users report "can't tell if upload is stuck or working"
- Activity Monitor shows network activity but Finder shows no progress
- Canceling operations doesn't stop network requests

**Phase mapping:** Phase 3 (Performance)

---

### Pitfall 11: Bundle Files Treated as Atomic (Fails for .app, .bundle, etc.)

**What goes wrong:**
macOS bundles (`.app`, `.bundle`, `.xcodeproj`) appear as single files in Finder but are directories internally. If you upload them as single objects via `fetchContents()`, internal structure is lost. Downloads fail to reconstruct bundle.

**Why it happens:**
File Provider calls `fetchContents()` for bundles (system sees them as files). You must detect bundle type and recursively enumerate internal structure.

**Prevention:**
- Detect bundle types via UTType checking
- Recursively iterate internal files/subdirectories
- Upload each component as separate S3 object with path prefix
- On download, reconstruct directory structure locally

**Detection:**
- Users report ".app files won't run after download"
- Xcode projects appear as single file instead of directory structure

**Phase mapping:** Phase 4 (Robustness) — edge case but critical for developer workflows

---

### Pitfall 12: Error Code Misuse Breaks System Retry Logic

**What goes wrong:**
File Provider error codes influence system behavior:
- `.notAuthenticated` → system prompts for re-authentication
- `.serverUnreachable` → system retries automatically
- `.noSuchItem` → system assumes permanent failure, no retry
- `.insufficientQuota` → system shows storage full UI

Returning wrong error codes:
- Breaks automatic retry (transient network error as `.noSuchItem`)
- Causes incorrect UI (authentication prompt for network timeout)
- Prevents user recovery (quota error with no remediation path)

**Prevention:**
- Map S3 errors correctly:
  - 401/403 → `.notAuthenticated`
  - 404 → `.noSuchItem` (only if item truly doesn't exist)
  - Network timeout → `.serverUnreachable`
  - 503 → `.serverUnreachable`
  - 507 → `.insufficientQuota`
- Use helper functions: `NSError.fileProviderErrorForCollision(with:)`
- Log error mapping decisions for debugging

**Detection:**
- System never retries transient failures
- Authentication prompts appear during network outages
- Users report "no way to fix sync errors"

**Phase mapping:** Phase 1 (Foundation) — fix existing error handling in FileProviderExtension+Errors.swift

**Existing code warning:**
```swift
// Provider/FileProviderExtension+Errors.swift:38-42
// ⚠️ Generic mapping loses S3 error context
case .s3Error: return NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError)
```

---

## Minor Pitfalls

---

### Pitfall 13: Continuation Token Pagination Not Tested at Scale

**What goes wrong:**
S3 ListObjectsV2 returns max 1000 objects per request. For larger buckets, continuation tokens paginate results. If pagination logic has off-by-one errors or doesn't handle final page correctly, items are silently lost.

**Prevention:**
- Integration tests with 10,000+ object buckets
- Validate all continuation token branches
- Log total enumerated count vs expected S3 object count

**Detection:**
- File counts don't match between S3 and Finder
- Some files never appear locally despite existing in S3

**Phase mapping:** Phase 5 (Testing/Validation)

---

### Pitfall 14: Hardcoded Multipart Upload Part Size Suboptimal

**What goes wrong:**
Fixed 5MB part size (existing code in DefaultSettings.S3.multipartUploadPartSize) is suboptimal for:
- Fast networks (larger parts = fewer S3 requests)
- Slow networks (smaller parts = better retry granularity)
- Large files (10,000 part limit → max 50GB file with 5MB parts)

**Prevention:**
- Make part size configurable (user preference or adaptive)
- Auto-adjust based on file size: 5MB for <100MB, 10MB for <1GB, 50MB for >1GB
- Stay within S3 limits: 5MB min, 5GB max, 10,000 parts max

**Detection:**
- Uploads fail for files >50GB
- Slow upload throughput on fast networks (overhead from many small parts)

**Phase mapping:** Phase 4 (Robustness)

---

### Pitfall 15: Move Operations Fail with NoSuchKey (Intermittent Race Condition)

**What goes wrong:**
Existing bug comment in FileProviderExtension.swift:362 indicates intermittent NoSuchKey errors during move operations. Likely cause: S3 CopyObject completes but source object not yet fully replicated before DeleteObject is called (eventual consistency on S3-compatible storage).

**Prevention:**
- After CopyObject, validate destination object exists (HeadObject) before deleting source
- Add retry logic with exponential backoff for move operations
- Use S3 conditional writes (If-Match with ETag) to detect race conditions
- Consider implementing moves as metadata-only operations in database until both copy and delete confirmed

**Detection:**
- Users report "move failed" errors intermittently
- Logs show NoSuchKey during DeleteObject after successful CopyObject

**Phase mapping:** Phase 2 (Sync Engine Revamp) — existing bug, needs root cause analysis

---

## Phase-Specific Warnings

| Phase Topic | Likely Pitfall | Mitigation |
|-------------|---------------|------------|
| Phase 1: Foundation & Metadata DB | Force-unwraps crash extension silently | Replace all `!` with `guard let` + logging |
| Phase 1: Foundation & Metadata DB | Multipart upload response discarded | Parse and validate ETag from CompleteMultipartUpload |
| Phase 2: Sync Engine Revamp | No remote deletion tracking | Compare S3 listings against database state |
| Phase 2: Sync Engine Revamp | Sync anchors never advance | Store anchors persistently, update after finishEnumeratingChanges |
| Phase 2: Sync Engine Revamp | No conflict resolution | Compare ETags before modifyItem, create conflict copies on mismatch |
| Phase 2: Sync Engine Revamp | Working set not signaled | Always signal .workingSet for remote changes |
| Phase 3: Performance Optimization | Synchronous App Group I/O blocks threads | Move SharedData to async/await, add caching |
| Phase 3: Performance Optimization | Pagination ignored for large buckets | Respect suggestedPageSize, implement continuation token pagination |
| Phase 3: Performance Optimization | No progress reporting | Update NSProgress during multipart uploads |
| Phase 4: Robustness & Edge Cases | Bundle files uploaded as single objects | Detect bundles, recursively upload internal structure |
| Phase 4: Robustness & Edge Cases | Hardcoded multipart part size | Make adaptive based on file size and network speed |
| Phase 5: Error Handling & Logging | Wrong error codes break retry logic | Map S3 errors to correct NSFileProviderError codes |
| Phase 5: Error Handling & Logging | No structured logging in extension | Implement OSLog with subsystem, log all errors at appropriate levels |

---

## Sources

### File Provider Best Practices
- [Build your own cloud sync on iOS and macOS using Apple FileProvider APIs](https://claudiocambra.com/posts/build-file-provider-sync/) — Comprehensive implementation guide with pitfall warnings
- [NSFileProviderReplicatedExtension Documentation](https://developer.apple.com/documentation/fileprovider/nsfileproviderreplicatedextension?language=objc) — Official Apple documentation
- [How to Work with the File Provider API on macOS](https://www.apriorit.com/dev-blog/730-mac-how-to-work-with-the-file-provider-for-macos) — Implementation challenges and solutions
- [macOS File Provider extension debugging example](https://github.com/neXenio/macosfileproviderexample) — Example project with debugging setup

### S3 Conflict Detection & ETags
- [Tracking File Changes in S3 Using ETags](https://geeklogbook.com/tracking-file-changes-in-s3-using-etags/) — ETag behavior for conflict detection
- [Understanding AWS S3 ETag](https://www.artofcode.org/blog/aws-s3-etag/) — Multipart upload ETag format
- [How to prevent object overwrites with conditional writes](https://docs.aws.amazon.com/AmazonS3/latest/userguide/conditional-writes.html) — AWS S3 conflict resolution mechanisms
- [Debugging S3 Multipart Upload Failures](https://medium.com/@Adekola_Olawale/debugging-s3-multipart-upload-failures-271fdfd21244) — Common multipart upload issues

### S3 Consistency & Best Practices
- [How to handle eventual consistency with S3](https://markdboyd.medium.com/how-to-handle-eventual-consistency-with-s3-5cfbe97d1f18) — Eventual consistency patterns
- [Best practices: managing multipart uploads](https://docs.aws.amazon.com/filegateway/latest/files3/best-practices-managing-multi-part-uploads.html) — AWS official best practices
- [Uploading and copying objects using multipart upload](https://docs.aws.amazon.com/AmazonS3/latest/userguide/mpuoverview.html) — Multipart upload reference

### Debugging & Production Issues
- [File Provider API on macOS](https://www.perfectiongeeks.com/how-to-work-with-the-file-provider-for-macos) — Production deployment challenges
- [Apple Developer Forums: File Provider](https://developer.apple.com/forums/tags/fileprovider?page=2) — Community-reported issues
- [macOS 12.3 File Provider challenges](https://9to5mac.com/2022/04/16/macos-12-3s-challenges-with-cloud-file-providers-highlights-the-benefits-of-managing-corporate-files-in-the-browser/) — Platform-level issues affecting all File Provider apps

### Project-Specific Context
- `.planning/PROJECT.md` — DS3 Drive project requirements and constraints
- `.planning/codebase/CONCERNS.md` — Existing bugs and technical debt analysis
- `.planning/codebase/COMPETITIVE_LANDSCAPE.md` — Apple File Provider best practices from competitors
