# Phase 1: Foundation - Research

**Researched:** 2026-03-11
**Domain:** macOS app foundation -- renaming, OSLog, File Provider resilience, SwiftData metadata, S3 error mapping
**Confidence:** HIGH

## Summary

Phase 1 is a large-scope foundation phase that touches every target in the project: the main app (CubbitDS3Sync), the File Provider extension (Provider), and the shared library (DS3Lib). The work spans six distinct domains: (1) renaming the app from "CubbitDS3Sync" to "DS3 Drive" with new bundle identifiers, (2) adding structured OSLog-based logging with domain categories, (3) removing force-unwrapped optionals from the extension init to prevent crashes, (4) setting up a SwiftData metadata database shared between processes via App Group, (5) validating multipart upload ETags, and (6) mapping S3 errors to correct NSFileProviderError codes.

The codebase currently uses Swift 5.0 with macOS 14.2 deployment target, Soto v6.8.0 for S3, and swift-atomics 1.2.0. DS3Lib is an Xcode framework target (not SPM). The context decisions call for converting DS3Lib to a local Swift Package, raising the deployment target to macOS 15, enabling Swift 6 strict concurrency, and adding SwiftLint/SwiftFormat with pre-commit hooks. These are significant structural changes that must be carefully ordered -- the rename and SPM conversion should happen first, then the code quality improvements can layer on top.

The most technically risky area is SwiftData cross-process access via App Group container. SQLite in WAL mode supports one writer and many readers concurrently across processes, but SQLITE_BUSY errors can occur when both the main app and extension write simultaneously. Using ModelActor for background operations and keeping write operations minimal in the extension (Phase 1 only sets up the schema and access layer, not heavy writes) mitigates this risk.

**Primary recommendation:** Order the work as: (1) rename + SPM conversion + deployment target bump, (2) logging infrastructure, (3) extension crash fixes + error mapping, (4) SwiftData setup, (5) code quality tooling + Swift 6 concurrency. The rename must come first because it changes file paths, bundle IDs, and project structure that everything else depends on.

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
- Full rename from "CubbitDS3Sync" to "DS3 Drive" with bundle identifiers `io.cubbit.DS3Drive` (app), `io.cubbit.DS3Drive.provider` (extension), App Group `group.io.cubbit.DS3Drive`
- Xcode project renamed to `DS3Drive.xcodeproj`, scheme to `DS3Drive`
- Main app directory `CubbitDS3Sync/` -> `DS3Drive/`, Provider directory `Provider/` -> `DS3DriveProvider/`
- All Swift files and types containing "CubbitDS3Sync" get renamed
- Keep `DS3Lib` module name, `DS3` prefix on types, current app icon
- Internal constants renamed: API key prefix `DS3Drive-for-macOS`, notification names `io.cubbit.DS3Drive.notifications.*`, UserDefaults keys updated
- Full entitlement audit, Info.plist updates, Git repo renamed, README and CI updated
- SwiftData for SyncedItem metadata only -- SharedData (JSON files) stays for config/credentials/drives
- VersionedSchema protocol from the start
- Sync status enum with raw values: pending, syncing, synced, error, conflict
- SyncedItem hard deleted when drive is removed
- MetadataStore access layer in `DS3Lib/Metadata/` with SyncedItem.swift and MetadataStore.swift
- Testing deferred -- no unit tests for MetadataStore in Phase 1
- Each process creates its own ModelContainer pointing to same SQLite in App Group
- Remove all force-unwrapped optionals from FileProviderExtension init
- On init failure: log error, set enabled=false, return NSFileProviderError codes, no self-healing
- Extension notifies main app on failure via DistributedNotificationCenter
- Healthy drives continue independently (per-domain isolation)
- Recovery: retry button (primary), remove and re-add drive (fallback)
- Detailed S3-to-NSFileProviderError mapping
- Multipart upload: validate ETag from CompleteMultipartUpload, retry on mismatch, always abort on failure
- Add separate connection timeout (shorter) alongside 5-minute request timeout
- Logging: subsystem = target bundle ID, category = domain (sync, auth, transfer, extension, app, metadata)
- Per-class Logger instances with standardized log levels
- Fix copyFolder early return bug (S3Lib.swift:374)
- Fix EnumeratorError typo
- Replace print() with logger
- Clean up empty catch blocks
- Convert DS3Lib to Swift Package (SPM)
- Raise minimum deployment target to macOS 15 (Sequoia)
- Enable Swift 6 strict concurrency (-strict-concurrency=complete)
- Add SwiftLint + SwiftFormat with pre-commit hooks
- Set up Debug/Release build configurations
- Add meaningful access control
- Document DS3Lib public API with /// doc comments

### Claude's Discretion
- Drive ID field on SyncedItem (explicit driveId vs. infer from bucket/prefix)
- Index strategy (which SyncedItem fields to index)
- Cross-process ModelContainer concurrency approach (WAL mode, ModelActor, etc.)
- Module splitting decision for DS3Lib (keep monolithic or split)
- Dependency injection pattern for extension (constructor injection vs. service locator)
- Error handling pattern (unified hierarchy vs. per-domain enums)

### Deferred Ideas (OUT OF SCOPE)
None -- discussion stayed within phase scope
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|-----------------|
| FOUN-01 | App renamed to "DS3 Drive" with updated bundle identifiers and branding | Xcode rename process documented; 108 occurrences of "CubbitDS3Sync" across 35 files identified; bundle IDs, entitlements, Info.plist, CI all need updating |
| FOUN-02 | OSLog-based structured logging with categories across all targets | Logger subsystem/category pattern researched; 6 categories defined; existing inconsistent subsystem strings catalogued (4 different variants found) |
| FOUN-03 | Force-unwrapped optionals removed from File Provider extension init (graceful error handling) | 6 force-unwraps identified in FileProviderExtension.init; pattern for graceful degradation with `enabled=false` already partially in place |
| FOUN-04 | SwiftData metadata database shared between main app and extension via App Group container | ModelConfiguration with App Group container researched; VersionedSchema pattern documented; cross-process WAL mode implications understood |
| SYNC-07 | Multipart upload validates ETag from CompleteMultipartUpload response | Current code discards CompleteMultipartUpload response (line 632); withRetries utility available for retry logic; abort logic already exists |
| SYNC-08 | File Provider error codes mapped correctly to NSFileProviderError for proper system retry behavior | Complete S3 error code list obtained; NSFileProviderError.Code enumeration documented; current mapping is nearly all `NSFileReadUnknownError` (broken) |
</phase_requirements>

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| SwiftData | macOS 15+ | Persistent metadata store for SyncedItem | Apple's modern persistence framework; supports App Group sharing via ModelConfiguration; VersionedSchema for migrations |
| OSLog (os.Logger) | macOS 14+ | Structured logging | Apple's unified logging system; zero-cost when logs not collected; subsystem/category filtering in Console.app |
| FileProvider | macOS 12+ | NSFileProviderReplicatedExtension | Apple's file sync framework; already in use |
| SotoS3 | 6.8.0 | S3 client for Swift | Already in use; provides S3ErrorType for error mapping |
| swift-atomics | 1.2.0 | Thread-safe state flags | Already in use for extension shutdown flag |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| SwiftLint | latest | Static analysis / linting | Run on every build and pre-commit; catches style issues and potential bugs |
| SwiftFormat | latest | Code formatting | Run on pre-commit hook; enforces consistent code style |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| SwiftData | Core Data | SwiftData is the modern replacement; Core Data would work but VersionedSchema is cleaner than Core Data migration mapping models |
| SwiftData | GRDB/SQLite direct | More control over cross-process WAL, but loses Apple integration, requires manual migration management |
| SwiftLint (Homebrew) | SwiftLint SPM plugin | SPM plugin integrates into build but can be slower; Homebrew is faster for pre-commit hooks |

**Installation:**
```bash
# SwiftLint and SwiftFormat via Homebrew (for pre-commit hooks)
brew install swiftlint swiftformat

# Pre-commit hook setup
# Create .git/hooks/pre-commit with SwiftLint + SwiftFormat
```

## Architecture Patterns

### Recommended Project Structure (Post-Rename)
```
DS3Drive.xcodeproj
DS3Drive/                         # Main app target (was CubbitDS3Sync/)
├── DS3DriveApp.swift            # @main entry point (was CubbitDS3SyncApp.swift)
├── Assets/
├── Views/
├── Info.plist
└── DS3Drive.entitlements
DS3DriveProvider/                 # Extension target (was Provider/)
├── FileProviderExtension.swift
├── FileProviderExtension+Errors.swift
├── S3Lib.swift
├── S3Enumerator.swift
├── S3Item.swift
├── S3Item+Metadata.swift
├── NotificationsManager.swift
├── Info.plist
└── DS3DriveProvider.entitlements
DS3Lib/                           # Local Swift Package (was Xcode framework)
├── Package.swift
├── Sources/DS3Lib/
│   ├── Constants/
│   │   ├── DefaultSettings.swift
│   │   └── URLs.swift
│   ├── Models/
│   ├── SharedData/
│   ├── Metadata/                # NEW - SwiftData models and access layer
│   │   ├── SyncedItem.swift
│   │   └── MetadataStore.swift
│   ├── Utils/
│   ├── DS3Authentication.swift
│   ├── DS3DriveManager.swift
│   ├── DS3SDK.swift
│   └── AppStatusManager.swift
│   └── DS3Lib.h                 # May be removed when converting to SPM
└── Tests/DS3LibTests/           # Placeholder for future tests
Assets/                           # Git LFS managed assets
.github/workflows/build.yml      # Updated CI
```

### Pattern 1: SwiftData Cross-Process Sharing via App Group
**What:** Both the main app and File Provider extension create their own ModelContainer pointing to the same SQLite file in the App Group container.
**When to use:** Any time metadata must be readable/writable from both processes.
**Example:**
```swift
// Source: Apple Developer Documentation - ModelConfiguration
import SwiftData

enum MetadataStore {
    static func makeContainer() throws -> ModelContainer {
        let schema = Schema(versionedSchema: SyncedItemSchemaV1.self)
        let config = ModelConfiguration(
            "SyncedItems",
            schema: schema,
            groupContainer: .identifier("group.io.cubbit.DS3Drive")
        )
        return try ModelContainer(for: schema, configurations: [config])
    }
}
```

### Pattern 2: Graceful Extension Initialization
**What:** Replace force-unwraps with optional handling; set `enabled = false` on failure.
**When to use:** FileProviderExtension.init(domain:)
**Example:**
```swift
required init(domain: NSFileProviderDomain) {
    self.enabled = false
    self.domain = domain
    self.temporaryDirectory = try? NSFileProviderManager(for: domain)?.temporaryDirectoryURL()

    do {
        let sharedData = try SharedData.default()
        self.drive = try sharedData.loadDS3DriveFromPersistence(
            withDomainIdentifier: domain.identifier
        )
        guard let drive = self.drive else {
            logger.error("No drive found for domain \(domain.identifier.rawValue)")
            super.init()
            return
        }
        // ... continue setup with proper nil checks
        self.enabled = true
    } catch {
        logger.error("Extension init failed: \(error.localizedDescription)")
        // enabled stays false; all methods return appropriate errors
    }
    super.init()
}
```

### Pattern 3: VersionedSchema for SwiftData
**What:** Define the schema with explicit versioning from day one.
**When to use:** SyncedItem model definition.
**Example:**
```swift
// Source: Hacking with Swift - SwiftData VersionedSchema
enum SyncedItemSchemaV1: VersionedSchema {
    static var versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] { [SyncedItem.self] }

    @Model
    final class SyncedItem {
        @Attribute(.unique) var s3Key: String
        var driveId: UUID
        var etag: String?
        var lastModified: Date?
        var localFileHash: String?
        var syncStatus: String  // "pending", "syncing", "synced", "error", "conflict"
        var parentKey: String?
        var contentType: String?
        var size: Int64

        init(s3Key: String, driveId: UUID, size: Int64 = 0) {
            self.s3Key = s3Key
            self.driveId = driveId
            self.size = size
            self.syncStatus = "pending"
        }
    }
}

enum SyncedItemMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [SyncedItemSchemaV1.self] }
    static var stages: [MigrationStage] { [] }  // No migrations yet
}
```

### Pattern 4: S3 Error to NSFileProviderError Mapping
**What:** Map specific S3 error codes to the correct NSFileProviderError.Code values so the system retries or presents UI appropriately.
**When to use:** All S3Lib error paths that surface to FileProviderExtension methods.
**Example:**
```swift
extension S3ErrorType {
    func toFileProviderError() -> NSFileProviderError {
        switch self.errorCode {
        case "AccessDenied", "InvalidAccessKeyId", "SignatureDoesNotMatch":
            return NSFileProviderError(.notAuthenticated)
        case "NoSuchKey":
            return NSFileProviderError(.noSuchItem)
        case "NoSuchBucket":
            return NSFileProviderError(.noSuchItem)
        case "ExpiredToken":
            return NSFileProviderError(.notAuthenticated)
        case "EntityTooLarge":
            return NSFileProviderError(.insufficientQuota)
        case "SlowDown", "ServiceUnavailable", "InternalError":
            return NSFileProviderError(.serverUnreachable)
        case "RequestTimeout":
            return NSFileProviderError(.serverUnreachable)
        default:
            return NSFileProviderError(.cannotSynchronize)
        }
    }
}
```

### Pattern 5: OSLog Centralized Category Definition
**What:** Define all logger categories in one place so they stay consistent.
**When to use:** Every class that logs.
**Example:**
```swift
// In DS3Lib/Constants/DefaultSettings.swift or dedicated Logging.swift
enum LogCategory: String {
    case sync       // File sync operations
    case auth       // Authentication flow
    case transfer   // Upload/download data transfer
    case `extension` // File Provider extension lifecycle
    case app        // Main app lifecycle
    case metadata   // SwiftData/metadata operations
}

// Usage in any class:
private let logger = Logger(
    subsystem: "io.cubbit.DS3Drive",      // or .provider for extension
    category: LogCategory.sync.rawValue
)
```

### Anti-Patterns to Avoid
- **Force-unwrapping SharedData results in extension init:** This is the #1 crash source. Always use `guard let` or `if let`.
- **Using `print()` for logging:** `print()` does not appear in Console.app, has no level filtering, and cannot be filtered by subsystem/category.
- **Ignoring S3 API responses:** The current code discards DeleteObject, CopyObject, and CompleteMultipartUpload responses. All responses must be checked for error indicators.
- **Using NSFileReadUnknownError for all S3 errors:** This prevents the system from retrying appropriately. `.notAuthenticated` triggers re-auth UI; `.serverUnreachable` triggers exponential backoff; `.noSuchItem` removes the item from the working set.
- **Defining SwiftData models without VersionedSchema:** Adding VersionedSchema retroactively after the first release requires careful migration setup. Use it from the start.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Structured logging | Custom log framework | `os.Logger` with subsystem/category | Apple's unified logging is zero-cost, integrates with Console.app, respects privacy annotations |
| Metadata persistence | Custom SQLite wrapper | SwiftData with VersionedSchema | Apple-supported, cross-process via App Group, automatic migration support |
| S3 client | Raw HTTP/URLSession S3 calls | Soto v6 (SotoS3) | Already in use; handles signing, retries, multipart uploads |
| Retry logic | Manual while loops | Existing `withRetries()` in ControlFlow.swift | Already tested and available in codebase |
| Code formatting | Manual style enforcement | SwiftFormat + SwiftLint | Automated, consistent, catches issues pre-commit |
| Cross-process state sharing | Custom IPC mechanism | App Group container + DistributedNotificationCenter | Already in use; Apple-blessed pattern for app/extension communication |

**Key insight:** This phase is about stabilizing and standardizing what exists, not inventing new patterns. Use Apple frameworks (OSLog, SwiftData, FileProvider error codes) and existing codebase utilities (withRetries, SharedData, NotificationManager).

## Common Pitfalls

### Pitfall 1: Xcode Project Rename Breaking References
**What goes wrong:** Renaming the .xcodeproj, directories, and files leaves stale references in the pbxproj, xcschemes, Info.plist, and entitlements files.
**Why it happens:** The Xcode project file (project.pbxproj) contains absolute and relative paths to source files, groups, and build settings. Renaming outside of Xcode does not update these references.
**How to avoid:** Use a systematic approach: (1) rename directories first, (2) update pbxproj file references via find-and-replace on the raw XML/plist, (3) update xcscheme files, (4) update all entitlements and Info.plist files, (5) update CI workflow. Build and verify after each step.
**Warning signs:** "File not found" build errors; "No such module" errors; provisioning profile mismatches; extension fails to load.

### Pitfall 2: SwiftData Cross-Process SQLITE_BUSY
**What goes wrong:** Both the main app and File Provider extension try to write to the same SwiftData store simultaneously, causing SQLITE_BUSY errors.
**Why it happens:** SQLite in WAL mode allows one writer and many readers, but two concurrent writers will conflict.
**How to avoid:** In Phase 1, the extension is read-only for SwiftData (it does not write SyncedItem records yet -- that comes in Phase 2). The main app owns writes. If both need to write in the future, use short write transactions and handle SQLITE_BUSY with retry logic.
**Warning signs:** `NSPersistentStoreCoordinator` errors in logs; data not appearing in the other process; intermittent save failures.

### Pitfall 3: NSFileProviderError.notAuthenticated Triggers System UI
**What goes wrong:** Returning `.notAuthenticated` from the extension causes the system to throttle ALL operations for that domain and present a system alert. The domain becomes effectively frozen until `signalErrorResolved()` is called.
**Why it happens:** Apple treats `.notAuthenticated` as a resolvable error -- the system waits for the app to signal that the auth issue is fixed.
**How to avoid:** Only return `.notAuthenticated` for genuine auth failures (AccessDenied, InvalidAccessKeyId, ExpiredToken). For transient errors, use `.serverUnreachable` or `.cannotSynchronize` which the system retries automatically.
**Warning signs:** Drive appears stuck; system shows "sign in" prompt; operations never resume even after the transient error clears.

### Pitfall 4: Swift 6 Strict Concurrency Cascade
**What goes wrong:** Enabling `-strict-concurrency=complete` produces hundreds of warnings/errors because the existing codebase has no Sendable conformances, uses mutable shared state, and mixes callback-based and async code.
**Why it happens:** The codebase uses Swift 5.0 with no concurrency annotations. DS3Drive (an @Observable class) is shared across actors, S3Lib captures `self` in async closures, and the FileProvider completion handlers don't have Sendable constraints.
**How to avoid:** Enable strict concurrency AFTER the rename and SPM conversion, so you are working with the final file structure. Fix warnings incrementally: (1) mark simple types as Sendable, (2) add @MainActor to UI types, (3) use ModelActor for SwiftData, (4) address remaining warnings.
**Warning signs:** Build produces 100+ concurrency warnings; `self` captured in @Sendable closure warnings; "non-sendable type passed across actor boundaries".

### Pitfall 5: Inconsistent Logger Subsystem Strings
**What goes wrong:** Different parts of the codebase use different subsystem strings, making Console.app filtering unreliable.
**Why it happens:** The current codebase has at least 4 different subsystem variants: `io.cubbit.CubbitDS3Sync`, `io.cubbit.CubbitDS3Sync.provider`, `io.cubbit.CubbitDS3Sync.DS3Lib`, `com.cubbit.CubbitDS3Sync` (note the `com` prefix in DS3SDK.swift).
**How to avoid:** After the rename, establish exactly two subsystem strings: `io.cubbit.DS3Drive` (main app + DS3Lib when loaded by app) and `io.cubbit.DS3Drive.provider` (extension). Use category for domain differentiation (sync, auth, transfer, etc.).
**Warning signs:** Logs don't appear when filtering by subsystem in Console.app; duplicate log entries with different subsystems.

### Pitfall 6: DS3Lib SPM Conversion Dependency Issues
**What goes wrong:** Converting DS3Lib from an Xcode framework target to a local Swift Package breaks the dependency chain because DS3Lib depends on SotoS3, swift-atomics, and other packages currently managed at the project level.
**Why it happens:** When DS3Lib becomes a Swift Package, it needs its own Package.swift declaring its dependencies. The project-level SPM dependencies must then be referenced through DS3Lib rather than directly.
**How to avoid:** The DS3Lib Package.swift must declare SotoS3 and swift-atomics as dependencies. Both app and extension targets link DS3Lib (the local package), which transitively provides SotoS3.
**Warning signs:** "No such module 'SotoS3'" in Provider target; duplicate symbol errors; "This will result in duplication of library code" warnings.

## Code Examples

### Current Force-Unwrap Issues in FileProviderExtension.init (6 force-unwraps)
```swift
// Source: Provider/FileProviderExtension.swift lines 32-53
// Current problematic code:
self.notificationManager = NotificationManager(drive: self.drive!)       // line 32 - crash if drive nil
self.endpoint = try SharedData.default().loadAccountFromPersistence().endpointGateway  // no crash but throws
self.apiKeys = try SharedData.default().loadDS3APIKeyFromPersistence(
    forUser: self.drive!.syncAnchor.IAMUser,                             // line 35 - crash if drive nil
    projectName: self.drive!.syncAnchor.project.name                     // line 36 - crash if drive nil
)
let client = AWSClient(
    credentialProvider: .static(
        accessKeyId: self.apiKeys!.apiKey,                               // line 42 - crash if apiKeys nil
        secretAccessKey: self.apiKeys!.secretKey!                         // line 43 - crash if secretKey nil (double!)
    ),
    ...
)
self.s3 = S3(
    client: client,
    endpoint: self.endpoint!,                                            // line 49 - crash if endpoint nil
    ...
)
```

### S3 Error Mapping -- Current vs. Correct
```swift
// Current: ALL S3 errors map to NSFileReadUnknownError (useless)
extension S3ErrorType {
    func toPresentableError() -> NSError {
        return NSError(domain: NSFileProviderErrorDomain, code: NSFileReadUnknownError, userInfo: nil)
    }
}

// Correct: Map to specific NSFileProviderError.Code values
// Source: Apple NSFileProviderError.Code documentation + AWS S3 Error Responses
extension S3ErrorType {
    func toFileProviderError() -> NSError {
        let code: NSFileProviderError.Code
        switch self.errorCode {
        // Auth errors -> .notAuthenticated (system shows re-auth UI, throttles until resolved)
        case "AccessDenied", "InvalidAccessKeyId", "SignatureDoesNotMatch", "ExpiredToken":
            code = .notAuthenticated
        // Not found errors -> .noSuchItem (system removes item from working set)
        case "NoSuchKey", "NoSuchBucket":
            code = .noSuchItem
        // Quota errors -> .insufficientQuota
        case "EntityTooLarge":
            code = .insufficientQuota
        // Server errors -> .serverUnreachable (system retries with backoff)
        case "SlowDown", "ServiceUnavailable", "InternalError", "RequestTimeout":
            code = .serverUnreachable
        // Default -> .cannotSynchronize (generic retryable error)
        default:
            code = .cannotSynchronize
        }
        return NSFileProviderError(code) as NSError
    }
}
```

### Multipart Upload ETag Validation
```swift
// Source: Provider/S3Lib.swift - enhanced putS3ItemMultipart
// Current code discards the CompleteMultipartUpload response:
//   let _ = try await self.s3.completeMultipartUpload(completeMultipartRequest)
//
// Fixed version validates the ETag:
let completeResponse = try await self.s3.completeMultipartUpload(completeMultipartRequest)

guard let eTag = completeResponse.eTag, !eTag.isEmpty else {
    logger.error("CompleteMultipartUpload returned no ETag for key \(key)")
    try await self.abortS3MultipartUpload(for: s3Item, withUploadId: uploadId)
    throw FileProviderExtensionError.uploadValidationFailed
}

logger.info("Multipart upload complete for \(key) with ETag \(eTag)")
```

### copyFolder Bug Fix
```swift
// Source: Provider/S3Lib.swift line 374
// Current (buggy): `return` causes early exit after first item
while !items.isEmpty {
    let item = items.removeFirst()
    let newKey = item.identifier.rawValue
        .replacingOccurrences(of: prefix, with: newPrefix)
        .removingPercentEncoding!
    return try await self.copyS3Item(item, toKey: newKey, withProgress: progress)  // BUG: return
}

// Fixed: use `try await` without `return`
while !items.isEmpty {
    let item = items.removeFirst()
    let newKey = item.identifier.rawValue
        .replacingOccurrences(of: prefix, with: newPrefix)
        .removingPercentEncoding!
    try await self.copyS3Item(item, toKey: newKey, withProgress: progress)  // FIX: no return
}
```

### DS3Lib Package.swift (for SPM conversion)
```swift
// Package.swift for the local DS3Lib Swift Package
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DS3Lib",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "DS3Lib", targets: ["DS3Lib"]),
    ],
    dependencies: [
        .package(url: "https://github.com/soto-project/soto", from: "6.8.0"),
        .package(url: "https://github.com/apple/swift-atomics.git", from: "1.2.0"),
    ],
    targets: [
        .target(
            name: "DS3Lib",
            dependencies: [
                .product(name: "SotoS3", package: "soto"),
                .product(name: "Atomics", package: "swift-atomics"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "DS3LibTests",
            dependencies: ["DS3Lib"]
        ),
    ]
)
```

## Discretion Recommendations

### Drive ID Field on SyncedItem
**Recommendation: Use explicit `driveId: UUID` field.**
Rationale: Inferring drive identity from bucket+prefix is fragile. A user could create two drives pointing to the same bucket with different prefixes, or even the same bucket/prefix after deleting and recreating a drive. An explicit driveId makes deletion (`deleteItemsForDrive(driveId:)`) trivial and unambiguous.

### Index Strategy for SyncedItem
**Recommendation: Index `s3Key` (unique, used for lookups), `driveId` (used for bulk deletes and filtering), and `syncStatus` (used for querying items in error/conflict state).**
In SwiftData, use `@Attribute(.unique)` on s3Key and `#Index` macro (available macOS 15+) on `[driveId]` and `[driveId, syncStatus]` compound index.

### Cross-Process ModelContainer Concurrency
**Recommendation: Use WAL mode (default for SwiftData/SQLite) with separate ModelContainer instances per process. In Phase 1, keep writes to main app only. In Phase 2 when the extension needs to write, use short transactions and handle errors.**
Rationale: ModelActor is useful for background operations within a single process but does not solve cross-process contention. WAL mode naturally handles one-writer/many-readers. Since Phase 1 only creates the schema and MetadataStore access layer (no heavy writes from the extension), cross-process contention is not a concern yet.

### Module Splitting for DS3Lib
**Recommendation: Keep DS3Lib monolithic in Phase 1.** The SPM conversion is already a significant change. Splitting into sub-modules (e.g., DS3Auth, DS3Models, DS3Metadata) can be done in a future phase if the module grows unwieldy. The single-package structure keeps the dependency graph simple.

### Dependency Injection for Extension
**Recommendation: Constructor injection via a simple struct.** Create an `ExtensionDependencies` struct that holds optional references to S3Lib, NotificationManager, drive, etc. The init method builds this struct; if any dependency fails, the struct is nil and `enabled` stays false. This is simpler than a service locator and more testable.

### Error Handling Pattern
**Recommendation: Per-domain enums with a shared protocol.** Keep `FileProviderExtensionError`, `EnumeratorError`, `SharedDataError`, and `DS3AuthenticationError` as separate enums (they are already separate). Add a shared protocol `DS3Error` with a method `toFileProviderError() -> NSFileProviderError` so any error type can produce the correct NSFileProviderError when needed by the extension. This avoids a monolithic error hierarchy while providing consistent mapping.

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Core Data for persistence | SwiftData with VersionedSchema | WWDC 2023/2024 | Cleaner API, built-in migration, Swift-native |
| NSLog / print() | os.Logger with subsystem/category | iOS 14+ / macOS 11+ | Zero-cost when not collected, privacy annotations, Console.app filtering |
| Xcode framework targets | Local Swift Packages | Xcode 15+ | Better build times, cleaner dependency management, testable in isolation |
| Swift 5 concurrency (unchecked) | Swift 6 strict concurrency | Swift 6.0 (2024) | Compile-time data race detection, Sendable enforcement |
| SwiftLint via CocoaPods/Homebrew | SwiftLint SPM plugin or Homebrew + pre-commit | 2024-2025 | SPM plugin available but Homebrew is faster for pre-commit hooks |

**Deprecated/outdated:**
- `NSLog`: Replaced by os.Logger. NSLog is slow, not structured, and does not support privacy annotations.
- `print()`: Not visible in Console.app, no filtering, no privacy. Must be replaced throughout.
- Xcode framework targets for shared code: Local SPM packages are the modern standard. They provide better build caching, explicit dependency declarations, and easier testing.

## Open Questions

1. **SwiftData @Index macro availability on macOS 15**
   - What we know: The `#Index` macro was introduced in WWDC 2024. It should be available on macOS 15 (Sequoia).
   - What's unclear: Whether compound indexes (`#Index<SyncedItem>([\.driveId, \.syncStatus])`) are fully supported on macOS 15.0 or require 15.x.
   - Recommendation: Verify at implementation time. If not available, use `@Attribute(.unique)` on s3Key and accept unindexed queries for driveId (acceptable for Phase 1 volumes).

2. **Swift 6 compatibility of Soto v6.8.0**
   - What we know: Soto v6 was released before Swift 6. The `@Sendable` annotations on S3Lib methods suggest some concurrency awareness.
   - What's unclear: Whether Soto v6.8.0 compiles cleanly with `-strict-concurrency=complete`.
   - Recommendation: Enable strict concurrency last. If Soto produces warnings, use `@preconcurrency import SotoS3` as a temporary workaround.

3. **AWSClient lifecycle management under Swift 6**
   - What we know: AWSClient uses `syncShutdown()` which is not async. The current code calls it from `S3Lib.shutdown()`.
   - What's unclear: Whether `syncShutdown()` is safe to call from an async context in Swift 6 strict concurrency mode.
   - Recommendation: Wrap in a `nonisolated` context or use `AWSClient.shutdown()` (async version if available in Soto v6.8.0).

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | XCTest (built into Xcode) |
| Config file | None -- see Wave 0 |
| Quick run command | `xcodebuild test -scheme DS3Drive -destination 'platform=macOS'` |
| Full suite command | `xcodebuild test -scheme DS3Drive -destination 'platform=macOS'` |

### Phase Requirements -> Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| FOUN-01 | App launches with correct bundle ID and branding | manual-only | Manual: verify in Xcode + Finder | N/A |
| FOUN-02 | Structured log entries appear in Console.app with categories | manual-only | Manual: filter Console.app by subsystem | N/A |
| FOUN-03 | Extension init does not crash with missing SharedData | unit | `xcodebuild test -scheme DS3Drive -only-testing DS3LibTests` | No -- Wave 0 |
| FOUN-04 | SwiftData database accessible from both processes | integration | Manual: launch app + extension, verify records | N/A |
| SYNC-07 | Multipart upload validates ETag from CompleteMultipartUpload | unit | `xcodebuild test -scheme DS3Drive -only-testing DS3LibTests` | No -- Wave 0 |
| SYNC-08 | S3 errors map to correct NSFileProviderError codes | unit | `xcodebuild test -scheme DS3Drive -only-testing DS3LibTests` | No -- Wave 0 |

Note: CONTEXT.md explicitly states "Testing deferred -- no unit tests for MetadataStore in Phase 1." Several requirements are best verified manually (bundle IDs, Console.app filtering). Error mapping (SYNC-08) is highly testable but tests are deferred per user decision.

### Sampling Rate
- **Per task commit:** Build succeeds with `xcodebuild clean build -scheme DS3Drive -destination 'platform=macOS'`
- **Per wave merge:** Full build + manual verification of success criteria
- **Phase gate:** All 5 success criteria verified before phase completion

### Wave 0 Gaps
- [ ] `DS3Lib/Tests/DS3LibTests/` -- test target created in Package.swift but no test files
- [ ] Test infrastructure deferred per user decision -- no unit tests required in Phase 1

## Sources

### Primary (HIGH confidence)
- [Apple NSFileProviderError.Code documentation](https://developer.apple.com/documentation/fileprovider/nsfileprovidererror/code) - Complete error code enumeration
- [Apple ModelConfiguration.GroupContainer](https://developer.apple.com/documentation/swiftdata/modelconfiguration/groupcontainer-swift.struct) - SwiftData App Group configuration
- [Apple NSFileProviderReplicatedExtension](https://developer.apple.com/documentation/fileprovider/nsfileproviderreplicatedextension) - Extension lifecycle
- [AWS S3 Error Responses](https://docs.aws.amazon.com/AmazonS3/latest/API/ErrorResponses.html) - Complete S3 error code list
- [Soto Error Handling](https://soto.codes/user-guides/error-handling.html) - S3ErrorType patterns
- [Apple Adopting Swift 6](https://developer.apple.com/documentation/swift/adoptingswift6) - Strict concurrency migration guide
- Codebase analysis: Provider/FileProviderExtension.swift, S3Lib.swift, DefaultSettings.swift, S3Enumerator.swift

### Secondary (MEDIUM confidence)
- [Hacking with Swift - SwiftData VersionedSchema](https://www.hackingwithswift.com/quick-start/swiftdata/how-to-create-a-complex-migration-using-versionedschema) - Migration patterns
- [SwiftLee - OSLog and Unified Logging](https://www.avanderlee.com/debugging/oslog-unified-logging/) - Logger best practices
- [Medium - ModelActor and Swift Concurrency](https://killlilwinters.medium.com/taking-swiftdata-further-modelactor-swift-concurrency-and-avoiding-mainactor-pitfalls-3692f61f2fa1) - Cross-actor SwiftData patterns
- [Apriorit - File Provider API on macOS](https://www.apriorit.com/dev-blog/730-mac-how-to-work-with-the-file-provider-for-macos) - Extension initialization patterns
- [SwiftLee - Approachable Concurrency Swift 6.2](https://www.avanderlee.com/concurrency/approachable-concurrency-in-swift-6-2-a-clear-guide/) - Swift 6 concurrency adoption
- [GitHub Gist - SwiftLint/SwiftFormat pre-commit hook](https://gist.github.com/joeblau/a82bd6c353a076adb3698585c5d56d94) - Hook setup

### Tertiary (LOW confidence)
- SwiftData cross-process WAL behavior -- verified via SQLite WAL docs but not directly tested with SwiftData
- Soto v6.8.0 Swift 6 compatibility -- inferred from @Sendable annotations, not verified with strict concurrency enabled

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH - all libraries are already in use or are Apple first-party frameworks
- Architecture: HIGH - patterns verified against Apple docs and existing codebase conventions
- Pitfalls: HIGH - identified from actual codebase analysis (6 force-unwraps, 4 inconsistent subsystems, 108 rename occurrences)
- SwiftData cross-process: MEDIUM - Apple docs confirm App Group sharing works, but cross-process write contention under load is less proven
- Swift 6 strict concurrency migration: MEDIUM - scope of changes uncertain until attempted; Soto compatibility unverified

**Research date:** 2026-03-11
**Valid until:** 2026-04-11 (30 days -- stable technologies, no fast-moving areas)
