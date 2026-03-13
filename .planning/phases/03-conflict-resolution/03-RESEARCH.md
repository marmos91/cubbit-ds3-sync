# Phase 3: Conflict Resolution - Research

**Researched:** 2026-03-12
**Domain:** NSFileProviderReplicatedExtension conflict detection, S3 ETag-based version comparison, conflict copy creation
**Confidence:** HIGH

## Summary

Phase 3 adds conflict detection and resolution to the DS3 Drive File Provider extension. The core mechanism is straightforward: before any write operation (upload, delete, rename, move), perform a HEAD request to S3 to compare the stored ETag against the remote ETag. When a mismatch is detected, the local version is uploaded as a conflict copy with a descriptive filename, and the system re-fetches the remote version for the original filename via `signalEnumerator`.

The codebase is well-prepared for this phase. The `SyncStatus.conflict` enum case already exists but is unused. The `MetadataStore.upsertItem()` accepts sync status and ETag parameters. The `S3Lib.remoteS3Item()` already performs HEAD requests but currently omits the ETag from its response. The existing `NotificationManager` and `DistributedNotificationCenter` IPC pattern provides the communication channel for conflict notifications from extension to main app.

**Primary recommendation:** Implement conflict detection as a pre-flight check layer in each CRUD method of `FileProviderExtension`, using `S3Lib.remoteS3Item()` (after adding ETag extraction) for version comparison. Follow the Dropbox convention: remote version keeps the original filename, local version becomes the conflict copy. Use `signalEnumerator(for:)` after conflict copy upload to trigger re-enumeration.

<user_constraints>

## User Constraints (from CONTEXT.md)

### Locked Decisions
- Remote version keeps the original filename (Dropbox pattern -- server is canonical)
- Local version is uploaded to S3 as the conflict copy
- Conflict copy naming: `"filename (Conflict on [hostname] [YYYY-MM-DD HH-MM-SS]).ext"` -- uses Mac hostname via `Host.current().localizedName` and includes time-of-day
- Conflict copy placed in the same folder as the original (side-by-side in Finder)
- Each conflicting version creates its own copy (1 per conflict, no limit)
- Conflict copies are regular files after creation -- no special protection
- After uploading local as conflict copy, signal File Provider to re-fetch remote version for the original filename
- Conflict copy gets its own SyncedItem in MetadataStore with `syncStatus = .conflict`
- Both enumeration-time and write-time detection (dual protection)
- HEAD-then-upload approach (not conditional PUT with If-Match)
- Accept the millisecond race condition window between HEAD and PUT
- Always persist ETag to MetadataStore after every successful upload
- Extract ETag from remoteS3Item() HEAD response -- currently missing
- Local edit vs remote delete: re-upload the local version to S3 (user's edit wins)
- Local delete vs remote edit: keep remote version, cancel local delete, return NSFileProviderError
- Both sides delete: silently succeed -- treat 404/NoSuchKey as success
- macOS notification via UNUserNotificationCenter with IPC from extension to main app
- Batching: individual notifications for 1-3 conflicts; if >3, single summary
- Clicking notification reveals the conflict copy in Finder
- No grace period for conflict detection -- ETag comparison is definitive
- If HEAD request fails (network error), block upload and return transient error for File Provider retry
- Skip folder operations -- S3 folders are key prefixes, no content conflicts possible
- Unit tests for conflict detection paths, reuse in-memory SwiftData container pattern

### Claude's Discretion
- Exact NSFileProviderError codes for conflict scenarios (recommendation below)
- S3Item.itemVersion handling -- whether metadataVersion should differ from contentVersion
- SyncEngine internal conflict detection flow design
- Conflict copy upload retry strategy (reuse existing withRetries pattern)
- Exact notification content wording and formatting
- How to detect "local file is modified" during enumeration (file hash comparison approach)
- Exact choice of which modifyItem/deleteItem/rename operations get checks

### Deferred Ideas (OUT OF SCOPE)
- Conflict resolution UI (keep/discard/merge) -- Phase 5 (UX Polish)
- Conflict history view in main app -- Phase 5
- Menu bar conflict count badge -- Phase 5

</user_constraints>

<phase_requirements>

## Phase Requirements

| ID | Description | Research Support |
|----|-------------|-----------------|
| SYNC-02 | Conflict detection compares local NSFileProviderItemVersion against remote ETag via HEAD request before writes | HEAD request via `S3Lib.remoteS3Item()` returns ETag from `HeadObjectOutput.eTag`. Compare against stored ETag in MetadataStore via `fetchItemEtag()`. Pre-flight check in modifyItem, createItem, deleteItem. |
| SYNC-03 | Conflict copies created with pattern "filename (Conflict on [device] [date]).ext" when versions diverge | Upload local version with conflict-named key via existing `putS3Item()`. Record in MetadataStore with `.conflict` status. Signal enumerator for re-fetch. |

</phase_requirements>

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| FileProvider (Apple) | macOS 15+ | NSFileProviderReplicatedExtension conflict handling | Native API for file sync -- modifyItem baseVersion parameter is the conflict detection hook |
| SotoS3 | 6.8.0+ | HEAD requests for ETag comparison, PUT for conflict copy upload | Already in use; `HeadObjectOutput.eTag` and `PutObjectOutput.eTag` fields available |
| SwiftData | macOS 15+ | MetadataStore persistence of conflict status | Already in use; `SyncStatus.conflict` case defined |
| UserNotifications | macOS 15+ | UNUserNotificationCenter for conflict notifications in main app | Standard Apple framework for actionable notifications |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| Foundation (Host) | macOS 15+ | `Host.current().localizedName` for device hostname in conflict filename | Called during conflict copy name generation |
| os.log | macOS 15+ | Structured conflict logging | Existing pattern; add `.conflict` to log messages |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| HEAD-then-upload | S3 conditional PUT (If-Match) | Better atomicity but may not be supported by all S3-compatible services including Cubbit gateway |
| ETag comparison | LastModified comparison | ETags are canonical version identifiers in S3; timestamps can be unreliable across services |

**Installation:** No new dependencies needed. All libraries already in the project.

## Architecture Patterns

### Recommended Project Structure
```
DS3DriveProvider/
  FileProviderExtension.swift         # Add pre-flight conflict checks to modifyItem/createItem/deleteItem
  S3Lib.swift                         # Add ETag extraction to remoteS3Item(), add conflict copy upload method
  S3Item+Metadata.swift               # Already has etag field
  NotificationsManager.swift          # Extend for conflict IPC notifications

DS3Lib/Sources/DS3Lib/
  Metadata/
    MetadataStore.swift               # Add fetchMaterializedConflictCandidates() query
    SyncedItem.swift                  # SyncStatus.conflict already defined
  Sync/
    SyncEngine.swift                  # Add enumeration-time conflict detection
    ConflictManager.swift             # NEW: Conflict detection + copy creation logic (extracted)
  Utils/
    ConflictNaming.swift              # NEW: Pure function for conflict filename generation
  Constants/
    DefaultSettings.swift             # Add conflict notification name constants

DS3Drive/ (main app)
  ConflictNotificationHandler.swift   # NEW: Listen for conflict IPC, show UNUserNotification
```

### Pattern 1: Pre-flight ETag Check (Write-time Detection)
**What:** Before uploading a modified file, perform HEAD request and compare ETags.
**When to use:** Every modifyItem (content change), createItem, deleteItem, rename/move.
**Example:**
```swift
// In FileProviderExtension.modifyItem, before upload:
let remoteItem = try await s3Lib.remoteS3Item(for: s3Item.itemIdentifier, drive: drive)
let remoteETag = remoteItem.metadata.etag  // NEW: extracted from HEAD response
let storedETag = try? await metadataStore?.fetchItemEtag(
    byKey: s3Item.itemIdentifier.rawValue, driveId: drive.id
)

if let remoteETag, let storedETag, remoteETag != storedETag {
    // Conflict detected -- create conflict copy instead of overwriting
    let conflictKey = ConflictNaming.conflictKey(
        originalKey: s3Item.itemIdentifier.rawValue,
        hostname: Host.current().localizedName ?? "Unknown"
    )
    // Upload local version as conflict copy
    let conflictItem = S3Item(
        identifier: NSFileProviderItemIdentifier(conflictKey),
        drive: drive,
        objectMetadata: s3Item.metadata
    )
    try await s3Lib.putS3Item(conflictItem, fileURL: contents)
    // Record conflict in MetadataStore
    try? await metadataStore?.upsertItem(
        s3Key: conflictKey, driveId: drive.id,
        syncStatus: .conflict
    )
    // Signal enumerator to re-fetch remote version
    self.signalChanges()
    // Return the conflict item to the system
    cb.handler(conflictItem, NSFileProviderItemFields(), false, nil)
    return
}
// No conflict -- proceed with normal upload
```

### Pattern 2: Enumeration-time Conflict Detection
**What:** During SyncEngine reconciliation, detect modified files that have changed both locally and remotely.
**When to use:** In `enumerateChanges` when SyncEngine finds a modified key AND the local file is materialized.
**Example:**
```swift
// In SyncEngine.reconcile(), after computing modifiedKeys:
// For each modified key, check if the local file is materialized and has local changes
let materializedItems = try await metadataStore.fetchMaterializedItems(driveId: driveId)
for key in modifiedKeys {
    if materializedItems.contains(key) {
        // This file was downloaded and potentially edited locally
        // while the remote version also changed
        conflictKeys.insert(key)
    }
}
```

### Pattern 3: Conflict Copy Naming (Pure Function)
**What:** Generate a deterministic conflict filename from original key, hostname, and timestamp.
**When to use:** Whenever a conflict copy needs to be created.
**Example:**
```swift
// ConflictNaming.swift -- pure utility, no dependencies
enum ConflictNaming {
    static func conflictKey(originalKey: String, hostname: String, date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        let dateStr = formatter.string(from: date)

        let components = originalKey.split(separator: "/", omittingEmptySubsequences: false)
        let filename = String(components.last ?? "")

        let dotIndex = filename.lastIndex(of: ".")
        let name: String
        let ext: String
        if let dotIndex {
            name = String(filename[filename.startIndex..<dotIndex])
            ext = String(filename[dotIndex...])  // includes the dot
        } else {
            name = filename
            ext = ""
        }

        let conflictFilename = "\(name) (Conflict on \(hostname) \(dateStr))\(ext)"

        // Reconstruct full key with parent path
        if components.count > 1 {
            let parent = components.dropLast().joined(separator: "/")
            return "\(parent)/\(conflictFilename)"
        }
        return conflictFilename
    }
}
```

### Pattern 4: IPC for Conflict Notifications
**What:** Extension posts conflict details via DistributedNotificationCenter; main app listens and shows macOS notification.
**When to use:** After every conflict copy is created.
**Example:**
```swift
// Extension side (NotificationManager extension):
func sendConflictNotification(filename: String, conflictKey: String, driveId: UUID) {
    let info: [String: String] = [
        "filename": filename,
        "conflictKey": conflictKey,
        "driveId": driveId.uuidString
    ]
    guard let data = try? JSONEncoder().encode(info),
          let string = String(data: data, encoding: .utf8) else { return }
    DistributedNotificationCenter.default().post(
        Notification(name: .conflictDetected, object: string)
    )
}

// Main app side (ConflictNotificationHandler):
// Listen for .conflictDetected, batch, then show UNUserNotification
```

### Anti-Patterns to Avoid
- **Returning custom error types to File Provider system:** ONLY use `NSFileProviderErrorDomain` and `NSCocoaErrorDomain`. Custom errors cause "unsupported" system logs (from MEMORY.md).
- **Blocking on MetadataStore writes during conflict handling:** Use `try?` pattern consistent with Phase 2 to avoid blocking S3 operations on metadata failures.
- **Creating conflict copy without signaling enumerator:** The system will not re-fetch the remote version unless `signalEnumerator(for:)` is called.
- **Checking folders for conflicts:** S3 folders are key prefixes with no content -- skip all folder operations.
- **Using `Host.current().localizedName` in a tight loop:** Cache hostname once per extension lifecycle (it rarely changes).

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Conflict filename parsing/generation | Custom regex-based parser | Dedicated `ConflictNaming` pure utility | Edge cases: files without extensions, dots in names, nested paths, unicode |
| Notification batching | Custom timer-based batching | DispatchWorkItem debounce pattern (already in NotificationManager) | Race conditions in concurrent conflict detection |
| ETag comparison normalization | String equality | Normalize quotes first (`etag.replacingOccurrences(of: "\"", with: "")`) | S3 ETags sometimes wrapped in quotes, sometimes not |
| Retry for conflict copy upload | Custom retry loop | Existing `withRetries()` / `withExponentialBackoff()` in ControlFlow.swift | Already tested, handles backoff and jitter |
| Device hostname | Manual sysctl calls | `Host.current().localizedName ?? ProcessInfo.processInfo.hostName` | Standard Foundation API, handles localization |

**Key insight:** The conflict detection logic is straightforward (ETag comparison), but the edge cases in naming, S3 error handling (404 on HEAD = file deleted), and File Provider error code mapping require careful attention. Each operation type (modify, create, delete, rename) has different conflict semantics.

## Common Pitfalls

### Pitfall 1: ETag Quote Wrapping Inconsistency
**What goes wrong:** S3 returns ETags sometimes with surrounding quotes (`"abc123"`) and sometimes without (`abc123`). Direct string comparison fails.
**Why it happens:** The S3 spec defines ETags as opaque strings, but different S3-compatible services (and Soto's parsing) handle quotes differently.
**How to avoid:** Strip surrounding quotes from both sides before comparison. Create a normalized comparison helper.
**Warning signs:** Conflicts detected on every sync cycle even when files haven't changed.

### Pitfall 2: HEAD 404 During Delete Conflict Check
**What goes wrong:** When checking if a file was modified before deleting, HEAD returns 404 (file already deleted remotely). If treated as an error, deletion fails.
**Why it happens:** Another client deleted the file between local delete request and HEAD check.
**How to avoid:** Catch `NoSuchKey`/404 from HEAD specifically. Per CONTEXT.md: "Both sides delete: silently succeed -- treat 404/NoSuchKey from S3 as success."
**Warning signs:** Delete operations failing with "not found" errors instead of succeeding silently.

### Pitfall 3: Conflict Copy Upload Fails Silently
**What goes wrong:** The conflict copy upload to S3 fails (network error, quota), but the original file is not protected.
**Why it happens:** The extension continues processing after an upload failure without ensuring the local version is preserved.
**How to avoid:** If conflict copy upload fails, return a transient error (`NSFileProviderError(.serverUnreachable)`) so the File Provider system retries the entire operation later.
**Warning signs:** Data loss -- local edits disappear without conflict copy being created.

### Pitfall 4: File Provider System Not Recognizing New Conflict File
**What goes wrong:** Conflict copy uploaded to S3 successfully, but never appears in Finder.
**Why it happens:** `signalEnumerator(for:)` not called, or called on wrong container. The File Provider system only discovers new items through enumeration.
**How to avoid:** Always call `signalEnumerator(for: .workingSet)` after uploading conflict copy. The subsequent `enumerateChanges` call will discover the conflict file.
**Warning signs:** Conflict copy exists in S3 (visible via CLI) but not in Finder.

### Pitfall 5: UNUserNotificationCenter in File Provider Extension
**What goes wrong:** Extension tries to show user notifications directly but crashes or silently fails.
**Why it happens:** File Provider extensions run in a sandboxed process with limited notification capabilities. The extension may not have the proper entitlements to show user-facing notifications.
**How to avoid:** Per CONTEXT.md decision: extension posts via `DistributedNotificationCenter`, main app listens and shows `UNUserNotificationCenter` notification. Best effort -- if main app is not running, no notification (conflict copy still created).
**Warning signs:** Notification permission errors in system logs from the extension process.

### Pitfall 6: Race Between Conflict Copy Upload and signalEnumerator
**What goes wrong:** `signalEnumerator` fires before conflict copy upload completes. Re-enumeration doesn't find the new file.
**Why it happens:** `signalEnumerator` is async; if called before the PUT completes, the enumerator won't see the file.
**How to avoid:** Call `signalEnumerator(for:)` only AFTER the conflict copy upload (and MetadataStore write) completes.
**Warning signs:** Intermittent conflict copies not appearing in Finder.

### Pitfall 7: baseVersion vs Stored ETag Confusion
**What goes wrong:** Using `modifyItem`'s `baseVersion` parameter (provided by the system) instead of stored ETag for conflict detection.
**Why it happens:** The system's `baseVersion` reflects the last version it knows about, but for S3-based sync, the authoritative version is the remote ETag from a HEAD request.
**How to avoid:** Always do a fresh HEAD request to S3. The `baseVersion` from the system is useful as a sanity check but the remote HEAD is the source of truth for conflict detection.
**Warning signs:** False conflicts or missed conflicts due to stale version data.

## Code Examples

### ETag Extraction from HEAD Response (Missing Today)
```swift
// S3Lib.remoteS3Item() -- add eTag to returned S3Item.Metadata
// Current code omits eTag from HeadObjectOutput. Fix:
func remoteS3Item(
    for identifier: NSFileProviderItemIdentifier,
    drive: DS3Drive
) async throws -> S3Item {
    // ... existing request setup ...
    let response = try await self.s3.headObject(request)
    let fileSize = response.contentLength ?? 0

    return S3Item(
        identifier: identifier,
        drive: drive,
        objectMetadata: S3Item.Metadata(
            etag: response.eTag,        // NEW: extract ETag
            contentType: response.contentType,
            lastModified: response.lastModified,
            versionId: response.versionId,
            size: NSNumber(value: fileSize)
        )
    )
}
```

### ETag Persistence After Upload
```swift
// S3Lib.putS3ItemStandard() -- persist ETag after successful upload
let putObjectResponse = try await self.s3.putObject(request)
let eTag = putObjectResponse.eTag ?? ""
self.logger.debug("Got ETag \(eTag) for \(key)")

// Return ETag so caller can persist it (new return type)
// Or: modify putS3Item to accept MetadataStore and drive for direct persistence
```

### Delete Conflict Handling
```swift
// In FileProviderExtension.deleteItem:
// Check if remote file was modified before deleting
do {
    let remoteItem = try await s3Lib.remoteS3Item(for: identifier, drive: drive)
    let remoteETag = remoteItem.metadata.etag
    let storedETag = try? await metadataStore?.fetchItemEtag(
        byKey: identifier.rawValue, driveId: drive.id
    )

    if let remoteETag, let storedETag, remoteETag != storedETag {
        // Remote was modified -- cancel delete, file reappears at next sync
        self.logger.warning("Delete cancelled: remote ETag changed for \(identifier.rawValue)")
        cb.handler(NSFileProviderError(.cannotSynchronize) as NSError)
        return
    }
    // ETags match or no stored ETag -- proceed with delete
    try await s3Lib.deleteS3Item(s3Item, withProgress: progress)
} catch let s3Error as S3ErrorType where s3Error.errorCode == "NoSuchKey" {
    // Both sides deleted -- treat as success
    self.logger.debug("File already deleted remotely, treating as success")
    try? await metadataStore?.deleteItem(byKey: identifier.rawValue, driveId: drive.id)
    cb.handler(nil)
    return
}
```

### Conflict Notification via IPC
```swift
// Extension: post conflict detail via DistributedNotificationCenter
struct ConflictInfo: Codable {
    let driveId: UUID
    let originalFilename: String
    let conflictKey: String
}

// Main app: listen and show UNUserNotification
let content = UNMutableNotificationContent()
content.title = "Conflict detected"
content.body = "\(info.originalFilename) -- Both versions saved."
content.categoryIdentifier = "CONFLICT_CATEGORY"
content.userInfo = ["conflictKey": info.conflictKey]
content.sound = .default

let request = UNNotificationRequest(
    identifier: UUID().uuidString,
    content: content,
    trigger: nil  // Deliver immediately
)
try await UNUserNotificationCenter.current().add(request)
```

## Recommendations for Claude's Discretion Items

### NSFileProviderError Codes for Conflict Scenarios
**Recommendation:** Use `NSFileProviderError(.cannotSynchronize)` as the conflict error code.
- When a delete is cancelled due to remote modification: `.cannotSynchronize` -- the system retries, and next enumeration will show the updated file.
- When a HEAD request fails (network error): `.serverUnreachable` -- system retries with backoff.
- When conflict copy upload fails: `.serverUnreachable` -- system retries entire operation.
- There is no `.versionOutOfDate` in the current NSFileProviderError.Code enum. The closest is `.cannotSynchronize`.
**Confidence:** MEDIUM -- Apple's documentation does not prescribe specific error codes for custom conflict handling.

### S3Item.itemVersion Handling
**Recommendation:** Keep using ETag for both `contentVersion` and `metadataVersion` (current behavior). This is appropriate because S3 ETags represent content identity. When a conflict is detected and resolved (conflict copy created), the S3Item returned to the system will have the new ETag from the conflict copy upload, which naturally updates the version the system tracks.
**Confidence:** HIGH -- current pattern is consistent with S3 semantics.

### Conflict Copy Upload Retry Strategy
**Recommendation:** Use `withRetries(retries: 3)` from existing `ControlFlow.swift`. The conflict copy upload is critical (data loss if it fails), so use simple retry without backoff delay. If all retries fail, return `.serverUnreachable` to let File Provider retry the entire operation.
**Confidence:** HIGH -- existing pattern is proven.

### Detecting "Local File is Modified" During Enumeration
**Recommendation:** Use `isMaterialized` flag from MetadataStore. If `isMaterialized == true` AND the remote ETag differs from stored ETag, this item is a conflict candidate. Full file hash comparison is expensive and unnecessary -- the combination of "materialized + remote changed" is sufficient to flag potential conflicts. The File Provider system tracks local modifications and will call `modifyItem` when the user saves, which is where the actual HEAD check happens.
**Confidence:** HIGH -- avoids expensive file hashing; leverages existing infrastructure.

### Notification Wording
**Recommendation:**
- Single: "Conflict detected: report.pdf -- Both versions saved."
- Batch: "5 conflicts detected -- Click to view in Finder."
- Category: "CONFLICT_CATEGORY" with action "Show in Finder"
**Confidence:** HIGH -- consistent with Dropbox/OneDrive notification patterns.

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| S3 eventual consistency | S3 strong read-after-write consistency | AWS Dec 2020 | ETags from HEAD are immediately consistent after PUT -- no grace period needed |
| NSFileProviderExtension (non-replicated) | NSFileProviderReplicatedExtension | macOS 11+ (2020) | baseVersion parameter in modifyItem enables version-aware conflict detection |
| Custom file sync daemon | File Provider framework | macOS 12+ (2021) | System manages file materialization, eviction; extension only needs CRUD + enumeration |

**Deprecated/outdated:**
- Non-replicated File Provider extensions: The project correctly uses `NSFileProviderReplicatedExtension`
- Manual sync anchor management: The project uses SwiftData-backed SyncAnchorRecord (Phase 2)

## Open Questions

1. **ETag format from Cubbit S3 gateway**
   - What we know: Standard S3 returns ETags as quoted strings (e.g., `"abc123"`)
   - What's unclear: Whether Cubbit's gateway strips quotes or adds extra formatting
   - Recommendation: Implement quote-stripping normalization. Test with actual Cubbit responses during integration testing.

2. **Host.current().localizedName in sandboxed extension**
   - What we know: Foundation's `Host.current().localizedName` returns the user-facing hostname on macOS
   - What's unclear: Whether File Provider extension sandbox restricts this API
   - Recommendation: Use with fallback: `Host.current().localizedName ?? ProcessInfo.processInfo.hostName`. Cache the result at extension init.

3. **UNUserNotificationCenter permission in main app**
   - What we know: Main app needs to request notification permission from user
   - What's unclear: Whether the app already requests this (Phase 5 concern)
   - Recommendation: Add permission request at app launch. If denied, conflict copies still created -- just no notification. This is the "best effort" pattern from CONTEXT.md.

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | XCTest + SwiftData (Swift 6.0) |
| Config file | DS3Lib/Package.swift (testTarget: DS3LibTests) |
| Quick run command | `swift test --package-path DS3Lib` |
| Full suite command | `swift test --package-path DS3Lib` |

### Phase Requirements to Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| SYNC-02 | ETag mismatch detection triggers conflict instead of overwrite | unit | `swift test --package-path DS3Lib --filter ConflictDetectionTests` | No -- Wave 0 |
| SYNC-02 | HEAD request failure returns transient error | unit | `swift test --package-path DS3Lib --filter ConflictDetectionTests` | No -- Wave 0 |
| SYNC-02 | Folder operations skip conflict check | unit | `swift test --package-path DS3Lib --filter ConflictDetectionTests` | No -- Wave 0 |
| SYNC-03 | Conflict copy naming generates correct pattern | unit | `swift test --package-path DS3Lib --filter ConflictNamingTests` | No -- Wave 0 |
| SYNC-03 | Conflict copy naming handles files without extensions | unit | `swift test --package-path DS3Lib --filter ConflictNamingTests` | No -- Wave 0 |
| SYNC-03 | Conflict copy naming handles nested paths | unit | `swift test --package-path DS3Lib --filter ConflictNamingTests` | No -- Wave 0 |
| SYNC-03 | Conflict copy recorded in MetadataStore with .conflict status | unit | `swift test --package-path DS3Lib --filter ConflictDetectionTests` | No -- Wave 0 |
| SYNC-02 | Delete cancelled when remote ETag changed | unit | `swift test --package-path DS3Lib --filter ConflictDetectionTests` | No -- Wave 0 |
| SYNC-02 | Both-sides-delete treated as success | unit | `swift test --package-path DS3Lib --filter ConflictDetectionTests` | No -- Wave 0 |
| SYNC-02 | Local edit vs remote delete re-uploads local version | unit | `swift test --package-path DS3Lib --filter ConflictDetectionTests` | No -- Wave 0 |

### Sampling Rate
- **Per task commit:** `swift test --package-path DS3Lib`
- **Per wave merge:** `swift test --package-path DS3Lib`
- **Phase gate:** Full suite green before `/gsd:verify-work`

### Wave 0 Gaps
- [ ] `DS3Lib/Tests/DS3LibTests/ConflictNamingTests.swift` -- covers SYNC-03 naming logic
- [ ] `DS3Lib/Tests/DS3LibTests/ConflictDetectionTests.swift` -- covers SYNC-02 ETag comparison, delete conflicts, error handling
- [ ] No new framework install needed -- XCTest already configured

## Sources

### Primary (HIGH confidence)
- Codebase analysis: `FileProviderExtension.swift`, `S3Lib.swift`, `MetadataStore.swift`, `SyncEngine.swift`, `SyncedItem.swift` -- direct code review
- Soto S3 shapes: `HeadObjectOutput.eTag` field confirmed in `DS3Lib/.build/checkouts/soto/Sources/Soto/Services/S3/S3_shapes.swift`
- [Claudio Cambra - Build File Provider Sync](https://claudiocambra.com/posts/build-file-provider-sync/) -- Conflict handling pattern: create conflict copy, signal enumerator
- [NSFileProviderError.Code | Apple Developer Documentation](https://developer.apple.com/documentation/fileprovider/nsfileprovidererror/code) -- Available error codes
- [NSFileProviderReplicatedExtension | Apple Developer Documentation](https://developer.apple.com/documentation/fileprovider/nsfileproviderreplicatedextension) -- baseVersion parameter semantics

### Secondary (MEDIUM confidence)
- [Apple Developer Forums - File Provider](https://developer.apple.com/forums/thread/729541) -- Error handling patterns
- [UNUserNotificationCenter | Apple Developer Documentation](https://developer.apple.com/documentation/usernotifications/unusernotificationcenter) -- Notification framework
- [Apple Developer Forums - UNNotification from extension](https://developer.apple.com/forums/thread/679326) -- Extension notification limitations
- [How to Work with File Provider API | Apriorit](https://www.apriorit.com/dev-blog/730-mac-how-to-work-with-the-file-provider-for-macos) -- File Provider patterns
- [Host.current().localizedName | Apple Developer Documentation](https://developer.apple.com/documentation/foundation/nshost/1409624-localizedname) -- Device hostname API

### Tertiary (LOW confidence)
- None -- all findings verified with primary or secondary sources

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH - No new dependencies; all APIs verified in existing codebase and Apple docs
- Architecture: HIGH - Pattern directly from Apple File Provider documentation (conflict copy + signalEnumerator)
- Pitfalls: HIGH - Based on known File Provider extension constraints (MEMORY.md) and S3 ETag behavior
- Conflict naming: HIGH - Pure string manipulation, well-defined spec from CONTEXT.md
- Notification IPC: MEDIUM - DistributedNotificationCenter pattern exists, but UNUserNotificationCenter permission flow untested

**Research date:** 2026-03-12
**Valid until:** 2026-04-12 (stable APIs, no fast-moving dependencies)
