# Phase 2: Sync Engine - Research

**Researched:** 2026-03-12
**Domain:** macOS File Provider change enumeration, SwiftData background persistence, S3 reconciliation
**Confidence:** HIGH

## Summary

Phase 2 transforms the current "list-only" File Provider extension into a metadata-driven sync engine that detects remote changes (new, modified, deleted) by reconciling S3 `listObjectsV2` results against a SwiftData MetadataStore. The core gap is the `// TODO: process remotely deleted files` in `S3Enumerator.enumerateChanges()` -- currently no deletions are ever reported, and the sync anchor is a Date stored in UserDefaults without per-drive scoping.

The implementation requires: (1) migrating MetadataStore from `@MainActor` to a `@ModelActor` for background execution in the File Provider extension, (2) adding a `SyncAnchorRecord` SwiftData entity alongside a schema v2 migration that also adds `isMaterialized` to `SyncedItem`, (3) building a `SyncEngine` class that orchestrates full reconciliation (S3 listing vs MetadataStore diff), and (4) integrating cloud placeholder behavior with on-demand download and basic pinning support.

The existing codebase provides solid foundations: `S3Lib.listS3Items()` already handles pagination with continuation tokens, `SyncedItem` has versioned schema with migration plan, and `S3Item` already returns `.downloadLazily` as content policy. The main work is connecting these pieces through a reconciliation engine.

**Primary recommendation:** Build a `SyncEngine` actor in `DS3Lib/Sources/DS3Lib/Sync/` that encapsulates all reconciliation logic (S3 listing, MetadataStore diffing, deletion detection, sync anchor advancement) and have `S3Enumerator` delegate to it for both `enumerateItems()` and `enumerateChanges()`.

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
- Immediate disappearance from Finder at next sync cycle when files are deleted on S3
- Full reconciliation on every `enumerateChanges()` call: S3 `listObjectsV2` compared against MetadataStore to detect deletions
- Individual S3 `DeleteObject` calls per `deleteItem()` invocation (no batching) -- File Provider framework requires per-item completion handlers
- Hard delete of SyncedItem records from MetadataStore when remote deletion detected
- Threshold warning: if >50% of items in a drive are detected as deleted in one cycle, log a warning but still proceed with deletion
- Empty folder auto-cleanup: folders disappear when all contents are deleted (follows S3 semantics)
- In-use files: delegate to File Provider framework (it will not remove open files; deletion applied when file is closed)
- System-managed sync frequency: let File Provider framework control when `enumerateChanges()` is called -- no custom polling timer
- Signal after local changes: call `NSFileProviderManager.signalEnumerator()` after local upload/delete/rename completes to trigger eager re-enumeration
- Full reconciliation on every `enumerateChanges()` call (not periodic -- every call does complete S3 listing vs MetadataStore diff)
- Paginate through all objects using S3 `listObjectsV2` continuation tokens -- no cap on item count
- Exponential backoff on S3 errors with NWPathMonitor integration
- Cloud placeholders via `.downloadLazily` content policy
- Basic pinning support: allow "Keep Downloaded" on files/folders using `.downloadLazilyAndKeepDownloaded` policy
- Auto-retry with exponential backoff on download failure; after all retries fail, show error state on file
- Track materialization in MetadataStore: add `isMaterialized` field to SyncedItem
- Partial downloads for large files: use S3 range GET requests + File Provider `fetchPartialContents`
- Per-drive error status: drive shows "error" in menu bar tray after failures
- 3 consecutive sync cycle failures = drive marked as error state
- Auto-recover when NWPathMonitor detects connectivity restored
- Track per-item errors in MetadataStore: set `syncStatus` to `error` on failed file operations
- 3 retries per file operation with exponential backoff, then mark as error and skip
- API key expiry handling deferred to Phase 4
- Extract new `SyncEngine` class in `DS3Lib/Sources/DS3Lib/Sync/`
- Migrate `MetadataStore` from `@MainActor` to `ModelActor` for background thread execution
- New `SyncAnchorRecord` SwiftData entity: separate from SyncedItem, contains `driveId`, `lastSyncDate`, and additional tracking fields
- `SyncEngine` uses async/await with `SyncEngineDelegate` protocol or `AsyncStream` for status updates
- `S3Enumerator` delegates to `SyncEngine` for reconciliation; `S3Item` stays as pure File Provider item representation
- `SyncEngine` owns all MetadataStore writes
- Basic unit test coverage for SyncEngine

### Claude's Discretion
- Partial download threshold (recommend somewhere between 5MB and 100MB based on performance testing)
- Exact exponential backoff parameters (max delay, jitter)
- ModelActor implementation details (custom actor vs. SwiftData's @ModelActor macro)
- SyncEngine internal state machine design
- S3Enumerator refactoring approach (how much logic to move vs. keep)
- Test framework choice (XCTest vs. Swift Testing)

### Deferred Ideas (OUT OF SCOPE)
None -- discussion stayed within phase scope
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|-----------------|
| SYNC-01 | SwiftData schema tracks per-item: S3 key, ETag, LastModified, local file hash, sync status, parent key, content type, size | SyncedItem already has all fields in SchemaV1. SchemaV2 adds `isMaterialized`. MetadataStore migrated to ModelActor for background access. |
| SYNC-04 | Remote deletion tracking by comparing S3 listObjectsV2 results against local metadata DB | SyncEngine performs full reconciliation: fetches all S3 keys, diffs against MetadataStore, reports missing items via `observer.didDeleteItems(withIdentifiers:)` |
| SYNC-05 | Sync anchor persisted to SwiftData and advanced after each successful enumeration batch | New `SyncAnchorRecord` entity replaces UserDefaults-based anchor. Advanced after each successful reconciliation cycle. |
| SYNC-06 | On-demand sync -- files visible as cloud placeholders, downloaded only when opened by user | S3Item already returns `.downloadLazily`. Add pinning support with `.downloadLazilyAndKeepDownloaded`. Implement `fetchPartialContents` for large files. |
</phase_requirements>

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| SwiftData | macOS 15+ | Metadata persistence (SyncedItem, SyncAnchorRecord) | Apple-native, already adopted in Phase 1, supports ModelActor for background ops |
| FileProvider | macOS 15+ | NSFileProviderReplicatedExtension, change enumeration, content policies | Framework requirement -- the entire sync engine integrates through it |
| SotoS3 | 6.8+ | S3 listObjectsV2, GetObject (range), HeadObject | Already in use, declared in DS3Lib/Package.swift |
| Network | macOS 15+ | NWPathMonitor for connectivity detection | Apple framework, no dependency needed |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| swift-atomics | 1.2+ | Thread-safe flags (e.g., isShutdown in S3Lib) | Already in use for atomic state in extension |
| os.log | macOS 15+ | Structured logging (subsystem/category pattern from Phase 1) | All sync operations logged with sync/metadata/transfer categories |
| XCTest | Xcode 16+ | Unit tests for SyncEngine | Test target already exists (DS3LibTests) |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| @ModelActor macro | Custom actor with ModelContext | Macro is simpler but has thread-behavior quirks; custom actor gives more control. Recommend @ModelActor for simplicity with documented workaround for background execution. |
| XCTest | Swift Testing | Swift Testing is newer but XCTest already in use. Recommend XCTest for consistency with existing DS3LibTests. |
| Full reconciliation every cycle | Incremental (timestamp-based) | Current code uses timestamp filtering but misses deletions entirely. Full reconciliation is the locked decision. |

**Installation:** No new dependencies needed. All required frameworks are already available.

## Architecture Patterns

### Recommended Project Structure
```
DS3Lib/Sources/DS3Lib/
  Sync/
    SyncEngine.swift           # Main reconciliation orchestrator (@ModelActor)
    SyncEngineDelegate.swift   # Protocol for status callbacks
    NetworkMonitor.swift       # NWPathMonitor wrapper (async/await)
  Metadata/
    MetadataStore.swift        # Migrated to ModelActor (from @MainActor)
    SyncedItem.swift           # SchemaV2 with isMaterialized field
    SyncAnchorRecord.swift     # New SwiftData entity

DS3DriveProvider/
    S3Enumerator.swift         # Delegates reconciliation to SyncEngine
    FileProviderExtension.swift # Initializes SyncEngine, calls signalEnumerator
    S3Item.swift               # Adds pinning content policy logic
```

### Pattern 1: Full Reconciliation via Set Diff
**What:** On every `enumerateChanges()` call, fetch all S3 keys for the drive, compare against MetadataStore, and compute three sets: new items, modified items (ETag changed), deleted items (in DB but not in S3).
**When to use:** Every `enumerateChanges()` invocation.
**Example:**
```swift
// SyncEngine reconciliation pseudocode
func reconcile(drive: DS3Drive) async throws -> ReconciliationResult {
    // 1. Fetch all remote keys with pagination
    var remoteItems: [String: S3ObjectInfo] = [:]
    var continuationToken: String? = nil
    repeat {
        let (items, nextToken) = try await s3Lib.listS3Items(
            forDrive: drive,
            withPrefix: drive.syncAnchor.prefix,
            recursively: true,
            withContinuationToken: continuationToken
        )
        for item in items {
            remoteItems[item.itemIdentifier.rawValue] = S3ObjectInfo(
                etag: item.metadata.etag,
                lastModified: item.metadata.lastModified,
                size: item.metadata.size
            )
        }
        continuationToken = nextToken
    } while continuationToken != nil

    // 2. Fetch all local items for this drive from MetadataStore
    let localItems = try fetchItemsByDrive(driveId: drive.id)
    let localKeySet = Set(localItems.map(\.s3Key))
    let remoteKeySet = Set(remoteItems.keys)

    // 3. Compute diffs
    let newKeys = remoteKeySet.subtracting(localKeySet)
    let deletedKeys = localKeySet.subtracting(remoteKeySet)
    let commonKeys = localKeySet.intersection(remoteKeySet)

    // 4. Check for modifications (ETag changed)
    var modifiedKeys: Set<String> = []
    for key in commonKeys {
        if let local = localItems.first(where: { $0.s3Key == key }),
           let remote = remoteItems[key],
           local.etag != remote.etag {
            modifiedKeys.insert(key)
        }
    }

    // 5. Threshold warning
    if deletedKeys.count > localItems.count / 2 {
        logger.warning("Mass deletion detected: \(deletedKeys.count) of \(localItems.count) items")
    }

    return ReconciliationResult(
        newKeys: newKeys,
        modifiedKeys: modifiedKeys,
        deletedKeys: deletedKeys,
        remoteItems: remoteItems
    )
}
```

### Pattern 2: ModelActor for Background SwiftData Access
**What:** Migrate MetadataStore from `@MainActor` to `@ModelActor` so the File Provider extension (which runs off the main thread) can safely access SwiftData.
**When to use:** All MetadataStore operations in the File Provider extension.
**Example:**
```swift
// Source: SwiftData @ModelActor documentation + community patterns
@ModelActor
actor MetadataStoreActor {
    // @ModelActor macro generates:
    // - modelContainer: ModelContainer
    // - modelExecutor: any ModelExecutor
    // - init(modelContainer: ModelContainer)

    func upsertItem(
        s3Key: String,
        driveId: UUID,
        etag: String? = nil,
        lastModified: Date? = nil,
        syncStatus: SyncStatus = .pending,
        parentKey: String? = nil,
        contentType: String? = nil,
        size: Int64 = 0
    ) throws {
        let context = modelExecutor.modelContext
        let predicate = #Predicate<SyncedItem> { $0.s3Key == s3Key }
        let descriptor = FetchDescriptor<SyncedItem>(predicate: predicate)

        if let existing = try context.fetch(descriptor).first {
            existing.etag = etag
            existing.lastModified = lastModified
            existing.syncStatus = syncStatus.rawValue
            // ... update other fields
        } else {
            let item = SyncedItem(s3Key: s3Key, driveId: driveId, size: size)
            item.etag = etag
            // ... set other fields
            context.insert(item)
        }
        try context.save()
    }

    func fetchItemsByDrive(driveId: UUID) throws -> [SyncedItem] {
        let context = modelExecutor.modelContext
        let predicate = #Predicate<SyncedItem> { $0.driveId == driveId }
        return try context.fetch(FetchDescriptor<SyncedItem>(predicate: predicate))
    }
}
```

**Critical note on @ModelActor thread behavior:** When created on the main thread, `@ModelActor` types execute there. To ensure background execution, create the actor from a non-isolated async context:
```swift
// Ensure background execution
func makeMetadataStore(container: ModelContainer) async -> MetadataStoreActor {
    MetadataStoreActor(modelContainer: container)
}
```

### Pattern 3: SyncEngine as Orchestrator Actor
**What:** A dedicated actor that owns all MetadataStore writes and orchestrates the reconciliation flow. S3Enumerator delegates to it.
**When to use:** All sync operations flow through SyncEngine.
**Example:**
```swift
actor SyncEngine {
    private let metadataStore: MetadataStoreActor
    private let networkMonitor: NetworkMonitor
    private let logger = Logger(subsystem: LogSubsystem.provider, category: LogCategory.sync.rawValue)

    private var consecutiveFailures: Int = 0
    private let maxConsecutiveFailures = 3

    weak var delegate: SyncEngineDelegate?

    init(metadataStore: MetadataStoreActor, networkMonitor: NetworkMonitor) {
        self.metadataStore = metadataStore
        self.networkMonitor = networkMonitor
    }

    func enumerateChanges(
        for drive: DS3Drive,
        s3Lib: S3Lib
    ) async throws -> (updated: [S3Item], deleted: [NSFileProviderItemIdentifier], newAnchor: NSFileProviderSyncAnchor) {
        guard networkMonitor.isConnected else {
            throw NSFileProviderError(.serverUnreachable)
        }

        do {
            let result = try await reconcile(drive: drive, s3Lib: s3Lib)

            // Update MetadataStore with new/modified items
            for key in result.newKeys.union(result.modifiedKeys) {
                guard let remote = result.remoteItems[key] else { continue }
                try await metadataStore.upsertItem(
                    s3Key: key,
                    driveId: drive.id,
                    etag: remote.etag,
                    lastModified: remote.lastModified,
                    syncStatus: .synced,
                    size: remote.size
                )
            }

            // Delete removed items from MetadataStore
            for key in result.deletedKeys {
                try await metadataStore.deleteItem(byKey: key)
            }

            // Advance sync anchor
            let anchor = try await metadataStore.advanceSyncAnchor(driveId: drive.id)

            consecutiveFailures = 0
            delegate?.syncEngineDidComplete(drive: drive)

            return (
                updated: result.updatedS3Items,
                deleted: result.deletedIdentifiers,
                newAnchor: anchor
            )
        } catch {
            consecutiveFailures += 1
            if consecutiveFailures >= maxConsecutiveFailures {
                delegate?.syncEngineDidEnterErrorState(drive: drive, error: error)
            }
            throw error
        }
    }
}
```

### Pattern 4: Exponential Backoff with Jitter
**What:** Extend the existing `withRetries()` utility with configurable exponential backoff and jitter.
**When to use:** S3 operation retries, download failures.
**Recommended parameters:**
- Base delay: 1.0 seconds
- Max delay: 60.0 seconds
- Multiplier: 2.0
- Jitter: +/- 25% randomization
- Max retries: 3 (per file operation, per decision)
```swift
public func withExponentialBackoff<T>(
    maxRetries: Int = 3,
    baseDelay: TimeInterval = 1.0,
    maxDelay: TimeInterval = 60.0,
    multiplier: Double = 2.0,
    logger: Logger? = nil,
    block: @escaping @Sendable () async throws -> T
) async throws -> T {
    var attempt = 0
    while true {
        do {
            return try await block()
        } catch {
            attempt += 1
            if attempt >= maxRetries { throw error }
            let delay = min(baseDelay * pow(multiplier, Double(attempt - 1)), maxDelay)
            let jitter = delay * Double.random(in: 0.75...1.25)
            logger?.debug("Retry \(attempt)/\(maxRetries) after \(jitter, format: .fixed(precision: 1))s")
            try await Task.sleep(for: .seconds(jitter))
        }
    }
}
```

### Pattern 5: NetworkMonitor Wrapper
**What:** Async-friendly NWPathMonitor wrapper that SyncEngine checks before operations.
**When to use:** Before any S3 operation, and for auto-recovery detection.
```swift
import Network

actor NetworkMonitor {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "io.cubbit.DS3Drive.NetworkMonitor")
    private(set) var isConnected: Bool = true
    private var continuation: AsyncStream<Bool>.Continuation?

    var connectivityStream: AsyncStream<Bool> {
        AsyncStream { continuation in
            self.continuation = continuation
            monitor.pathUpdateHandler = { path in
                let connected = path.status == .satisfied
                continuation.yield(connected)
            }
            monitor.start(queue: queue)
        }
    }

    func startMonitoring() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { await self?.updateStatus(path.status == .satisfied) }
        }
        monitor.start(queue: queue)
    }

    private func updateStatus(_ connected: Bool) {
        isConnected = connected
        continuation?.yield(connected)
    }

    func stopMonitoring() {
        monitor.cancel()
        continuation?.finish()
    }
}
```

### Anti-Patterns to Avoid
- **Passing SwiftData models across actor boundaries:** `SyncedItem` is not `Sendable`. Pass DTOs (structs with the raw values) or `PersistentIdentifier` instead. Never pass `SyncedItem` out of the `@ModelActor`.
- **Creating multiple ModelContexts for the same store:** This causes Core Data crashes ("An NSManagedObjectContext cannot delete objects in other contexts"). The SyncEngine should use a single `MetadataStoreActor` instance.
- **Using `anchor.toDate()` for deletion detection:** The current code only finds items modified *after* the anchor timestamp, which by definition cannot detect deletions. Full S3 listing + set diff is required.
- **Reporting changes without updating MetadataStore first:** Always persist the new state before calling `observer.didUpdate()` or `observer.didDeleteItems()`, so that if the extension crashes, the MetadataStore is consistent.
- **Blocking the main actor from File Provider extension:** The extension runs in a separate process and should never assume main-actor availability. All SwiftData access must go through the `@ModelActor`.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Network reachability | Custom reachability checker | `NWPathMonitor` from `Network` framework | Handles WiFi, cellular, wired; async-friendly; Apple-maintained |
| Retry with backoff | Simple loop with fixed delay | Extended `withRetries()` utility with exponential backoff + jitter | Jitter prevents thundering herd; capped delay prevents infinite waits |
| Sync anchor persistence | UserDefaults (current approach) | SwiftData `SyncAnchorRecord` entity | Per-drive scoping, survives extension restarts, co-located with metadata |
| Background SwiftData access | Manual ModelContext + DispatchQueue | `@ModelActor` macro | Handles serial execution, actor isolation, context lifecycle |
| S3 pagination | Manual pagination loop | Existing `S3Lib.listS3Items()` with continuation tokens | Already handles pagination, URL decoding, prefix filtering |
| File Provider error mapping | Custom error types | Existing `S3ErrorType.toFileProviderError()` and `FileProviderExtensionError.toPresentableError()` | Phase 1 established correct NSFileProviderError/NSCocoaError mappings |
| Content policy for cloud placeholders | Custom download state tracking | `NSFileProviderContentPolicy.downloadLazily` / `.downloadLazilyAndKeepDownloaded` | System handles cloud badge display, eviction, Finder integration |

**Key insight:** The File Provider framework does most of the heavy lifting for cloud placeholder UI, eviction, and download triggering. The extension only needs to correctly report item state and implement `fetchContents`/`fetchPartialContents`. Do not try to manage materialization state beyond what the framework provides -- the `isMaterialized` field is for app-side display only.

## Common Pitfalls

### Pitfall 1: SwiftData Model Crossing Actor Boundaries
**What goes wrong:** Passing a `SyncedItem` (SwiftData `@Model`) out of the `@ModelActor` causes crashes or undefined behavior because `@Model` classes are not `Sendable`.
**Why it happens:** SwiftData models are tied to their `ModelContext` and cannot be safely accessed from another context or thread.
**How to avoid:** Create `Sendable` DTOs (plain structs) inside the actor and return those. Use `PersistentIdentifier` for lookups.
**Warning signs:** Runtime crashes mentioning "NSManagedObject accessed from wrong thread" or Swift concurrency isolation errors.

### Pitfall 2: @ModelActor Running on Main Thread
**What goes wrong:** If `MetadataStoreActor` is initialized on the main thread (e.g., during `FileProviderExtension.init()`), all its operations run on the main thread, blocking UI.
**Why it happens:** `@ModelActor` uses `DefaultSerialModelExecutor` which inherits the creating thread's execution context.
**How to avoid:** Initialize the `MetadataStoreActor` from a `nonisolated` async function or `Task.detached` to ensure background execution:
```swift
// In FileProviderExtension.init(domain:)
// Don't: let store = MetadataStoreActor(modelContainer: container) // runs on main
// Do: create lazily from async context
```
**Warning signs:** Main thread hangs during sync operations; laggy Finder.

### Pitfall 3: Sync Anchor Size Limit
**What goes wrong:** `NSFileProviderSyncAnchor` raw data exceeds 500 bytes, causing enumeration failures.
**Why it happens:** Storing too much data in the sync anchor itself (e.g., serializing entire state).
**How to avoid:** Store only a minimal identifier in the anchor (e.g., a `UUID` referencing a `SyncAnchorRecord` in SwiftData, or just the last sync date). Keep the heavy state in SwiftData.
**Warning signs:** `enumerateChanges` fails with opaque File Provider errors.

### Pitfall 4: Reporting Deletions for Items File Provider Doesn't Know About
**What goes wrong:** Calling `observer.didDeleteItems(withIdentifiers:)` with identifiers the system never received via `didUpdate()` causes undefined behavior.
**Why it happens:** The MetadataStore has items that were never successfully reported to the File Provider system (e.g., from a failed initial enumeration).
**How to avoid:** Only report deletion for items that have been previously reported as existing. Use the MetadataStore's `syncStatus == .synced` to track which items the system knows about.
**Warning signs:** Ghost items that reappear, or system errors during change enumeration.

### Pitfall 5: Race Between enumerateItems and enumerateChanges
**What goes wrong:** Initial enumeration (`enumerateItems`) and change enumeration (`enumerateChanges`) run concurrently, causing duplicate inserts or missed deletions.
**Why it happens:** The File Provider system can call both methods concurrently for the same or different containers.
**How to avoid:** The `@ModelActor` provides serialization. Additionally, `SyncEngine` should use an internal lock or actor serialization to prevent concurrent reconciliation for the same drive.
**Warning signs:** Duplicate items in Finder, database constraint violations on `s3Key` unique index.

### Pitfall 6: Not Handling the .workingSet Enumerator Correctly
**What goes wrong:** The working set enumerator must also support `enumerateChanges()`. If it doesn't report deletions, items linger in Spotlight and system caches.
**Why it happens:** `WorkingSetS3Enumerator` inherits from `S3Enumerator` but the working set has different semantics (flat, recursive view of all items).
**How to avoid:** Ensure `WorkingSetS3Enumerator` delegates to `SyncEngine` for changes just like the regular enumerator. Working set deletions are especially important for system cache consistency.
**Warning signs:** Deleted files still appear in Spotlight search results.

### Pitfall 7: SchemaV2 Migration Breaking Existing Data
**What goes wrong:** Adding `isMaterialized` as a non-optional field without a default value causes SwiftData lightweight migration to fail.
**Why it happens:** Lightweight migrations can only add optional fields or fields with default values.
**How to avoid:** Add `isMaterialized` as `Bool` with default value `false`, and `SyncAnchorRecord` as a new entity (additive). Test migration with an existing v1 database before shipping.
**Warning signs:** App crashes on launch with "migration failed" errors.

## Code Examples

### Schema V2 Migration (Adding isMaterialized + SyncAnchorRecord)
```swift
// Source: SwiftData VersionedSchema documentation
public enum SyncedItemSchemaV2: VersionedSchema {
    nonisolated(unsafe) public static let versionIdentifier = Schema.Version(2, 0, 0)
    public static var models: [any PersistentModel.Type] {
        [SyncedItem.self, SyncAnchorRecord.self]
    }

    @Model
    public final class SyncedItem {
        @Attribute(.unique) public var s3Key: String
        public var driveId: UUID
        public var etag: String?
        public var lastModified: Date?
        public var localFileHash: String?
        public var syncStatus: String
        @Transient
        public var status: SyncStatus {
            get { SyncStatus(rawValue: syncStatus) ?? .pending }
            set { syncStatus = newValue.rawValue }
        }
        public var parentKey: String?
        public var contentType: String?
        public var size: Int64
        // NEW in V2
        public var isMaterialized: Bool = false

        public init(s3Key: String, driveId: UUID, size: Int64 = 0,
                     syncStatus: String = SyncStatus.pending.rawValue) {
            self.s3Key = s3Key
            self.driveId = driveId
            self.size = size
            self.syncStatus = syncStatus
            self.isMaterialized = false
        }
    }

    @Model
    public final class SyncAnchorRecord {
        @Attribute(.unique) public var driveId: UUID
        public var lastSyncDate: Date
        public var lastSuccessfulSync: Date?
        public var consecutiveFailures: Int = 0
        public var itemCount: Int = 0

        public init(driveId: UUID, lastSyncDate: Date = Date()) {
            self.driveId = driveId
            self.lastSyncDate = lastSyncDate
        }
    }
}

// Migration plan
public enum SyncedItemMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] {
        [SyncedItemSchemaV1.self, SyncedItemSchemaV2.self]
    }
    public static var stages: [MigrationStage] {
        [migrateV1toV2]
    }

    static let migrateV1toV2 = MigrationStage.lightweight(
        fromVersion: SyncedItemSchemaV1.self,
        toVersion: SyncedItemSchemaV2.self
    )
}
```

### Reporting Deletions in enumerateChanges
```swift
// Source: Apple File Provider documentation (WWDC21-10182)
// In S3Enumerator.enumerateChanges(for:from:)
func enumerateChanges(
    for observer: NSFileProviderChangeObserver,
    from anchor: NSFileProviderSyncAnchor
) {
    Task {
        do {
            guard let drive = self.drive else {
                observer.finishEnumeratingWithError(NSFileProviderError(.cannotSynchronize))
                return
            }

            let result = try await syncEngine.enumerateChanges(
                for: drive,
                s3Lib: s3Lib
            )

            // Report updated/new items
            if !result.updated.isEmpty {
                observer.didUpdate(result.updated)
            }

            // Report deleted items -- CRITICAL: this was the missing piece
            if !result.deleted.isEmpty {
                observer.didDeleteItems(withIdentifiers: result.deleted)
            }

            observer.finishEnumeratingChanges(
                upTo: result.newAnchor,
                moreComing: false
            )
        } catch {
            observer.finishEnumeratingWithError(error)
        }
    }
}
```

### S3Item Content Policy with Pinning Support
```swift
// Source: NSFileProviderContentPolicy documentation
var contentPolicy: NSFileProviderContentPolicy {
    // Check if item is pinned (user selected "Keep Downloaded")
    // The system tracks pinning state and communicates it via modifyItem
    // We just need to return the appropriate policy based on the item's state
    if isPinned {
        return .downloadLazilyAndKeepDownloaded
    }
    return .downloadLazily
}
```

### fetchPartialContents Implementation
```swift
// Source: NSFileProviderPartialContentFetching documentation
// Conform FileProviderExtension to NSFileProviderPartialContentFetching
extension FileProviderExtension: NSFileProviderPartialContentFetching {
    func fetchPartialContents(
        for itemIdentifier: NSFileProviderItemIdentifier,
        version requestedVersion: NSFileProviderItemVersion,
        request: NSFileProviderRequest,
        minimalRange requestedRange: NSRange,
        aligningTo alignment: Int,
        options: NSFileProviderFetchContentsOptions,
        completionHandler: @escaping (URL?, NSFileProviderItem?, NSRange, NSFileProviderFetchContentsOptions, Error?) -> Void
    ) -> Progress {
        let cb = UnsafeCallback(completionHandler)

        guard self.enabled,
              let drive = self.drive,
              let s3Lib = self.s3Lib,
              let temporaryDirectory = self.temporaryDirectory else {
            cb.handler(nil, nil, NSRange(), [], NSFileProviderError(.cannotSynchronize))
            return Progress()
        }

        let progress = Progress(totalUnitCount: 100)

        Task {
            do {
                // Align range to the requested alignment boundary
                let alignedStart = (requestedRange.location / alignment) * alignment
                let alignedEnd = ((requestedRange.location + requestedRange.length + alignment - 1) / alignment) * alignment
                let alignedRange = NSRange(location: alignedStart, length: alignedEnd - alignedStart)

                // Use S3 range GET
                let rangeHeader = "bytes=\(alignedRange.location)-\(alignedRange.location + alignedRange.length - 1)"

                let fileURL = try await s3Lib.getS3ItemRange(
                    identifier: itemIdentifier,
                    drive: drive,
                    range: rangeHeader,
                    temporaryFolder: temporaryDirectory,
                    progress: progress
                )

                let s3Item = try await s3Lib.remoteS3Item(for: itemIdentifier, drive: drive)

                cb.handler(fileURL, s3Item, alignedRange, [], nil)
            } catch {
                cb.handler(nil, nil, NSRange(), [], error)
            }
        }

        return progress
    }
}
```

### signalEnumerator After Local Changes
```swift
// Source: Apple WWDC21-10182, NSFileProviderManager documentation
// Call after createItem/modifyItem/deleteItem completes successfully
private func signalChanges(for drive: DS3Drive) {
    guard let manager = NSFileProviderManager(for: NSFileProviderDomain(
        identifier: NSFileProviderDomainIdentifier(rawValue: drive.id.uuidString),
        displayName: drive.name
    )) else { return }

    manager.signalEnumerator(for: .workingSet) { error in
        if let error {
            self.logger.error("Failed to signal working set: \(error)")
        }
    }
}
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| `@MainActor` MetadataStore | `@ModelActor` for background access | SwiftData 2023+ | Required for File Provider extension (runs off main thread) |
| UserDefaults sync anchor | SwiftData `SyncAnchorRecord` entity | Phase 2 | Per-drive scoping, survives extension restarts, richer tracking |
| Date-based change detection | Full S3 reconciliation (set diff) | Phase 2 | Actually detects deletions (the core gap this phase fills) |
| `contentPolicy = .downloadLazily` only | `.downloadLazilyAndKeepDownloaded` for pinned items | macOS 12+ | Enables "Keep Downloaded" user action |
| `fetchContents` only | `fetchPartialContents` for large files | macOS 12.3+ | Enables range-based downloads for large files |
| No network awareness | NWPathMonitor integration | Phase 2 | Pause sync when offline, auto-recover when back online |

**Deprecated/outdated:**
- `NSFileProviderExtension` (non-replicated): Superseded by `NSFileProviderReplicatedExtension`. This project already uses the replicated variant.
- `Reachability` (third-party): Replaced by `NWPathMonitor` from Apple's `Network` framework.
- Callback-based `NWPathMonitor`: Now supports `AsyncSequence` for `for await` loops (macOS 15+).

## Open Questions

1. **Partial download threshold value**
   - What we know: The decision says "between 5MB and 100MB." S3 multipart threshold is already 5MB in `DefaultSettings.S3.multipartThreshold`.
   - What's unclear: The optimal threshold depends on user network conditions and typical file sizes.
   - Recommendation: Use 10MB as the threshold (2x the multipart boundary). This is a good balance -- small enough to benefit from range requests, large enough to avoid excessive overhead for medium files. Can be made configurable later.

2. **S3Lib.getS3ItemRange implementation**
   - What we know: Soto S3 supports `GetObjectRequest` with a `range` parameter (standard HTTP range header format).
   - What's unclear: Exact Soto API for range parameter name and response handling.
   - Recommendation: Verify Soto's `S3.GetObjectRequest` has a `range` property during implementation. If not, use the `customHeaders` approach. HIGH confidence this will work -- S3 range GET is a standard feature.

3. **MetadataStore dual-access pattern**
   - What we know: Both the main app and extension access the same SwiftData store via App Group container.
   - What's unclear: Whether two `@ModelActor` instances (one in app, one in extension) accessing the same SQLite file can cause WAL conflicts.
   - Recommendation: SwiftData/Core Data handles multi-process access via SQLite WAL mode. This should work, but test thoroughly with concurrent app + extension access. If issues arise, the main app could use a read-only context.

4. **isPinned state tracking for content policy**
   - What we know: The system communicates pinning via `modifyItem` with `.contentPolicy` in changed fields.
   - What's unclear: Exact mechanism for persisting pin state and reflecting it in the `S3Item.contentPolicy` getter.
   - Recommendation: Add an `isPinned` field to `SyncedItem` (or track separately). When `modifyItem` receives a `.contentPolicy` change, update the metadata. S3Item can then query the MetadataStore to determine its content policy.

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | XCTest (Xcode 16+) |
| Config file | DS3Lib/Package.swift (testTarget already declared) |
| Quick run command | `swift test --package-path DS3Lib` |
| Full suite command | `swift test --package-path DS3Lib` |

### Phase Requirements to Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| SYNC-01 | SyncedItem schema tracks all required fields + isMaterialized | unit | `swift test --package-path DS3Lib --filter SyncEngineTests/testSyncedItemSchemaV2Fields` | Wave 0 |
| SYNC-04 | New items detected via reconciliation (in S3, not in DB) | unit | `swift test --package-path DS3Lib --filter SyncEngineTests/testDetectsNewItems` | Wave 0 |
| SYNC-04 | Modified items detected (ETag changed) | unit | `swift test --package-path DS3Lib --filter SyncEngineTests/testDetectsModifiedItems` | Wave 0 |
| SYNC-04 | Deleted items detected (in DB, not in S3) | unit | `swift test --package-path DS3Lib --filter SyncEngineTests/testDetectsDeletedItems` | Wave 0 |
| SYNC-04 | Mass deletion threshold warning logged | unit | `swift test --package-path DS3Lib --filter SyncEngineTests/testMassDeletionWarning` | Wave 0 |
| SYNC-05 | Sync anchor advances after successful enumeration | unit | `swift test --package-path DS3Lib --filter SyncEngineTests/testSyncAnchorAdvances` | Wave 0 |
| SYNC-05 | Sync anchor survives re-initialization | unit | `swift test --package-path DS3Lib --filter SyncEngineTests/testSyncAnchorPersistence` | Wave 0 |
| SYNC-06 | Content policy returns downloadLazily by default | unit | `swift test --package-path DS3Lib --filter SyncEngineTests/testDefaultContentPolicy` | Wave 0 |
| ERR | Consecutive failure count triggers error state | unit | `swift test --package-path DS3Lib --filter SyncEngineTests/testConsecutiveFailureErrorState` | Wave 0 |
| ERR | Error count resets on success | unit | `swift test --package-path DS3Lib --filter SyncEngineTests/testErrorCountResetOnSuccess` | Wave 0 |

### Sampling Rate
- **Per task commit:** `swift test --package-path DS3Lib`
- **Per wave merge:** `swift test --package-path DS3Lib` + `xcodebuild build -project DS3Drive.xcodeproj -scheme DS3Drive -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`
- **Phase gate:** Full suite green before `/gsd:verify-work`

### Wave 0 Gaps
- [ ] `DS3Lib/Tests/DS3LibTests/SyncEngineTests.swift` -- covers SYNC-01, SYNC-04, SYNC-05, SYNC-06, error state
- [ ] `DS3Lib/Tests/DS3LibTests/MetadataStoreMigrationTests.swift` -- covers SchemaV1 to SchemaV2 migration
- [ ] `DS3Lib/Tests/DS3LibTests/ExponentialBackoffTests.swift` -- covers retry utility
- [ ] In-memory SwiftData container helper in test fixtures (already available via `MetadataStore.init(container:)` pattern -- extend for ModelActor)

## Sources

### Primary (HIGH confidence)
- Apple FileProvider framework documentation - `NSFileProviderReplicatedExtension`, `NSFileProviderEnumerator`, `NSFileProviderChangeObserver`, `NSFileProviderContentPolicy`
- [WWDC21-10182 "Sync files to the cloud with FileProvider on macOS"](https://developer.apple.com/videos/play/wwdc2021/10182/) -- canonical reference for File Provider architecture
- [Claudio Cambra: Build your own cloud sync](https://claudiocambra.com/posts/build-file-provider-sync/) -- practical File Provider implementation guide
- SwiftData `@ModelActor` documentation -- background context management
- Existing codebase: MetadataStore.swift, SyncedItem.swift, S3Enumerator.swift, S3Lib.swift, ControlFlow.swift

### Secondary (MEDIUM confidence)
- [BrightDigit: Using ModelActor in SwiftData](https://brightdigit.com/tutorials/swiftdata-modelactor/) -- ModelActor initialization patterns
- [Matt Massicotte: ModelActor is Just Weird](https://www.massicotte.org/model-actor/) -- Thread behavior quirks of @ModelActor
- [Hacking with Swift: SwiftData background context](https://www.hackingwithswift.com/quick-start/swiftdata/how-to-create-a-background-context) -- Background SwiftData patterns
- [Hacking with Swift: SwiftData migrations](https://www.hackingwithswift.com/quick-start/swiftdata/how-to-create-a-complex-migration-using-versionedschema) -- VersionedSchema migration patterns
- [FileProviderTrial (seanses/FileProviderTrial)](https://github.com/seanses/FileProviderTrial) -- Reference File Provider implementation
- [Apple Developer Forums: File Provider discussions](https://developer.apple.com/forums/tags/fileprovider) -- Community patterns and gotchas

### Tertiary (LOW confidence)
- fetchPartialContents implementation details -- Apple docs confirmed the API exists but JavaScript-rendered docs could not be fetched. Implementation approach based on API signature and S3 range GET standard behavior. Verify exact parameter types during implementation.
- `NSFileProviderContentPolicy.downloadLazilyAndKeepDownloaded` -- confirmed to exist in API but detailed behavior documentation could not be fetched. Based on enum naming convention and community usage.

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH - all libraries already in use or are Apple frameworks
- Architecture: HIGH - patterns verified against Apple docs and community implementations; existing codebase provides clear integration points
- Pitfalls: HIGH - ModelActor thread behavior documented by multiple independent sources; SwiftData migration pitfalls well-known
- File Provider change enumeration: HIGH - core pattern (didUpdate/didDeleteItems/finishEnumeratingChanges) confirmed by WWDC session and multiple implementations
- Partial content fetching: MEDIUM - API exists but detailed implementation verified only against API signatures, not working examples
- Pinning behavior: MEDIUM - content policy enum values confirmed but detailed system interaction not fully verified

**Research date:** 2026-03-12
**Valid until:** 2026-04-12 (stable Apple frameworks, unlikely to change)
