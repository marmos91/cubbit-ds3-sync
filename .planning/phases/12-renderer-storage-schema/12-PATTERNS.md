# Phase 12: Renderer, Storage & Schema - Pattern Map

**Mapped:** 2026-04-24
**Files analyzed:** 10 new + 5 modified + 2 deletions
**Analogs found:** 15 / 15 (100% analog coverage — Phase 12 is a mechanical extraction + 1:1 mirror exercise)

## File Classification

| New/Modified File | Role | Data Flow | Closest Analog | Match Quality |
|-------------------|------|-----------|----------------|---------------|
| **NEW** `DS3Lib/Sources/DS3Lib/Thumbnails/ThumbnailRenderer.swift` | utility (pure decode) | transform (file → bytes) | `DS3DriveProvider/FileProviderExtension+ThumbnailGenerators.swift` (lines 29-75, 138-155) | exact — verbatim extraction |
| **NEW** `DS3Lib/Sources/DS3Lib/Thumbnails/ThumbnailBackfillCoordinator.swift` | service (actor) | batch orchestration | `DS3Lib/Sources/DS3Lib/Metadata/MetadataStore.swift` (actor shape only); borrows temp-file pattern from `DS3DriveProvider/FileProviderExtension+Thumbnails.swift:219-224` | role-match (no exact analog) |
| **NEW** `DS3Lib/Sources/DS3Lib/DS3S3Client+Thumbnails.swift` | service (S3 extension) | request-response | `DS3Lib/Sources/DS3Lib/DS3S3Client+ThumbnailPrefix.swift` (protocol-extension shape); `DS3Lib/Sources/DS3Lib/DS3S3Client+Transfers.swift:157-169` (putObjectData call shape) | exact shape + composed |
| **NEW** `DS3Lib/Sources/DS3Lib/SharedData/SharedData+thumbnailSettings.swift` | config persistence | CRUD (JSON) | `DS3Lib/Sources/DS3Lib/SharedData/SharedData+trashSettings.swift` | exact — 1:1 mirror |
| **MODIFY** `DS3Lib/Sources/DS3Lib/Metadata/SyncedItem.swift` (append V3) | model (SwiftData schema) | migration | Same file: `SyncedItemSchemaV2` block (lines 62-156) + `migrateV1toV2` (lines 193-196) | exact — precedent in same file |
| **MODIFY** `DS3Lib/Sources/DS3Lib/Metadata/MetadataStore.swift` (line 16) | store bootstrap | one-line change | Same file: existing `Schema(versionedSchema: V2.self)` at `:16` | trivial |
| **MODIFY** `DS3Lib/Sources/DS3Lib/Metadata/MetadataStore+Queries.swift` (append) | query surface | read (Sendable DTO) | Same file: `CachedChildItem` DTO (lines 40-47) + `fetchChildren` (lines 56-83) + `setSyncStatus` (lines 134-142) | exact — precedent in same file |
| **MODIFY** `DS3Lib/Sources/DS3Lib/Constants/DefaultSettings.swift` (insert namespace) | constants | additive | Same file: `enum Trash` at `:208-215`, `enum S3` at `:161-206`, `FileNames.trashSettingsFileName` at `:154` | exact — namespace sibling |
| **MODIFY** `DS3DriveProvider/FileProviderExtension+Thumbnails.swift:338-346` | consumer call-site | request-response | Same file: existing call to `FileProviderExtension.generateImageThumbnail(from:fitting:)` | trivial replace |
| **DELETE** `DS3DriveProvider/FileProviderExtension+ThumbnailGenerators.swift` | — | — | n/a — content is moved into ThumbnailRenderer then file removed | n/a |
| **DELETE** `DS3DriveProviderTests/ThumbnailGeneratorTests.swift` (move to DS3LibTests) | test | unit | `DS3DriveProviderTests/ThumbnailGeneratorTests.swift` (same content, renamed + relocated) | exact — move |
| **NEW** `DS3Lib/Tests/DS3LibTests/ThumbnailRendererTests.swift` | test | unit | `DS3DriveProviderTests/ThumbnailGeneratorTests.swift` (verbatim body, fixture-loading swapped to `Bundle.module`) | exact — relocated |
| **NEW** `DS3Lib/Tests/DS3LibTests/DS3S3ClientThumbnailsTests.swift` | test | unit (mocked) | `DS3Lib/Tests/DS3LibTests/InspectThumbnailPrefixTests.swift` + `MockDS3S3Client.swift` | exact — Phase 11 mirror |
| **NEW** `DS3Lib/Tests/DS3LibTests/SchemaV3MigrationTests.swift` | test | migration | `DS3Lib/Tests/DS3LibTests/MetadataStoreMigrationTests.swift` | exact — test style precedent |
| **NEW** `DS3Lib/Tests/DS3LibTests/MetadataStoreThumbnailQueriesTests.swift` | test | unit (SwiftData in-memory) | `DS3Lib/Tests/DS3LibTests/MetadataStoreMigrationTests.swift:44-70` (in-memory store setup) | role-match |
| **NEW** `DS3Lib/Tests/DS3LibTests/SharedDataThumbnailSettingsTests.swift` | test | unit (round-trip) | `DS3Lib/Tests/DS3LibTests/SharedDataPersistenceTests.swift` (same pattern for trash/pause settings) | role-match |
| **NEW** `DS3Lib/Tests/DS3LibTests/ThumbnailBackfillCoordinatorTests.swift` | test | smoke | `DS3Lib/Tests/DS3LibTests/InspectThumbnailPrefixTests.swift` (mock-driven style) | role-match |
| **MODIFY** `DS3Drive.xcodeproj/project.pbxproj` | build config | pbxproj edit | existing fixture PBXBuildFile/PBXFileReference entries around lines 86, 319-323, 1307-1308 | pattern — remove entries |

## Pattern Assignments

### `DS3Lib/Sources/DS3Lib/Thumbnails/ThumbnailRenderer.swift` (utility, transform)

**Analog:** `DS3DriveProvider/FileProviderExtension+ThumbnailGenerators.swift`

**Imports pattern** (lines 1-6) — copy verbatim minus `AVFoundation` (video deleted per D-05):
```swift
import CoreGraphics
import DS3Lib  // — renderer IS DS3Lib; drop this
import ImageIO
import os
import UniformTypeIdentifiers
```
Final renderer imports: `CoreGraphics`, `ImageIO`, `os`, `UniformTypeIdentifiers`, `Foundation`.

**Whole-type macOS gate pattern** (D-03 — load-bearing for THUMB-07):
```swift
// Phase 12 NEW — wrap entire declaration, NOT just bodies
#if os(macOS)
public struct ThumbnailRenderer {
    // ... fields, init, methods ...
}
#endif
```

**Allow-list constant** (lines 13-21 in analog — move verbatim, make `private static`):
```swift
private nonisolated(unsafe) static let allowedRasterUTIs: Set<CFString> = [
    "public.jpeg" as CFString,
    "public.png" as CFString,
    "public.heic" as CFString,
    "public.heif" as CFString,
    "org.webmproject.webp" as CFString,
    "com.compuserve.gif" as CFString,
    "public.tiff" as CFString
]
```

**Memory guard constant** (line 26 in analog — move verbatim):
```swift
private static let minAvailableMemoryBytes: Int = 64 * 1024 * 1024
```

**Core render pattern** (lines 29-75 in analog — copy VERBATIM into `renderJPEG(from:)` instance method; change only: `maxSize` param → `self.maxDimension`, static → instance):
```swift
public func renderJPEG(from fileURL: URL) -> Data? {
    #if canImport(UIKit)
        // Note: unreachable given whole-type #if os(macOS) gate, but preserved for
        // defense-in-depth if the gate is ever relaxed (THUMB-07).
        let availableMemory = os_proc_available_memory()
        if availableMemory > 0, availableMemory < Self.minAvailableMemoryBytes {
            return nil
        }
    #endif

    return autoreleasepool {
        let sourceOptions: [CFString: Any] = [
            kCGImageSourceShouldCache: false
        ]
        guard let source = CGImageSourceCreateWithURL(
            fileURL as CFURL,
            sourceOptions as CFDictionary
        )
        else { return nil }

        guard let sourceType = CGImageSourceGetType(source),
              Self.allowedRasterUTIs.contains(sourceType)
        else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: self.maxDimension,  // was param
            kCGImageSourceCreateThumbnailWithTransform: true,        // MANDATORY — EXIF
            kCGImageSourceShouldCacheImmediately: true
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
            source, 0, options as CFDictionary
        )
        else { return nil }

        return jpegData(from: cgImage)
    }
}
```

**JPEG encoder pattern** (lines 138-155 in analog — move verbatim; change: read `self.jpegQuality` instead of `DefaultSettings.S3.thumbnailJPEGQuality`):
```swift
private func jpegData(from cgImage: CGImage) -> Data? {
    let data = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(
        data as CFMutableData,
        UTType.jpeg.identifier as CFString,
        1,
        nil
    )
    else { return nil }
    CGImageDestinationAddImage(
        dest,
        cgImage,
        [kCGImageDestinationLossyCompressionQuality: Double(self.jpegQuality)] as CFDictionary
    )
    guard CGImageDestinationFinalize(dest) else { return nil }
    return data as Data
}
```

**Init signature** (D-01 — exact form):
```swift
public init(
    maxDimension: CGFloat = CGFloat(DefaultSettings.S3.thumbnailMaxDimension),
    jpegQuality: Float = DefaultSettings.S3.thumbnailJPEGQuality
) {
    self.maxDimension = maxDimension
    self.jpegQuality = jpegQuality
}
```

**DELETED** (lines 78-135 in analog): `generateVideoThumbnail` + `generatePDFThumbnail` — do NOT carry forward (D-05).

---

### `DS3Lib/Sources/DS3Lib/DS3S3Client+Thumbnails.swift` (service, request-response)

**Primary analog (shape):** `DS3Lib/Sources/DS3Lib/DS3S3Client+ThumbnailPrefix.swift`
**Secondary analog (metadata PUT):** `DS3Lib/Sources/DS3Lib/DS3S3Client+Transfers.swift:155-169`

**Protocol-extension dispatch pattern** (analog lines 20-21 — verbatim shape):
```swift
// Source: DS3S3Client+ThumbnailPrefix.swift:20
public extension DS3S3ClientProtocol {
    func inspectThumbnailPrefix(bucket: String, prefix: String?) async throws -> ThumbnailPrefixState {
        let result = try await listObjects(
            bucket: bucket, prefix: thumbPrefix, delimiter: nil,
            maxKeys: 10, continuationToken: nil
        )
        // ...
    }
}
```
Phase 12 MUST place `putThumbnail` / `getThumbnailBytes` / `deleteThumbnail` on `public extension DS3S3ClientProtocol` (NOT on concrete `DS3S3Client`) so `MockDS3S3Client` inherits them for free (see `InspectThumbnailPrefixTests.swift:27`: `mock.inspectThumbnailPrefix(...)` with zero boilerplate).

**Soto PutObject pattern with bare metadata keys** (analog `DS3S3Client+Transfers.swift:157-168` — adapt by adding `metadata` parameter):
```swift
// Existing analog (no metadata)
func putObjectData(bucket: String, key: String, data: Data) async throws -> String? {
    let request = S3.PutObjectRequest(
        body: .byteBuffer(ByteBuffer(data: data)),
        bucket: bucket,
        key: key
    )
    let response = try await s3.putObject(request)
    return response.eTag
}
```

Phase 12 pattern — extend protocol with a metadata-aware variant (Pitfall 8 in RESEARCH.md recommends option 1) then call it from `putThumbnail`:
```swift
// In DS3S3ClientProtocol.swift add:
func putObjectData(
    bucket: String, key: String, data: Data, metadata: [String: String]?
) async throws -> String?

// Concrete impl in DS3S3Client+Transfers.swift — bare keys (Soto prepends x-amz-meta-):
let request = S3.PutObjectRequest(
    body: .byteBuffer(ByteBuffer(data: data)),
    bucket: bucket,
    key: key,
    metadata: metadata  // Soto prepends "x-amz-meta-" per header
)
```

**Single-part precondition** (D-12):
```swift
precondition(
    data.count < DefaultSettings.Thumbnail.maxSinglePartBytes,
    "Thumbnails must be <500 KB single-part"
)
```

**404 → nil pattern** (D-13, D-14) — use existing `DS3S3Client.isNotFoundError(_:)` helper at `DS3S3Client.swift:378-381`:
```swift
// getThumbnailBytes body shape
do {
    // download to temp, read Data, return
} catch {
    if Self.isNotFoundError(error) { return nil }
    throw error
}

// deleteThumbnail body shape
do {
    try await deleteObject(bucket: bucket, key: key)
} catch {
    if Self.isNotFoundError(error) { return }
    throw error
}
```

**ETag normalization** — use existing `ETagUtils.normalize` (see analog `DS3S3Client+Transfers.swift:27`). Return value is the normalized thumbnail ETag per D-09.

---

### `DS3Lib/Sources/DS3Lib/Metadata/SyncedItem.swift` (V3 append)

**Analog:** same file — `SyncedItemSchemaV2` (lines 62-156) + `migrateV1toV2` stage (lines 193-196).

**V3 schema enum pattern** (lines 64-68 in analog — mirror for V3):
```swift
// Source: SyncedItem.swift:64-68 (V2 declaration to mirror)
public enum SyncedItemSchemaV2: VersionedSchema {
    public nonisolated static let versionIdentifier = Schema.Version(2, 0, 0)
    public static var models: [any PersistentModel.Type] {
        [SyncedItem.self, SyncAnchorRecord.self]  // — V3 must list BOTH too
    }
```
**CRITICAL** (Pitfall 3): V3's `models` MUST be `[SyncedItem.self, SyncAnchorRecord.self]`. Dropping `SyncAnchorRecord` deletes all sync anchor rows on migration.

**Swift 6 concurrency requirement** (Pitfall 1 + `MEMORY.md`): MUST use `public nonisolated static let versionIdentifier = Schema.Version(3, 0, 0)` — the `nonisolated` modifier is load-bearing on CI (Xcode 16.2 stricter than local).

**Raw-string + @Transient accessor pattern** (lines 92-98 in analog — VERBATIM shape for new `thumbnailStatus` field):
```swift
// Source: SyncedItem.swift:92-98 (syncStatus + @Transient status)
public var syncStatus: String

@Transient public var status: SyncStatus {
    get { SyncStatus(rawValue: syncStatus) ?? .pending }
    set { syncStatus = newValue.rawValue }
}
```
V3 mirror:
```swift
// Phase 12 addition — placement inside V3's SyncedItem @Model class
public var thumbnailStatus: String = ThumbnailStatus.pending.rawValue

@Transient public var thumbnail: ThumbnailStatus {
    get { ThumbnailStatus(rawValue: thumbnailStatus) ?? .pending }
    set { thumbnailStatus = newValue.rawValue }
}
```

**ThumbnailStatus enum pattern** (lines 159-177 in analog — `SyncStatus` is the 1:1 template):
```swift
// Source: SyncedItem.swift:159-166
public enum SyncStatus: String, Codable, Sendable {
    case pending
    case syncing
    case synced
    // ...
}
```
V3 sibling:
```swift
public enum ThumbnailStatus: String, Codable, Sendable {
    case notApplicable
    case pending
    case uploaded
    case failed
}
```

**Composite uniqueKey preservation** (line 79 in analog — V3 must preserve VERBATIM):
```swift
// DO NOT change — adding thumbnailStatus to uniqueKey would break migration
@Attribute(.unique) public var uniqueKey: String
// init still constructs: self.uniqueKey = "\(driveId.uuidString):\(s3Key)"
```

**Migration plan pattern** (lines 180-197 in analog — VERBATIM shape for V2→V3):
```swift
// Source: SyncedItem.swift:180-197
public enum SyncedItemMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] {
        [SyncedItemSchemaV1.self, SyncedItemSchemaV2.self]  // add V3.self
    }

    public static var stages: [MigrationStage] {
        [migrateV1toV2]  // add migrateV2toV3
    }

    nonisolated static let migrateV1toV2 = MigrationStage.lightweight(
        fromVersion: SyncedItemSchemaV1.self,
        toVersion: SyncedItemSchemaV2.self
    )
}
```
Phase 12 appends `V3.self` to `schemas`, `migrateV2toV3` to `stages`, and:
```swift
nonisolated static let migrateV2toV3 = MigrationStage.lightweight(
    fromVersion: SyncedItemSchemaV2.self,
    toVersion: SyncedItemSchemaV3.self
)
```

**Typealias bump pattern** (line 200 in analog — one-line change):
```swift
// was
public typealias SyncedItem = SyncedItemSchemaV2.SyncedItem
// becomes
public typealias SyncedItem = SyncedItemSchemaV3.SyncedItem
```

---

### `DS3Lib/Sources/DS3Lib/Metadata/MetadataStore.swift` (line 16 modify)

**Analog:** same file — existing `createContainer()` at lines 15-47.

**One-line schema bind** (analog line 16):
```swift
// was
let schema = Schema(versionedSchema: SyncedItemSchemaV2.self)
// becomes
let schema = Schema(versionedSchema: SyncedItemSchemaV3.self)
```

**DO NOT TOUCH** the catch-recovery block (lines 28-46) — it inherits V3 automatically (D-21).

---

### `DS3Lib/Sources/DS3Lib/Metadata/MetadataStore+Queries.swift` (append)

**Analog:** same file — `CachedChildItem` DTO (lines 40-47) + `fetchChildren` (lines 56-83) + `setSyncStatus` (lines 134-142).

**Sendable DTO pattern** (lines 40-47 — VERBATIM shape):
```swift
// Source: MetadataStore+Queries.swift:40-47
struct CachedChildItem: Sendable {
    public let s3Key: String
    public let etag: String?
    public let lastModified: Date?
    public let contentType: String?
    public let size: Int64
    public let syncStatus: String?
}
```
Phase 12 addition:
```swift
public struct PendingThumbnail: Sendable {
    public let s3Key: String
    public let etag: String?
    public let contentType: String?
    public let size: Int64
}
```

**Fetch + Sendable map pattern** (lines 56-83 — adapt for status predicate):
```swift
// Source: MetadataStore+Queries.swift:56-83
func fetchChildren(parentKey: String?, driveId: UUID) throws -> [CachedChildItem] {
    let context = modelExecutor.modelContext
    let trashedStatus = SyncStatus.trashed.rawValue

    if let parentKey {
        let predicate = #Predicate<SyncedItem> {
            $0.driveId == driveId && $0.parentKey == parentKey && $0.syncStatus != trashedStatus
        }
        items = try context.fetch(FetchDescriptor<SyncedItem>(predicate: predicate))
    }
    // ...
    return items.map { CachedChildItem(...) }
}
```
Phase 12 `fetchPendingThumbnails` — same shape, different predicate, PLUS `fetchLimit` (Pitfall 5):
```swift
func fetchPendingThumbnails(driveId: UUID, limit: Int) throws -> [PendingThumbnail] {
    let pendingRaw = ThumbnailStatus.pending.rawValue
    let predicate = #Predicate<SyncedItem> {
        $0.driveId == driveId && $0.thumbnailStatus == pendingRaw
    }
    var descriptor = FetchDescriptor<SyncedItem>(predicate: predicate)
    descriptor.fetchLimit = limit
    let items = try modelExecutor.modelContext.fetch(descriptor)

    // Raster allow-list filter runs in Swift (D-22: predicates don't compose
    // cleanly over dynamic extension list). Limit applied BEFORE filter —
    // caller must NOT infer end-of-queue from result.count < limit.
    let rasterExtensions: Set<String> = ["jpg","jpeg","png","heic","heif","webp","gif","tiff","tif"]
    return items.compactMap { item in
        let ext = (item.s3Key as NSString).pathExtension.lowercased()
        guard rasterExtensions.contains(ext) else { return nil }
        return PendingThumbnail(
            s3Key: item.s3Key, etag: item.etag,
            contentType: item.contentType, size: item.size
        )
    }
}
```

**Status setter pattern** (lines 134-142 in analog — VERBATIM shape, different field):
```swift
// Source: MetadataStore+Queries.swift:134-142
func setSyncStatus(s3Key: String, driveId: UUID, status: SyncStatus) throws {
    if let existing = try findItem(byKey: s3Key, driveId: driveId) {
        existing.syncStatus = status.rawValue
    } else {
        let item = SyncedItem(s3Key: s3Key, driveId: driveId, size: 0, syncStatus: status.rawValue)
        modelExecutor.modelContext.insert(item)
    }
    try modelExecutor.modelContext.save()
}
```
Phase 12 `setThumbnailStatus` — 1:1 mirror, **but SKIP the insert branch** (per D-22 we only update existing rows; coordinator never creates):
```swift
func setThumbnailStatus(s3Key: String, driveId: UUID, status: ThumbnailStatus) throws {
    guard let item = try findItem(byKey: s3Key, driveId: driveId) else { return }
    item.thumbnailStatus = status.rawValue
    try modelExecutor.modelContext.save()
}
```

---

### `DS3Lib/Sources/DS3Lib/SharedData/SharedData+thumbnailSettings.swift` (NEW)

**Analog:** `DS3Lib/Sources/DS3Lib/SharedData/SharedData+trashSettings.swift` — 1:1 mirror (D-23).

**Settings struct pattern** (analog lines 4-15):
```swift
// Source: SharedData+trashSettings.swift:4-15
public struct TrashSettings: Codable, Sendable {
    public var enabled: Bool
    public var retentionDays: Int
    public init(enabled: Bool = true, retentionDays: Int = DefaultSettings.Trash.defaultRetentionDays) {
        self.enabled = enabled
        self.retentionDays = retentionDays
    }
}
```
Phase 12 mirror (drop `retentionDays`; `enabled` defaults to **false** per D-24):
```swift
public struct ThumbnailSettings: Codable, Sendable {
    public var enabled: Bool
    public init(enabled: Bool = false) {
        self.enabled = enabled
    }
}
```

**Load/save pattern** (analog lines 17-43 — VERBATIM shape, rename helpers):
```swift
// Source: SharedData+trashSettings.swift:17-43 — whole pattern
extension SharedData {
    public func loadTrashSettings(forDrive driveId: UUID) throws -> TrashSettings {
        let url = try trashSettingsURL()
        guard let allSettings = try? loadAllTrashSettings(from: url) else {
            return TrashSettings()
        }
        return allSettings[driveId.uuidString] ?? TrashSettings()
    }

    public func saveTrashSettings(forDrive driveId: UUID, settings: TrashSettings) throws {
        let url = try trashSettingsURL()
        var allSettings = (try? loadAllTrashSettings(from: url)) ?? [:]
        allSettings[driveId.uuidString] = settings
        let data = try JSONEncoder().encode(allSettings)
        try coordinatedWrite(data: data, to: url)
    }
}
```

**Helper pattern** (analog lines 71-83):
```swift
// Source: SharedData+trashSettings.swift:71-83
private func trashSettingsURL() throws -> URL {
    try sharedContainerURL().appendingPathComponent(
        DefaultSettings.FileNames.trashSettingsFileName
    )
}

private func loadAllTrashSettings(from url: URL) throws -> [String: TrashSettings] {
    try coordinatedRead(from: url) { data in
        try JSONDecoder().decode([String: TrashSettings].self, from: data)
    }
}
```
Phase 12 mirror uses `DefaultSettings.FileNames.thumbnailSettingsFileName` (new constant per D-27).

**DO NOT mirror** the `hasEmptyTrashRequest` / `setEmptyTrashRequest` methods (lines 48-67) — per D-25 no speculative fields, Phase 13 re-checks collision live via `inspectThumbnailPrefix` (D-26).

---

### `DS3Lib/Sources/DS3Lib/Thumbnails/ThumbnailBackfillCoordinator.swift` (NEW)

**Primary analog (actor shape):** `DS3Lib/Sources/DS3Lib/Metadata/MetadataStore.swift:9-10`
**Secondary analog (temp-file cleanup):** `DS3DriveProvider/FileProviderExtension+Thumbnails.swift:219-224`

**Actor declaration pattern** (analog `MetadataStore.swift:9-10`):
```swift
// Source: MetadataStore.swift:9-10
@ModelActor
public actor MetadataStore {
    // ...
}
```
Phase 12 — plain actor (no `@ModelActor` — coordinator doesn't own a ModelContainer):
```swift
public actor ThumbnailBackfillCoordinator {
    private let metadataStore: MetadataStore
    private let s3Client: DS3S3Client
    private let drive: DS3Drive

    public init(
        metadataStore: MetadataStore,
        s3Client: DS3S3Client,
        drive: DS3Drive
    ) {
        self.metadataStore = metadataStore
        self.s3Client = s3Client
        self.drive = drive
    }
}
```

**BatchResult + runBatch shape** (D-31):
```swift
public struct BatchResult: Sendable {
    public let processed: Int
    public let succeeded: Int
    public let skipped: Int    // .notApplicable transitions
    public let failed: Int     // .failed transitions
}

public func runBatch(maxItems: Int) async throws -> BatchResult
```

**Temp-file cleanup pattern** (analog `FileProviderExtension+Thumbnails.swift:219-224` — Pitfall 9):
```swift
// Source: FileProviderExtension+Thumbnails.swift:219-224
var downloadedFiles: [URL] = []
defer {
    for file in downloadedFiles {
        try? FileManager.default.removeItem(at: file)
    }
}
```
Adopt inside `runBatch` to prevent /tmp accumulation across backfill passes.

**Download pattern** (analog `DS3S3Client+Transfers.swift:17-32` — the existing `getObject(bucket:key:toFile:onProgress:)` — per D-33):
```swift
// Source: DS3S3Client+Transfers.swift:17-32
func getObject(
    bucket: String, key: String, toFile fileURL: URL,
    onProgress: TransferProgressHandler? = nil
) async throws -> S3DownloadResult
```
Coordinator passes `onProgress: nil` (Phase 12 has no tray UI).

**macOS-only render branch** (D-29):
```swift
// Phase 12 coordinator shape — cross-platform shell, macOS-only render
public func runBatch(maxItems: Int) async throws -> BatchResult {
    let pending = try await metadataStore.fetchPendingThumbnails(
        driveId: drive.id, limit: maxItems
    )
    // ... iterate, download, render, upload, mark status ...

    #if os(macOS)
        let renderer = ThumbnailRenderer()  // lazy construct per D-30
        let thumbnailData = renderer.renderJPEG(from: tempURL)
        // ... putThumbnail, setThumbnailStatus(.uploaded) ...
    #else
        // iOS path formally undefined in Phase 12 — no production caller.
        // Phase 14 extends with iOS render path or IPC delegation.
    #endif
}
```

---

### `DS3Lib/Sources/DS3Lib/Constants/DefaultSettings.swift` (insert namespace)

**Analog:** same file — `enum Trash` (lines 208-215), `enum S3` (lines 161-206), `FileNames` struct (lines 131-158).

**Namespace pattern** (analog lines 208-215):
```swift
// Source: DefaultSettings.swift:208-215
public enum Trash {
    public static let defaultRetentionDays = 30
    public static let purgeIntervalSeconds = 3600
}
```
Phase 12 addition (insert AFTER `enum Trash` and BEFORE `enum Update`, i.e. around line 216):
```swift
public enum Thumbnail {
    public static let formatVersion = 1
    public static let sourceETagMetadataKey = "source-etag"       // bare — Soto prepends x-amz-meta-
    public static let formatVersionMetadataKey = "ds3drive-thumb-version"
    public static let maxSinglePartBytes = 500_000
}
```

**FileNames constant pattern** (analog line 154):
```swift
// Source: DefaultSettings.swift:154
public static let trashSettingsFileName = "trashSettings.json"
```
Phase 12 addition to `FileNames`:
```swift
public static let thumbnailSettingsFileName = "thumbnailSettings.json"
```

**DO NOT MOVE** Phase 11's existing constants at lines 195-205 (`trashPrefix`, `thumbnailsPrefix`, `thumbnailMaxDimension`, `thumbnailJPEGQuality`) — they stay on `DefaultSettings.S3` per D-11 and Phase 11 D-17. Moving them churns Phase 11 call sites for zero benefit.

---

### `DS3DriveProvider/FileProviderExtension+Thumbnails.swift:338-346` (MODIFY consumer)

**Analog:** lines 338-346 (current utType.conforms cascade). Replace with:
```swift
// Before (Phase 11):
// if utType.conforms(to: .image) {
//     thumbnailData = FileProviderExtension.generateImageThumbnail(from: fileURL, fitting: size)
// } else if utType.conforms(to: .movie) {
//     thumbnailData = await FileProviderExtension.generateVideoThumbnail(from: fileURL, fitting: size)
// } else if utType.conforms(to: .pdf) {
//     thumbnailData = FileProviderExtension.generatePDFThumbnail(from: fileURL, fitting: size)
// }

// Phase 12:
let renderer = ThumbnailRenderer(
    maxDimension: CGFloat(max(size.width, size.height)),
    jpegQuality: DefaultSettings.S3.thumbnailJPEGQuality
)
thumbnailData = renderer.renderJPEG(from: fileURL)
```

**Import audit after edit** (Pitfall 7):
- REMOVE `import ImageIO` (no direct use left)
- KEEP `import UniformTypeIdentifiers` (still used at line 301 for `UTType(filenameExtension:)`)
- KEEP `import DS3Lib` (now pulls `ThumbnailRenderer`)
- KEEP `@preconcurrency import FileProvider`, `import os.log`

---

### Test file patterns

### `DS3Lib/Tests/DS3LibTests/ThumbnailRendererTests.swift` (NEW — relocated)

**Analog:** `DS3DriveProviderTests/ThumbnailGeneratorTests.swift` (212 lines — verbatim body).

**Fixture-loading swap** (analog lines 37-39):
```swift
// Source: DS3DriveProviderTests/ThumbnailGeneratorTests.swift:37-39
private func fixtureURL(name: String, ext: String) -> URL? {
    Bundle(for: Self.self).url(forResource: name, withExtension: ext)
}
```
Relocated shape (SPM `.process("Fixtures")` at `DS3Lib/Package.swift:30`):
```swift
private func fixtureURL(name: String, ext: String) -> URL? {
    Bundle.module.url(forResource: name, withExtension: ext)
}
```

**Call-site swap**: replace `FileProviderExtension.generateImageThumbnail(from:fitting:)` (analog lines 52-54, 82-84, 113-116) with `ThumbnailRenderer(maxDimension: 256).renderJPEG(from:)` — same assertions, same fixtures.

**Everything else** (the 3 test methods, EXIF-6 fixture synthesizer at lines 143-210) is VERBATIM. File already 100% macOS-only; DS3LibTests runs on macOS only by default, fine.

### `DS3Lib/Tests/DS3LibTests/DS3S3ClientThumbnailsTests.swift` (NEW)

**Analog:** `DS3Lib/Tests/DS3LibTests/InspectThumbnailPrefixTests.swift` (Phase 11 pattern) + `MockDS3S3Client.swift`.

**Mock setup pattern** (analog lines 8-17):
```swift
// Source: InspectThumbnailPrefixTests.swift:8-17
private func makeMock(objects: [S3ObjectSummary] = []) -> MockDS3S3Client {
    let mock = MockDS3S3Client()
    mock.listObjectsResult = S3ListingResult(
        objects: objects, commonPrefixes: [],
        nextContinuationToken: nil, isTruncated: false
    )
    return mock
}
```

**Call-into-mock pattern** (analog line 27):
```swift
let result = try await mock.inspectThumbnailPrefix(bucket: "test", prefix: "drive/")
```
Phase 12 equivalent — protocol-extension method reachable directly on mock:
```swift
let etag = try await mock.putThumbnail(
    bucket: "test", key: "drive/.thumbnails/x.jpg",
    data: smallJPEGData, sourceETag: "\"abc\""
)
```

**MockDS3S3Client extension** — `MockDS3S3Client.swift` needs recording fields added for `putObjectData(metadata:)`:
```swift
// Add to MockDS3S3Client after line ~20
var lastPutObjectDataMetadata: [String: String]?
var lastPutObjectDataKey: String?
```
So tests can assert `mock.lastPutObjectDataMetadata == ["source-etag": "\"abc\"", "ds3drive-thumb-version": "1"]` (Pitfall 2).

**Required assertions per D-35:**
1. PUT issues bare metadata keys (no `x-amz-meta-` prefix double-encoding).
2. `putThumbnail(data: 600_000 bytes)` triggers `precondition` (skip if harness can't catch traps).
3. `getThumbnailBytes` returns `nil` on canned `NoSuchKey` response.
4. `getThumbnailBytes` returns bytes on 200.
5. `getThumbnailBytes` rethrows on 5xx.
6. `deleteThumbnail` succeeds on 204 AND `NoSuchKey` responses.
7. `deleteThumbnail` rethrows on 5xx.

### `DS3Lib/Tests/DS3LibTests/SchemaV3MigrationTests.swift` (NEW)

**Analog:** `DS3Lib/Tests/DS3LibTests/MetadataStoreMigrationTests.swift` (lines 7-42 in-memory container pattern).

**In-memory container setup pattern** (analog lines 8-11):
```swift
// Source: MetadataStoreMigrationTests.swift:8-11
let schema = Schema(versionedSchema: SyncedItemSchemaV2.self)
let config = ModelConfiguration(isStoredInMemoryOnly: true)
let container = try ModelContainer(for: schema, configurations: [config])
let context = ModelContext(container)
```

**Round-trip migration test pattern:**
```swift
// Seed V2 with N rows, close, re-open as V3 with migration plan, assert
let v2Schema = Schema(versionedSchema: SyncedItemSchemaV2.self)
// ... seed rows ...

let v3Schema = Schema(versionedSchema: SyncedItemSchemaV3.self)
let v3Container = try ModelContainer(
    for: v3Schema,
    migrationPlan: SyncedItemMigrationPlan.self,
    configurations: [config]
)
// Assert rows present, thumbnailStatus == "pending" on all
// Assert SyncAnchorRecord rows survived (Pitfall 3 regression)
```

### `DS3Lib/Tests/DS3LibTests/ThumbnailBackfillCoordinatorTests.swift` (NEW — scaffold)

**Analog:** `InspectThumbnailPrefixTests.swift` mock-driven style.

**Smoke test pattern** (D-39):
```swift
// Construct coordinator with mock MetadataStore (empty) + MockDS3S3Client.
// Call runBatch(maxItems: 1).
// Assert BatchResult(processed: 0, succeeded: 0, skipped: 0, failed: 0).
```
**Do NOT over-test a scaffold** — Phase 13 adds end-to-end tests when a real caller wires in.

---

## Shared Patterns

### Protocol-default extension for mockable S3 methods (CRITICAL — applies to `DS3S3Client+Thumbnails.swift`)

**Source:** `DS3Lib/Sources/DS3Lib/DS3S3Client+ThumbnailPrefix.swift:20`
**Apply to:** All new S3 methods on `DS3S3ClientProtocol` extension (NOT on `DS3S3Client` directly)
```swift
public extension DS3S3ClientProtocol {
    func putThumbnail(...) async throws -> String { /* calls self.putObjectData, etc. */ }
    func getThumbnailBytes(...) async throws -> Data? { ... }
    func deleteThumbnail(...) async throws { ... }
}
```
Ensures `MockDS3S3Client` gets the methods for free via protocol dispatch. Confirmed by `InspectThumbnailPrefixTests.swift:27`.

### Swift 6 `nonisolated static let` for `Schema.Version` (applies to V3)

**Source:** `SyncedItem.swift:7` + `:65` + `MEMORY.md` Swift 6 Concurrency notes
**Apply to:** `SyncedItemSchemaV3.versionIdentifier`
```swift
public nonisolated static let versionIdentifier = Schema.Version(3, 0, 0)
```
Missing `nonisolated` causes CI (Xcode 16.2) to fail with "Non-sendable type 'Schema.Version' passed..." — local Xcode may not catch it.

### `os_proc_available_memory()` + autoreleasepool (applies to `ThumbnailRenderer`)

**Source:** `FileProviderExtension+ThumbnailGenerators.swift:30-39, 42-74`
**Apply to:** `ThumbnailRenderer.renderJPEG(from:)` body — copy VERBATIM per D-04.
Required by THUMB-08 (EXIF) and iOS jetsam resistance (even though type is macOS-only).

### Soto `metadata` parameter — bare keys only (applies to `putThumbnail`)

**Source:** `soto/Sources/Soto/Services/S3/S3_shapes.swift:1597` (VERIFIED), Pitfall 2
**Apply to:** All calls passing `metadata:` to `S3.PutObjectRequest`
```swift
// CORRECT
metadata: ["source-etag": sourceETag, "ds3drive-thumb-version": "1"]
// WRONG — double-encodes to "x-amz-meta-x-amz-meta-source-etag"
metadata: ["x-amz-meta-source-etag": sourceETag]
```
Use `DefaultSettings.Thumbnail.sourceETagMetadataKey` and `.formatVersionMetadataKey` constants.

### Sendable DTO + @Model read inside actor (applies to `PendingThumbnail`)

**Source:** `MetadataStore+Queries.swift:40-47, 56-83`
**Apply to:** `PendingThumbnail` + `fetchPendingThumbnails`
Never let `@Model` objects escape the `@ModelActor` boundary. Materialize into Sendable struct inside the actor method body, return the array across the boundary.

### `isNotFoundError(_:)` helper for 404 detection (applies to `getThumbnailBytes`, `deleteThumbnail`)

**Source:** `DS3Lib/Sources/DS3Lib/DS3S3Client.swift:378-381`
**Apply to:** 404 → `nil` / silent-success paths
Do NOT string-match `NoSuchKey`; use the official helper per Don't-Hand-Roll table in RESEARCH.md.

### Temp file cleanup with `defer` (applies to `ThumbnailBackfillCoordinator.runBatch`)

**Source:** `FileProviderExtension+Thumbnails.swift:219-224`
**Apply to:** Coordinator's download → render → upload loop
```swift
var downloadedFiles: [URL] = []
defer {
    for file in downloadedFiles {
        try? FileManager.default.removeItem(at: file)
    }
}
```
Prevents /tmp accumulation across many backfill passes (Pitfall 9).

### OSLog `privacy: .public` on dynamic strings (applies to any logging added in Phase 12)

**Source:** CLAUDE.md + `MEMORY.md` File Provider Error Handling
**Apply to:** Any `logger.info/error/warning` call with dynamic values (bucket, key, ETag, error description)

### File Provider error boundary (applies — Phase 12 stays BELOW it)

**Source:** CLAUDE.md + `MEMORY.md`
**Apply to:** All new DS3Lib code (Phase 12) — throw raw Soto / Swift errors. Phase 13 consumers wrap at the boundary.
**Anti-pattern to avoid:** domain-remapping DS3Lib errors into `NSFileProviderErrorDomain` inside DS3Lib. That happens in Phase 13's `fetchThumbnails` rewrite.

### `Bundle.module` for test fixtures in DS3LibTests (applies to `ThumbnailRendererTests`)

**Source:** `DS3Lib/Package.swift:30` — `resources: [.process("Fixtures")]`
**Apply to:** Relocated `ThumbnailRendererTests` fixture loading
```swift
Bundle.module.url(forResource: name, withExtension: ext)  // SPM testTarget
// NOT Bundle(for: Self.self) (Xcode-target pattern used in DS3DriveProviderTests)
```

## No Analog Found

All 18 new/modified files have strong analogs. **Zero files require pattern-less invention.** Phase 12's character is "mechanical extraction + 1:1 mirror + additive append."

## Metadata

**Analog search scope:**
- `DS3DriveProvider/` (extension source files — source of extraction)
- `DS3Lib/Sources/DS3Lib/` (renderer/coordinator/S3/SharedData/Metadata homes)
- `DS3Lib/Tests/DS3LibTests/` (test precedents and MockDS3S3Client)
- `DS3DriveProviderTests/ThumbnailGeneratorTests.swift` (test body to relocate)
- `.planning/phases/11-foundation-filtering/` (Phase 11 decisions referenced)

**Files scanned:** 13 (all directly inspected during pattern extraction)

**Pattern extraction date:** 2026-04-24

**Pattern-to-action summary for planner:**
- 10 NEW files — each has a file-path + line-range analog to copy from
- 5 MODIFY files — same-file precedents exist in 4/5 cases (`SyncedItem.swift`, `MetadataStore.swift`, `MetadataStore+Queries.swift`, `DefaultSettings.swift`), consumer rewrite in 1 (`FileProviderExtension+Thumbnails.swift`)
- 2 DELETE files — `FileProviderExtension+ThumbnailGenerators.swift` (contents moved), `DS3DriveProviderTests/ThumbnailGeneratorTests.swift` (test moved)
- 1 pbxproj edit — 4 PBXBuildFile + 4 PBXFileReference + 1 Sources target-membership removal (9 entries)
