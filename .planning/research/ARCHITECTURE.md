# Architecture Patterns

**Domain:** macOS File Provider sync application with S3 backend
**Researched:** 2026-03-11
**Confidence:** MEDIUM

## Recommended Architecture

### Three-Layer Sync Model

Production File Provider sync applications follow a **three-state architecture**:

```
┌─────────────────────────────────────────────────────────────┐
│                      REMOTE STATE                            │
│  (S3 Bucket - Authoritative Source of Truth)                │
│  - Objects with ETag, LastModified                           │
│  - Bucket versioning metadata                                │
└──────────────────┬──────────────────────────────────────────┘
                   │
                   │ Sync via S3 API
                   ↓
┌─────────────────────────────────────────────────────────────┐
│                    MIDDLE STATE                              │
│  (File Provider Extension - Sync Broker)                     │
│  - Local metadata DB (SwiftData)                             │
│  - Tracks known remote state                                 │
│  - Detects local vs remote divergence                        │
│  - Conflict resolution logic                                 │
└──────────────────┬──────────────────────────────────────────┘
                   │
                   │ NSFileProviderReplicatedExtension protocol
                   ↓
┌─────────────────────────────────────────────────────────────┐
│                     LOCAL STATE                              │
│  (macOS FileProvider Framework - System Managed)             │
│  - Physical files on disk                                    │
│  - Finder integration                                        │
│  - User-visible filesystem                                   │
└─────────────────────────────────────────────────────────────┘
```

**Key principle:** The File Provider Extension is the "middle-man" responsible for reconciling remote (S3) and local (macOS filesystem) states. Your job is to track what has changed, where it has changed, and how to reconcile changes on both sides.

### Process Isolation Model

```
┌────────────────────────────────────────────────────────────┐
│                     MAIN APP PROCESS                        │
│  CubbitDS3Sync.app                                          │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  SwiftUI Views (Login, Setup Wizard, Tray Menu)     │  │
│  │  DS3Authentication (Challenge-response auth)        │  │
│  │  DS3DriveManager (Drive lifecycle management)       │  │
│  │  AppStatusManager (UI state aggregation)            │  │
│  └──────────────────────────────────────────────────────┘  │
│                           │                                 │
│                           │ Writes to                       │
│                           ↓                                 │
│  ┌──────────────────────────────────────────────────────┐  │
│  │        App Group Container (Shared)                  │  │
│  │  - SwiftData container (metadata.db)                 │  │
│  │  - UserDefaults (auth tokens, drive configs)        │  │
│  │  - UNIX domain sockets (optional XPC)               │  │
│  └──────────────────────────────────────────────────────┘  │
└────────────────────────────────────────────────────────────┘
                           ↑
                           │ Reads from
                           │
┌────────────────────────────────────────────────────────────┐
│              FILE PROVIDER EXTENSION PROCESS                │
│  Provider.appex (one process per domain/drive)              │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  FileProviderExtension                               │  │
│  │    (NSFileProviderReplicatedExtension)               │  │
│  │                                                       │  │
│  │  ┌────────────┐  ┌────────────┐  ┌───────────────┐  │  │
│  │  │ S3 Sync    │  │ Metadata   │  │ Enumerator    │  │  │
│  │  │ Engine     │  │ Tracker    │  │ (Changes)     │  │  │
│  │  └────────────┘  └────────────┘  └───────────────┘  │  │
│  │                                                       │  │
│  │  ┌────────────┐  ┌────────────┐  ┌───────────────┐  │  │
│  │  │ Upload     │  │ Download   │  │ Conflict      │  │  │
│  │  │ Manager    │  │ Manager    │  │ Resolver      │  │  │
│  │  └────────────┘  └────────────┘  └───────────────┘  │  │
│  └──────────────────────────────────────────────────────┘  │
│                           │                                 │
│                           │ Signals via                     │
│                           ↓                                 │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  DistributedNotificationCenter                       │  │
│  │  (Broadcasts sync status to main app)                │  │
│  └──────────────────────────────────────────────────────┘  │
└────────────────────────────────────────────────────────────┘
```

**Critical:** Each File Provider domain (drive) runs in a **separate process**. This means:
- One metadata database per domain to avoid concurrent access conflicts
- No shared in-memory state between extension instances
- All communication via App Group container or DistributedNotificationCenter
- Extension can run even when main app is closed

## Component Boundaries

### Main App Components

| Component | Responsibility | Depends On | Exposes To |
|-----------|---------------|------------|------------|
| **DS3Authentication** | Challenge-response auth, token lifecycle, 2FA | IAM API, KeychainAccess (for private keys) | All UI layers, extension via SharedData |
| **DS3DriveManager** | Drive lifecycle (add/remove), FileProvider domain registration, sync status aggregation | NSFileProviderManager, SharedData, DistributedNotificationCenter | UI (Setup Wizard, Tray Menu) |
| **AppStatusManager** | UI-visible status aggregation across all drives | DS3DriveManager | Tray Menu, Main Window |
| **DS3SDK** | API client for Composer Hub (projects, tenants, S3 endpoint discovery) | IAM tokens from DS3Authentication | Setup Wizard (project selection) |
| **SharedData** | Persistence layer for auth tokens, drive configs, API keys | App Group UserDefaults, SwiftData container | All components, extension |
| **Setup Wizard (SyncSetupViewModel)** | Multi-step drive creation flow | DS3SDK (projects), S3 client (bucket browsing), DS3DriveManager | Main Window |

### File Provider Extension Components

| Component | Responsibility | Depends On | Exposes To |
|-----------|---------------|------------|------------|
| **FileProviderExtension** | NSFileProviderReplicatedExtension implementation, delegates all FileProvider protocol methods | All components below | macOS FileProvider framework |
| **S3SyncEngine** | Orchestrates sync cycles: detect remote changes → compare with local state → resolve conflicts → execute transfers | MetadataTracker, S3Client, DownloadManager, UploadManager | FileProviderExtension |
| **MetadataTracker** | SwiftData-backed state tracking: itemIdentifier → (ETag, LastModified, sync status, local hash) | SwiftData container in App Group | S3SyncEngine, Enumerators |
| **S3Client (S3Lib)** | S3 API wrapper (Soto): list, get, put, delete, multipart upload | Soto S3 SDK, API keys from SharedData | S3SyncEngine, Enumerators |
| **DownloadManager** | Manages download queue, progress tracking, chunked downloads for large files | S3Client, MetadataTracker | S3SyncEngine |
| **UploadManager** | Manages upload queue, multipart uploads (>5MB), progress tracking | S3Client, MetadataTracker | S3SyncEngine |
| **ConflictResolver** | Detects conflicts (ETag mismatch), creates conflict copies, signals working set changes | MetadataTracker | S3SyncEngine |
| **S3Enumerator** | Lists S3 objects (folders, working set), returns NSFileProviderItem instances | S3Client, MetadataTracker | FileProviderExtension |

### Shared Components (DS3Lib)

| Component | Responsibility | Used By |
|-----------|---------------|---------|
| **DS3Drive model** | Drive configuration: domainIdentifier, SyncAnchor (bucket/prefix), API keys | Main app, Extension |
| **SyncAnchor model** | Bucket/prefix tuple defining sync root | Main app, Extension |
| **AccountSession model** | Auth tokens, refresh tokens, tenant ID | Main app, Extension |
| **NotificationManager** | DistributedNotificationCenter wrapper for extension → app communication | Extension (sends), Main app (receives) |

## Data Flow

### 1. Authentication and Drive Setup Flow

```
User enters credentials
    ↓
LoginViewModel → DS3Authentication.login()
    ↓
Challenge-response exchange (Curve25519/ED25519)
    ↓
Store AccountSession in SharedData (App Group UserDefaults)
    ↓
Navigate to Setup Wizard
    ↓
User selects Project → SyncSetupViewModel → DS3SDK.fetchProjects()
    ↓
User selects Bucket/Prefix → S3Client.listObjects() via wizard
    ↓
User names drive → DS3DriveManager.addDrive()
    ↓
Generate API keys → DS3SDK.createAPIKeys()
    ↓
Store DS3Drive + API keys in SharedData
    ↓
Write SwiftData metadata DB in App Group container
    ↓
Register NSFileProviderDomain → NSFileProviderManager.add(domain:)
    ↓
macOS spawns extension process, loads domain
```

**Key decision point:** Main app creates API keys during setup, not on first sync. Extension assumes keys exist.

### 2. Remote Change Detection Flow (Extension)

```
Timer/Signal triggers sync cycle in S3SyncEngine
    ↓
Load last sync anchor from MetadataTracker (SwiftData)
    ↓
S3Client.listObjectsV2(bucket, prefix, continuationToken)
    ↓
For each S3 object:
    Query MetadataTracker for local record by itemIdentifier
    ↓
    Compare S3 ETag with stored ETag
    ↓
    If ETag differs:
        - Mark as "remote modified"
        - Update MetadataTracker with new ETag, LastModified
    ↓
    If object not in MetadataTracker:
        - Mark as "remote new"
        - Create new metadata record
    ↓
    If local record exists but not in S3 list:
        - Mark as "remote deleted"
    ↓
Save new sync anchor (S3 continuationToken or timestamp)
    ↓
Signal NSFileProviderManager.signalEnumerator(for: .workingSet)
    ↓
FileProvider framework calls enumerator(for: .workingSet)
    ↓
S3Enumerator returns NSFileProviderItem instances with updated version identifiers
    ↓
macOS updates Finder UI
```

**Critical:** Remote change detection is PULL-based (polling S3), not push. Implement intelligent polling intervals: frequent when active, sparse when idle.

### 3. Local Change Detection Flow (Extension)

```
User modifies file in Finder
    ↓
macOS FileProvider framework calls:
    - modifyItem(identifier:, baseVersion:, changedFields:, contents:)
    ↓
FileProviderExtension receives callback
    ↓
Load metadata from MetadataTracker by itemIdentifier
    ↓
Compare baseVersion with stored versionIdentifier
    ↓
If baseVersion matches stored version:
    - No conflict, proceed with upload
    - UploadManager queues upload
    ↓
If baseVersion != stored version:
    - Conflict detected (remote changed between read and write)
    - ConflictResolver.createConflictCopy()
    - Signal working set enumerator
    - Return NSFileProviderError.syncAnchorExpired
    ↓
UploadManager uploads to S3
    ↓
On success:
    - Update MetadataTracker with new ETag from S3 response
    - Call completionHandler with updated NSFileProviderItem
    ↓
On failure:
    - Retry with exponential backoff
    - If persistent failure, mark as "upload pending" in MetadataTracker
    - Surface error via NSFileProviderError.serverUnreachable
```

**Key decision point:** baseVersion comparison is the conflict detection mechanism. Store ETags as versionIdentifier in NSFileProviderItemVersion.

### 4. Conflict Resolution Flow (Extension)

```
Conflict detected (baseVersion mismatch)
    ↓
Load remote S3 object metadata (ETag, LastModified)
    ↓
Load local file metadata from MetadataTracker
    ↓
Create conflict copy filename: "filename (Conflict Copy YYYY-MM-DD).ext"
    ↓
Upload local version as conflict copy to S3
    ↓
Update MetadataTracker:
    - Original item → remote ETag (remote wins for original name)
    - Conflict copy → new item with separate itemIdentifier
    ↓
Signal working set enumerator
    ↓
FileProvider returns both items to Finder
    ↓
User sees original (remote version) + conflict copy (local version)
```

**Pattern:** Dropbox-style conflict copies. Never auto-merge (S3 has no locking). Preserve both versions, let user resolve manually.

### 5. Download Flow (On-Demand Sync)

```
User opens file in Finder
    ↓
macOS FileProvider calls fetchContents(for:, version:)
    ↓
FileProviderExtension → DownloadManager.download(itemIdentifier)
    ↓
Load metadata from MetadataTracker
    ↓
S3Client.getObject(bucket, key)
    ↓
Stream to temporary file (not CloudStorage directly)
    ↓
Report Progress via NSProgress.completedUnitCount
    ↓
On completion:
    - Verify ETag matches expected
    - Calculate SHA256 hash of downloaded file
    - Update MetadataTracker (local hash, download timestamp)
    - Call completionHandler with file URL
    ↓
macOS moves file to final location in CloudStorage
```

**Critical:** Download to temp path, let system manage final location. Never write directly to CloudStorage directory.

### 6. Upload Flow (Multipart for Large Files)

```
User saves file in Finder
    ↓
macOS FileProvider calls modifyItem() with file URL
    ↓
Check file size
    ↓
If size < 5MB:
    - UploadManager.uploadSinglePart()
    - S3Client.putObject(bucket, key, body: fileData)
    ↓
If size >= 5MB:
    - UploadManager.uploadMultipart()
    - S3Client.createMultipartUpload()
    - For each 5MB chunk:
        - S3Client.uploadPart(partNumber, body: chunkData)
        - Report Progress
    - S3Client.completeMultipartUpload(uploadId, parts)
    ↓
On success:
    - Extract ETag from S3 response
    - Calculate local SHA256 hash
    - Update MetadataTracker (ETag, local hash, upload timestamp)
    - Call completionHandler with updated NSFileProviderItem
    ↓
On failure:
    - S3Client.abortMultipartUpload(uploadId)
    - Retry or mark as "upload pending"
```

**Key decision point:** Keep existing 5MB multipart threshold. Consider making configurable per network conditions later.

### 7. Extension → Main App Communication Flow

```
Extension completes sync operation
    ↓
Create DS3DriveStatusChange struct (driveID, syncStatus, error)
    ↓
NotificationManager.notifyDriveStatusChanged(statusChange)
    ↓
DistributedNotificationCenter.post(name: .driveStatusChanged, object: JSON)
    ↓
Main app DS3DriveManager receives notification
    ↓
Decode DS3DriveStatusChange
    ↓
Update @Observable state
    ↓
SwiftUI views re-render (Tray Menu updates status badge)
```

**Limitation:** DistributedNotificationCenter is broadcast-only (no request-response). For bidirectional queries, implement NSFileProviderServicing XPC service.

### 8. Multitenancy Flow

```
User enters tenant ID at login
    ↓
DS3Authentication.login(email, password, tenantID)
    ↓
Store tenant ID in AccountSession
    ↓
During drive setup:
    DS3SDK.discoverS3Endpoint(tenantID) → Composer Hub API
    ↓
Store S3 endpoint URL in DS3Drive model
    ↓
Extension loads DS3Drive, configures S3Client with tenant-specific endpoint
```

**Key decision point:** Tenant determines S3 endpoint. Store endpoint per drive, not globally (future: multi-tenant support with drives across tenants).

## SwiftData Metadata Schema

### Core Tables (Entities)

```swift
@Model
class SyncedItem {
    @Attribute(.unique) var itemIdentifier: String  // NSFileProviderItemIdentifier
    var parentItemIdentifier: String

    // Remote state
    var remoteETag: String?            // S3 ETag (version identifier)
    var remoteLastModified: Date?      // S3 LastModified timestamp
    var remoteSize: Int64?             // S3 object size in bytes

    // Local state
    var localHash: String?             // SHA256 of local file (for change detection)
    var localModificationDate: Date?   // Last local write timestamp
    var localSize: Int64?

    // Sync state
    var syncStatus: SyncStatus         // .synced, .downloading, .uploading, .conflict, .error
    var lastSyncDate: Date?
    var errorDescription: String?

    // File metadata
    var filename: String
    var contentType: String            // UTType identifier
    var isFolder: Bool

    // FileProvider metadata
    var capabilities: Int              // NSFileProviderItemCapabilities bitfield
    var downloadPolicy: String         // .downloadLazily, .downloadEagerly

    // Multipart upload tracking
    var uploadId: String?              // S3 multipart upload ID
    var uploadedParts: [Int]?          // Completed part numbers

    // Relationships
    @Relationship(deleteRule: .cascade) var children: [SyncedItem]?
}

@Model
class SyncAnchor {
    var containerType: String          // "root", "workingSet", "pendingSet"
    var anchorData: Data               // Opaque sync anchor (S3 continuationToken or timestamp)
    var lastEnumerationDate: Date
}

@Model
class ConflictCopy {
    var originalItemIdentifier: String
    var conflictCopyIdentifier: String
    var createdDate: Date
    var resolutionStatus: ConflictResolutionStatus  // .unresolved, .keepLocal, .keepRemote, .merged
}

enum SyncStatus: String, Codable {
    case synced              // Local and remote match
    case downloadPending     // Enqueued for download
    case downloading         // Download in progress
    case uploadPending       // Enqueued for upload
    case uploading           // Upload in progress
    case conflict            // Local and remote diverged
    case error               // Sync failed
    case remoteOnly          // Not downloaded (on-demand)
}

enum ConflictResolutionStatus: String, Codable {
    case unresolved
    case keepLocal
    case keepRemote
    case merged
}
```

### SwiftData Container Configuration

**Location:** App Group container (`group.io.cubbit.CubbitDS3Sync`)

**File:** `group.io.cubbit.CubbitDS3Sync/Library/Application Support/default.store`

**Configuration pattern:**

```swift
// Shared configuration (use in both main app and extension)
extension ModelContainer {
    static func shared(for drive: DS3Drive) throws -> ModelContainer {
        let schema = Schema([SyncedItem.self, SyncAnchor.self, ConflictCopy.self])

        // One database per domain to avoid concurrent access conflicts
        let storeURL = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: "group.io.cubbit.CubbitDS3Sync")!
            .appendingPathComponent("MetadataDB-\(drive.domainIdentifier).sqlite")

        let configuration = ModelConfiguration(
            url: storeURL,
            allowsSave: true,
            cloudKitDatabase: .none  // No CloudKit sync
        )

        return try ModelContainer(for: schema, configurations: configuration)
    }
}
```

**Critical:** One database file per drive (domain) to avoid concurrent write conflicts when multiple extension processes run simultaneously.

### Index Strategy

Create indexes on:
- `itemIdentifier` (primary key, unique)
- `parentItemIdentifier` (for hierarchy queries)
- `syncStatus` (for queue queries: "give me all uploadPending items")
- `remoteETag` (for conflict detection)

### Query Patterns

```swift
// Find all items needing upload
let uploadQueue = try context.fetch(
    FetchDescriptor<SyncedItem>(
        predicate: #Predicate { $0.syncStatus == .uploadPending },
        sortBy: [SortDescriptor(\.localModificationDate)]
    )
)

// Find item by identifier (most common query)
let item = try context.fetch(
    FetchDescriptor<SyncedItem>(
        predicate: #Predicate { $0.itemIdentifier == identifier }
    )
).first

// Find children of folder
let children = try context.fetch(
    FetchDescriptor<SyncedItem>(
        predicate: #Predicate { $0.parentItemIdentifier == folderIdentifier }
    )
)

// Find conflicts
let conflicts = try context.fetch(
    FetchDescriptor<ConflictCopy>(
        predicate: #Predicate { $0.resolutionStatus == .unresolved }
    )
)
```

## Sync Engine State Machine

### States

```
┌─────────────────────────────────────────────────────────────┐
│                        IDLE                                  │
│  - No pending operations                                     │
│  - Waiting for timer or signal                               │
└───────────────────────┬─────────────────────────────────────┘
                        │
                        │ Timer fires OR signalEnumerator() called
                        ↓
┌─────────────────────────────────────────────────────────────┐
│                   ENUMERATING REMOTE                         │
│  - S3 listObjectsV2() in progress                            │
│  - Building list of remote items                             │
└───────────────────────┬─────────────────────────────────────┘
                        │
                        │ List complete
                        ↓
┌─────────────────────────────────────────────────────────────┐
│                   COMPARING METADATA                         │
│  - Query MetadataTracker for each remote item                │
│  - Detect: new, modified, deleted, conflicted                │
└───────────────────────┬─────────────────────────────────────┘
                        │
                        │ Comparison complete
                        ↓
┌─────────────────────────────────────────────────────────────┐
│                   RESOLVING CONFLICTS                        │
│  - Create conflict copies                                    │
│  - Update metadata with conflict status                      │
└───────────────────────┬─────────────────────────────────────┘
                        │
                        │ Conflicts resolved
                        ↓
┌─────────────────────────────────────────────────────────────┐
│                   EXECUTING TRANSFERS                        │
│  - Downloads (parallel, priority-based)                      │
│  - Uploads (parallel, priority-based)                        │
│  - Progress tracking per item                                │
└───────────────────────┬─────────────────────────────────────┘
                        │
                        │ Transfers complete OR error
                        ↓
┌─────────────────────────────────────────────────────────────┐
│                   UPDATING METADATA                          │
│  - Save new ETags, hashes, sync status                       │
│  - Save sync anchor                                          │
└───────────────────────┬─────────────────────────────────────┘
                        │
                        │ Metadata saved
                        ↓
┌─────────────────────────────────────────────────────────────┐
│                   NOTIFYING MAIN APP                         │
│  - DistributedNotificationCenter post                        │
│  - Include status, error, stats                              │
└───────────────────────┬─────────────────────────────────────┘
                        │
                        └──────────→ Back to IDLE
```

### Error Recovery States

```
EXECUTING TRANSFERS → TRANSFER ERROR
    ↓
Retry with exponential backoff (1s, 2s, 4s, 8s, max 60s)
    ↓
If retry succeeds → UPDATING METADATA
    ↓
If max retries exceeded → Mark as .error in metadata
    ↓
Return NSFileProviderError.serverUnreachable
    ↓
User can manually retry via Finder or Tray Menu
    ↓
On manual retry → signalErrorResolved() → Back to IDLE
```

## Build Order and Dependencies

### Phase 1: Foundation (No Sync Yet)

**Goal:** Shared infrastructure that both main app and extension depend on

1. **SwiftData Models**
   - Define `SyncedItem`, `SyncAnchor`, `ConflictCopy` entities
   - Add to both main app and extension targets
   - Create `ModelContainer.shared(for:)` factory

2. **Shared Metadata Layer**
   - Create `MetadataTracker` service wrapping SwiftData queries
   - Implement CRUD operations for `SyncedItem`
   - Add index queries (by status, by parent, by identifier)

3. **Enhanced SharedData**
   - Migrate existing UserDefaults persistence to use SwiftData where appropriate
   - Keep auth tokens in UserDefaults (SwiftData not suitable for credentials)
   - Store drive configs in SwiftData (more queryable)

**Validation:** Main app and extension can both read/write to shared SwiftData container

### Phase 2: S3 Sync Engine Core (Extension Only)

**Goal:** Reliable remote change detection and metadata tracking

4. **S3Client Improvements**
   - Extract from existing `S3Lib.swift`
   - Add ETag extraction and validation
   - Implement continuation token pagination correctly
   - Add retry logic with exponential backoff

5. **Remote Change Detector**
   - Implement `listObjectsV2` with full pagination
   - Compare S3 ETags with `MetadataTracker` records
   - Classify items: new, modified, deleted, unchanged
   - Save sync anchor after each cycle

6. **Enumerator Refactor**
   - Rewrite `S3Enumerator` to use `MetadataTracker` as source of truth
   - Return `NSFileProviderItem` with `versionIdentifier` = ETag
   - Implement `.workingSet` container properly

**Validation:** Extension can detect remote changes and update Finder without downloads

### Phase 3: Conflict Detection (Extension Only)

**Goal:** Prevent data loss from concurrent modifications

7. **Version Tracking**
   - Store S3 ETag as `versionIdentifier` in `NSFileProviderItemVersion`
   - Implement `baseVersion` comparison in `modifyItem()`
   - Detect conflicts before upload

8. **Conflict Resolver**
   - Create `ConflictResolver` service
   - Implement conflict copy naming: `"filename (Conflict Copy YYYY-MM-DD).ext"`
   - Upload conflict copy as separate S3 object
   - Update `ConflictCopy` table for tracking

**Validation:** Concurrent edits create conflict copies, no data loss

### Phase 4: Transfer Managers (Extension Only)

**Goal:** Reliable uploads and downloads with progress tracking

9. **Download Manager**
   - Queue-based parallel downloads (max 3 concurrent)
   - Stream to temp file, report progress
   - Calculate SHA256 hash after download
   - Update metadata with local hash

10. **Upload Manager**
    - Queue-based parallel uploads (max 2 concurrent to avoid S3 throttling)
    - Implement multipart upload state machine
    - Store `uploadId` and `uploadedParts` in metadata for resume
    - Abort incomplete uploads on failure

**Validation:** Large files (>100MB) upload/download reliably with resumption

### Phase 5: Main App Integration

**Goal:** User-facing features for managing sync

11. **Drive Manager Improvements**
    - Subscribe to DistributedNotificationCenter for extension status
    - Aggregate sync status across drives (for tray menu badge)
    - Implement `signalEnumerator()` calls when user actions require sync

12. **Tray Menu Enhancements**
    - Display sync status per drive (from DistributedNotificationCenter)
    - Show transfer progress (percentage, speed)
    - Add manual sync trigger button

13. **Error Handling UI**
    - Surface `NSFileProviderError` to user in tray menu
    - Implement retry mechanism (calls `signalErrorResolved()`)
    - Log errors to structured logging for debugging

**Validation:** Users see sync status, can retry failed operations

### Phase 6: Multitenancy Support

**Goal:** Support multiple tenants with different S3 endpoints

14. **Tenant Discovery**
    - Implement Composer Hub API call: `discoverS3Endpoint(tenantID)`
    - Store endpoint per drive in `DS3Drive` model
    - Configure S3Client with drive-specific endpoint

15. **Tenant-Aware Auth**
    - Add `tenantID` field to login flow
    - Store in `AccountSession`
    - Validate tenant exists via IAM API

**Validation:** Can create drives on different tenants simultaneously

### Dependency Graph

```
Phase 1 (Foundation)
    ↓
Phase 2 (Sync Engine) ← Must complete before Phase 3
    ↓
Phase 3 (Conflict Detection) ← Must complete before Phase 4
    ↓
Phase 4 (Transfer Managers) ← Can develop in parallel with Phase 5
    ↓
Phase 5 (Main App Integration) ← Depends on Phase 2, 3, 4
    ↓
Phase 6 (Multitenancy) ← Depends on Phase 1, 2, can be parallel to 3-5
```

**Critical path:** Phase 1 → 2 → 3 → 4 (Foundation and extension must be solid before UI)

**Parallel work opportunity:** Phase 5 (UI) and Phase 6 (Multitenancy) can overlap with Phase 4

## Anti-Patterns to Avoid

### 1. Force-Unwrapping Shared Data

**What:** Current code force-unwraps optionals when loading from `SharedData`

**Why bad:** Extension crashes if data missing, taking down all drives

**Instead:**
```swift
// Bad
let drive = SharedData.default().loadDS3Drive(domainIdentifier)!

// Good
guard let drive = SharedData.default().loadDS3Drive(domainIdentifier) else {
    logger.error("Failed to load drive config")
    return NSFileProviderError(.providerNotFound)
}
```

### 2. Stale Sync Anchors

**What:** Current code loads sync anchor once at init, never refreshes

**Why bad:** Enumerator reports stale data if anchor changes during extension lifetime

**Instead:** Reload anchor from database at start of each enumeration cycle

### 3. Ignoring S3 Response Metadata

**What:** Current code discards `DeleteObject`, `CopyObject`, `CompleteMultipartUpload` responses

**Why bad:** Server errors (quota exceeded, permission denied) go undetected

**Instead:** Validate responses, check for error metadata, surface to user

### 4. Synchronous File I/O in Extension

**What:** JSON serialization/deserialization blocks extension threads

**Why bad:** Large drive configs freeze Finder UI

**Instead:** Use async file I/O, background queues for persistence

### 5. Global State in Extension

**What:** Shared singletons across FileProvider methods

**Why bad:** Race conditions when system calls multiple methods concurrently

**Instead:** Use actors for concurrent state management, or per-request context objects

### 6. Unlimited Retry Loops

**What:** Retry failed operations indefinitely

**Why bad:** Drains battery, hammers S3 API, accrues charges

**Instead:** Exponential backoff with max retry count, surface persistent errors to user

### 7. Downloading to CloudStorage Directly

**What:** Writing downloaded data directly to final FileProvider location

**Why bad:** Incomplete downloads leave corrupt files, bypasses system management

**Instead:** Download to temp directory, let system move to final location

### 8. Single Metadata Database for All Drives

**What:** Sharing one SwiftData container across multiple FileProvider domains

**Why bad:** Concurrent extension processes conflict on writes, data corruption

**Instead:** One database file per domain (`MetadataDB-{domainIdentifier}.sqlite`)

## Scaling Considerations

### At 10 Drives

**Concerns:**
- Main app aggregates status from 10 extension processes via DistributedNotificationCenter
- Tray menu displays 10 drive status badges

**Mitigations:**
- Collapse drives into single menu with submenus
- Aggregate overall status (any errors → show error badge)

### At 1,000 Files per Drive

**Concerns:**
- S3 listObjectsV2 requires ~2 requests (500 items per page)
- MetadataTracker query performance on 1K rows

**Mitigations:**
- Index `itemIdentifier`, `parentItemIdentifier`, `syncStatus`
- Use continuation tokens correctly
- Implement working set optimization (only enumerate recently changed items)

### At 10,000 Files per Drive

**Concerns:**
- Initial enumeration takes 20+ S3 requests
- SwiftData query performance degrades

**Mitigations:**
- Implement incremental enumeration (don't re-enumerate entire tree)
- Use sync anchors to track last change timestamp
- Consider prefix-based sharding for massive directories

### At 100MB/s Upload/Download

**Concerns:**
- Progress reporting overhead
- Memory pressure from buffering

**Mitigations:**
- Report progress in 1% increments, not per chunk
- Stream data, avoid loading entire files into memory
- Increase multipart chunk size for large files

## Sources

**Apple Official Documentation:**
- [Synchronizing files using file provider extensions](https://developer.apple.com/documentation/FileProvider/synchronizing-files-using-file-provider-extensions) - Apple Developer Documentation
- [NSFileProviderReplicatedExtension](https://developer.apple.com/documentation/fileprovider/nsfileproviderreplicatedextension) - Apple Developer Documentation
- [File Provider](https://developer.apple.com/documentation/fileprovider) - Apple Developer Documentation

**Production Architecture Patterns:**
- [Build your own cloud sync on iOS and macOS using Apple FileProvider APIs](https://claudiocambra.com/posts/build-file-provider-sync/) - Claudio Cambra (HIGH confidence - comprehensive File Provider architecture guide)
- [How to Work with the File Provider API on macOS](https://www.apriorit.com/dev-blog/730-mac-how-to-work-with-the-file-provider-for-macos) - Apriorit
- [Rewriting the heart of our sync engine](https://dropbox.tech/infrastructure/rewriting-the-heart-of-our-sync-engine) - Dropbox Engineering Blog (Nucleus sync engine architecture)
- [Testing sync at Dropbox](https://dropbox.tech/infrastructure/-testing-our-new-sync-engine) - Dropbox Engineering Blog

**SwiftData Integration:**
- [iOS Share Extension with SwiftUI and SwiftData](https://www.merrell.dev/ios-share-extension-with-swiftui-and-swiftdata) - Sam Merrell
- [Core Data and App extensions: Sharing a single database](https://www.avanderlee.com/swift/core-data-app-extension-data-sharing/) - SwiftLee
- [Sharing Data Between Share Extension & App Swift iOS](https://www.fleksy.com/blog/communicating-between-an-ios-app-extensions-using-app-groups/) - Fleksy

**Conflict Resolution:**
- [Offline sync & conflict resolution patterns — Architecture & Trade-offs](https://www.sachith.co.uk/offline-sync-conflict-resolution-patterns-architecture-trade%E2%80%91offs-practical-guide-feb-19-2026/) - Sachith Dassanayake
- [ETags and Optimistic Concurrency Control](https://fideloper.com/etags-and-optimistic-concurrency-control) - Fideloper
- [ETag header - HTTP](https://developer.mozilla.org/en-US/docs/Web/HTTP/Headers/ETag) - MDN Web Docs

**Metadata Database Design:**
- [Best practices for building a pain-free metadata store](https://www.cockroachlabs.com/blog/metadata-best-practices/) - CockroachDB

---

*Architecture research: 2026-03-11*
