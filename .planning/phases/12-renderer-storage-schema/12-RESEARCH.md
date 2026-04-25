# Phase 12: Renderer, Storage & Schema - Research

**Researched:** 2026-04-24
**Domain:** DS3Lib renderer extraction, Soto v6 thumbnail PUT/GET/DELETE, SwiftData V2→V3 lightweight migration, App-Group settings, cross-platform coordinator scaffold
**Confidence:** HIGH (every claim below is grounded in a specific file:line read during this session; one `[VERIFIED: Soto v6 S3_shapes.swift]` citation for the `x-amz-meta-` prefix behavior)

## Summary

Phase 12 is a **mechanical extraction and 1:1 mirror exercise**, not a design exercise. Phase 11 (PR #134, merged fc875ce) already shipped every hard piece: the hardened generator, the S3PathUtils thumbnail helpers, `S3KeyFilter.isUserVisible`, Git LFS fixtures, `DS3S3Client+ThumbnailPrefix.swift`, and the `inspectThumbnailPrefix` protocol extension pattern. Phase 12 lifts artifacts into new DS3Lib homes, adds three S3 methods behind the same protocol seam, bumps SwiftData from V2 to V3 with one defaulted string field, mirrors `SharedData+trashSettings.swift` 1:1, and scaffolds a dormant actor.

Five concrete, load-bearing findings grounded in file inspection during this session:

1. **Soto v6 metadata encoding is VERIFIED.** `S3.PutObjectRequest.metadata: [String: String]?` is declared at `soto/Sources/Soto/Services/S3/S3_shapes.swift:1600` (DerivedData checkout) with encoding `AWSMemberEncoding(label: "metadata", location: .headerPrefix("x-amz-meta-"))` at the same struct's `_encoding` table. **Soto prepends `x-amz-meta-` automatically** — callers pass bare keys (`"source-etag"`, `"ds3drive-thumb-version"`). CONTEXT D-11's claim is correct. The existing `copyObject` call site at `DS3Lib/Sources/DS3Lib/DS3S3Client.swift:326-340` already uses this pattern: `metadata: [String: String]?` + `metadataDirective: .replace`.

2. **Phase 11 generator is VERBATIM-ready for extraction.** `DS3DriveProvider/FileProviderExtension+ThumbnailGenerators.swift:29-75` contains the full hardened `generateImageThumbnail` with all four ImageIO flags, the `autoreleasepool`, the UTI allow-list, and the memory guard (the memory guard is iOS-only gated via `#if canImport(UIKit)` at lines 30-39 — the macOS path relies on 64MB headroom being essentially always available). Phase 12's `ThumbnailRenderer.renderJPEG` copies lines 29-75 verbatim, only: (a) renames to the instance method, (b) reads config from `self.maxDimension` / `self.jpegQuality` instead of static constants / parameters, and (c) wraps the entire type in `#if os(macOS) … #endif`. `jpegData(from:)` at lines 138-155 moves to a `private func` on the struct. `generateVideoThumbnail` (lines 78-97) and `generatePDFThumbnail` (lines 100-135) are deleted per D-05.

3. **`FileProviderExtension+Thumbnails.swift` is 521 lines — NOT at the SwiftLint error limit.** `.swiftlint.yml` config referenced in Phase 11 research sets `file_length` warning at 600, error at 1000. Phase 12's call-site rewrite at lines 338-346 (the `utType.conforms` cascade) shrinks to a single `ThumbnailRenderer(…).renderJPEG(from: fileURL)` invocation, dropping the video and PDF branches entirely. Net: the file gets SHORTER, not longer. **Only ONE call site** in the repo invokes the old generator statics — at lines 338-346 (verified via grep: no other references to `generateImageThumbnail`, `generateVideoThumbnail`, or `generatePDFThumbnail` anywhere else in the codebase except the test file at `DS3DriveProviderTests/ThumbnailGeneratorTests.swift`).

4. **The `inspectThumbnailPrefix` precedent at `DS3Lib/Sources/DS3Lib/DS3S3Client+ThumbnailPrefix.swift:20` is the EXACT pattern Phase 12 must replicate.** That file declares its method on `public extension DS3S3ClientProtocol` (not on the concrete `DS3S3Client`), which means `MockDS3S3Client: DS3S3ClientProtocol` gets the method for free via protocol-default dispatch — see `InspectThumbnailPrefixTests.swift:27` which calls `mock.inspectThumbnailPrefix(bucket:prefix:)` without any boilerplate. **Phase 12's new `putThumbnail` / `getThumbnailBytes` / `deleteThumbnail` go on `public extension DS3S3ClientProtocol`**, NOT on `DS3S3Client` directly, so mocked tests reuse the existing `MockDS3S3Client` with zero new conformance work.

5. **Fixtures are ALREADY in DS3LibTests/Fixtures/ — the test relocation is mostly done.** Git LFS fixtures `exif6-portrait.heic`, `exif6-portrait.jpg`, `large-test.png`, `unsupported.pdf` live at `DS3Lib/Tests/DS3LibTests/Fixtures/` and `DS3Lib/Package.swift:30` already declares `resources: [.process("Fixtures")]` on the testTarget. The Xcode `DS3DriveProviderTests` target **references them via relative path** (pbxproj file ref: `path = "../DS3Lib/Tests/DS3LibTests/Fixtures/exif6-portrait.heic"`). Phase 12's test relocation is: (a) delete the 4 PBXBuildFile + PBXFileReference entries for fixtures from DS3DriveProviderTests target, (b) delete `DS3DriveProviderTests/ThumbnailGeneratorTests.swift`, (c) create `DS3Lib/Tests/DS3LibTests/ThumbnailRendererTests.swift` loading fixtures via `Bundle.module.url(forResource:withExtension:)` instead of `Bundle(for: Self.self)`.

**Primary recommendation:** Phase 12 plans should model this as five parallel tracks: (1) `ThumbnailRenderer` extraction + test relocation, (2) `DS3S3Client+Thumbnails.swift` + tests, (3) Schema V3 + migration test + `MetadataStore+Queries` additions, (4) `SharedData+thumbnailSettings.swift` + tests (D-23 / D-38), (5) `ThumbnailBackfillCoordinator` scaffold + smoke test. These have no runtime coupling to each other (the coordinator depends on the other four by type, but Phase 12 never invokes it from production) — they can execute as independent waves. The only sequencing constraint: the coordinator's smoke test imports `ThumbnailRenderer`, `ThumbnailStatus`, and the S3 methods, so its wave must land last.

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

**Renderer (THUMB-07, THUMB-08, THUMB-09)**

- **D-01:** `ThumbnailRenderer` is a **struct with an initializer**, not an enum-of-statics. Signature: `public struct ThumbnailRenderer { public init(maxDimension: CGFloat = CGFloat(DefaultSettings.S3.thumbnailMaxDimension), jpegQuality: Float = DefaultSettings.S3.thumbnailJPEGQuality); public func renderJPEG(from fileURL: URL) -> Data? }`. Instance state is the two config knobs; allows future injection (e.g., a smaller quality for overnight iOS backfill) without breaking the API. Renderer has no state that needs an actor — the decode path is pure.
- **D-02:** File location: `DS3Lib/Sources/DS3Lib/Thumbnails/ThumbnailRenderer.swift`. Opens a new `Thumbnails/` directory under DS3Lib that Phase 12 also uses for `ThumbnailBackfillCoordinator.swift`. The S3 service stays as a `DS3S3Client+Thumbnails.swift` extension file at the root of DS3Lib sources — consistent with `+Presign.swift`, `+Transfers.swift`, `+ThumbnailPrefix.swift`.
- **D-03:** **`#if os(macOS)` wraps the entire type declaration** (not just method bodies). On iOS targets, `ThumbnailRenderer` literally does not exist — `import DS3Lib` + `ThumbnailRenderer()` is a compile error, which is exactly what THUMB-07 / phase success-criterion #2 demands. This is load-bearing — a runtime guard or no-op stub does NOT satisfy the criterion.
- **D-04:** The renderer is a **mechanical extraction** of the Phase 11-hardened static functions in `DS3DriveProvider/FileProviderExtension+ThumbnailGenerators.swift`. All four ImageIO flags (`kCGImageSourceShouldCache: false`, `kCGImageSourceCreateThumbnailFromImageAlways: true`, `kCGImageSourceCreateThumbnailWithTransform: true`, `kCGImageSourceShouldCacheImmediately: true`), the `autoreleasepool`, the `CGImageSourceGetType` allow-list check, and the `os_proc_available_memory()` guard move verbatim. Phase 12 does NOT rewrite any of this logic.
- **D-05:** **`generateVideoThumbnail` and `generatePDFThumbnail` are deleted entirely**, not moved. v3.1 scope is raster-only per THUMB-09 and REQUIREMENTS Out of Scope. Leaving them behind as dead-but-public API in DS3Lib invites misuse.
- **D-06:** **`FileProviderExtension+ThumbnailGenerators.swift` is deleted** once extraction completes. Its only caller (`FileProviderExtension+Thumbnails.swift:338-346`'s `fetchThumbnails` fallback) is rewritten in this phase to call `ThumbnailRenderer` directly via an instance. No shim, no deprecation file, no re-export.
- **D-07:** **`ThumbnailGeneratorTests.swift` moves from `DS3DriveProviderTests/` to `DS3LibTests/`**. Fixtures already in Git LFS move with them. Tests become `ThumbnailRendererTests`. The macOS-only XCTest pattern stays.

**S3 Service (THUMB-10)**

- **D-08:** **Methods live on `DS3S3Client`** as a new extension file `DS3Lib/Sources/DS3Lib/DS3S3Client+Thumbnails.swift`. Mirrors the existing extension pattern (`+Presign.swift`, `+Transfers.swift`, `+ThumbnailPrefix.swift`). The implementation goes on `DS3S3ClientProtocol` extension (per Phase 11 `inspectThumbnailPrefix` precedent) so mocked tests inherit the method automatically.
- **D-09:** **API surface (exact signatures):**
  ```swift
  public func putThumbnail(bucket: String, key: String, data: Data, sourceETag: String) async throws -> String
  public func getThumbnailBytes(bucket: String, key: String) async throws -> Data?
  public func deleteThumbnail(bucket: String, key: String) async throws
  ```
  `sourceETag` is a **required non-optional parameter** on `putThumbnail`.
- **D-10:** **Both metadata headers always present on PUT:**
  - `x-amz-meta-source-etag: <sourceETag>` — for Phase 13's stale-thumbnail detection
  - `x-amz-meta-ds3drive-thumb-version: 1` — for future format migrations
- **D-11:** **Open a `DefaultSettings.Thumbnail` namespace** with `formatVersion = 1`, `sourceETagMetadataKey = "source-etag"`, `formatVersionMetadataKey = "ds3drive-thumb-version"`, `maxSinglePartBytes = 500_000`. Phase 11's size/quality/prefix constants stay where they are on `DefaultSettings.S3`.
- **D-12:** **Single-part PUT enforcement** via `precondition(data.count < DefaultSettings.Thumbnail.maxSinglePartBytes)` at the top of `putThumbnail`. Uses Soto's single-shot `S3.putObject(PutObjectRequest)` directly — NOT multipart.
- **D-13:** **`getThumbnailBytes` returns `Data?`** with nil = 404. Network / auth / 5xx errors throw through.
- **D-14:** **`deleteThumbnail` is silent on 404.** Network / auth errors still throw.
- **D-15:** A `HEAD` method is **NOT** added in Phase 12.

**Schema V3 + MetadataStore (THUMB-04)**

- **D-16:** New `SyncedItemSchemaV3` in `DS3Lib/Sources/DS3Lib/Metadata/SyncedItem.swift`, mirroring the existing V1 / V2 definitions. One new stored `thumbnailStatus: String` field defaulting to `"pending"`, plus `@Transient` accessor `thumbnail: ThumbnailStatus`.
- **D-17:** `public enum ThumbnailStatus: String, Codable, Sendable` with four cases: `.notApplicable` / `.pending` / `.uploaded` / `.failed`.
- **D-18:** **Lightweight V2→V3 migration** appended to `SyncedItemMigrationPlan.stages`. Existing rows get `.pending` on the new field.
- **D-19:** **Fresh rows default to `.pending`**; classification happens at query time, not upsert time.
- **D-20:** `typealias SyncedItem = SyncedItemSchemaV3.SyncedItem` replaces the V2 alias. `MetadataStore.createContainer()` updates from `SyncedItemSchemaV2.self` to `V3.self`.
- **D-21:** **Migration-failed fallback stays** — existing catch block in `createContainer` inherits V3 automatically.
- **D-22:** **New query surface:** `PendingThumbnail: Sendable` DTO + `fetchPendingThumbnails(driveId:limit:)` + `setThumbnailStatus(s3Key:driveId:status:)`. Predicate: `driveId == X AND thumbnailStatus == "pending"`. Raster allow-list filter applied in Swift after the fetch. `countPending` NOT added in Phase 12.

**SharedData + Settings**

- **D-23:** **`SharedData+thumbnailSettings.swift` is a 1:1 mirror of `SharedData+trashSettings.swift`.** Per-drive JSON in App Group. `ThumbnailSettings { enabled: Bool }`.
- **D-24:** **Default `enabled = false`** for all drives, including existing drives upgrading to V3.
- **D-25:** **No speculative fields** in `ThumbnailSettings`.
- **D-26:** **Phase 11's "Use anyway" collision choice is NOT persisted.** Phase 13 re-checks on feature-enable.
- **D-27:** Add `thumbnailSettingsFileName` constant to `DefaultSettings.FileNames`.

**Backfill Coordinator Scaffold**

- **D-28:** **`public actor ThumbnailBackfillCoordinator`** at `DS3Lib/Sources/DS3Lib/Thumbnails/ThumbnailBackfillCoordinator.swift`.
- **D-29:** **Cross-platform shell, macOS-only render.** Type compiles on iOS + macOS; only the render branch is `#if os(macOS)`.
- **D-30:** **Construction signature:** `public init(metadataStore: MetadataStore, s3Client: DS3S3Client, drive: DS3Drive)`. Renderer lazily constructed inside `runBatch` with DefaultSettings knobs.
- **D-31:** **Batch entry point:** `runBatch(maxItems: Int) async throws -> BatchResult` with `BatchResult { processed, succeeded, skipped, failed }`.
- **D-32:** **Render-fail policy:** render nil → UTI check → unsupported → `.notApplicable`, supported-but-failed → `.failed`.
- **D-33:** Coordinator downloads originals via existing `DS3S3Client.getObject(bucket:key:toFile:onProgress:)`, renders, uploads thumbnail, deletes temp.

**Test Strategy**

- **D-34:** **`ThumbnailRendererTests`** in `DS3LibTests`, moved from `DS3DriveProviderTests`. Fixtures move with them.
- **D-35:** **`DS3S3Client+ThumbnailsTests`** — mocked via `DS3S3Client+Protocol` seam. Assertions: headers on PUT, nil on 404 GET, silent success on 404 DELETE, rethrow on 5xx.
- **D-36:** **`SchemaV3MigrationTests`** — seed V2 store with N rows, re-open with V3, assert `thumbnailStatus == "pending"` on all rows.
- **D-37:** **`MetadataStore+ThumbnailQueriesTests`** — `fetchPendingThumbnails` returns only `.pending` rows, respects driveId + limit. `setThumbnailStatus` transitions correctly.
- **D-38:** **`SharedData+thumbnailSettingsTests`** — round-trip `enabled: true` / `false`, default-on-missing-file, coordinated-write safety.
- **D-39:** **`ThumbnailBackfillCoordinatorTests`** — scaffold test only: construct with mocks, call `runBatch(maxItems: 1)`, assert `BatchResult(processed: 0, ...)` when no pending items.

### Claude's Discretion

- Exact file layout under `DS3Lib/Sources/DS3Lib/Thumbnails/` (single file per type vs `ThumbnailRenderer.swift` + `ThumbnailRenderer+Internal.swift` split).
- Whether `ThumbnailStatus` lives in `SyncedItem.swift` next to `SyncStatus` or in a new `ThumbnailStatus.swift` sibling file.
- Minor internal naming (e.g., `BatchResult.succeeded` vs `.uploaded`).
- Whether `ThumbnailBackfillCoordinator.runBatch` uses a `TaskGroup` for parallel renders in Phase 12's scaffold or stays sequential (recommend sequential).
- Whether to temporarily keep an internal `typealias ThumbnailGenerator = ThumbnailRenderer` for grep-discoverability (probably no).

### Deferred Ideas (OUT OF SCOPE)

- Cache-first `fetchThumbnails` rewrite → Phase 13.
- Upload-path hook (`UploadThumbnailHook`) → Phase 13.
- Cascade hooks (delete/rename/move) → Phase 13.
- Orphan sweep → Phase 13 (may add `headThumbnail` then).
- BFS backfill invocation → Phase 13.
- `ThumbnailFetchLimiter` → Phase 13.
- Negative cache / 3-strike rule (THUMB-20) → Phase 13.
- Tray progress UI (THUMB-24) → Phase 13 (may add `countPending` then).
- iOS `BGProcessingTask` + `ForegroundBackfillDriver` → Phase 14.
- Cellular gating + "Generate now" action → Phase 14.
- iOS settings progress UI → Phase 14.
- Parallel renders inside `runBatch` → Phase 13/14.
- EXIF thumbnail fast path → deferred beyond v3.1.
- PNG fallback for line-art/screenshots → deferred beyond v3.1.
- Video / PDF / RAW thumbnail support → out of scope per REQUIREMENTS.
- WebP / AVIF thumbnail format → deferred beyond v3.1.
- `headThumbnail` → add in Phase 13 if orphan-sweep needs it.
- `countPending` → add in Phase 13 alongside tray progress.
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| THUMB-04 | `SyncedItem` tracks per-item thumbnail status via Schema V3 migration | V1→V2 precedent at `DS3Lib/Sources/DS3Lib/Metadata/SyncedItem.swift:179-197`. SwiftData `MigrationStage.lightweight(fromVersion:toVersion:)` is the exact API. V2 already uses the `@Transient` computed accessor pattern (`syncStatus` → `status`) at lines 94-97, which V3's `thumbnailStatus` → `thumbnail` accessor mirrors 1:1. |
| THUMB-07 | iOS File Provider extension is strictly consume-only; enforced with `#if os(macOS)` gate on the renderer type | Pattern already in use in Phase 11: `FileProviderExtension+Thumbnails.swift:165-174` short-circuits on iOS. `#if os(macOS)` on the entire type declaration is unambiguous and the only way to satisfy phase success criterion #2 at compile time. |
| THUMB-08 | EXIF orientation correctness | Phase 11's `FileProviderExtension+ThumbnailGenerators.swift:64` already passes `kCGImageSourceCreateThumbnailWithTransform: true`. Verbatim copy preserves the flag. Existing regression test at `DS3DriveProviderTests/ThumbnailGeneratorTests.swift:108-136` proves EXIF-6 portrait output. |
| THUMB-09 | Raster format allow-list; unsupported silently skipped | Phase 11's allow-list at lines 13-21 and check at lines 56-58 is the canonical implementation. Verbatim move. Regression test at `ThumbnailGeneratorTests.swift:46-60` (PDF → nil) proves the allow-list. |
| THUMB-10 | Thumbnail PUT always single-part + two metadata headers | Soto v6 `S3.PutObjectRequest.metadata: [String: String]?` VERIFIED at `soto/Sources/Soto/Services/S3/S3_shapes.swift:1600` + `_encoding` table entry `AWSMemberEncoding(label: "metadata", location: .headerPrefix("x-amz-meta-"))` — Soto prepends `x-amz-meta-` automatically; callers pass `["source-etag": sourceETag, "ds3drive-thumb-version": "1"]`. Single-part enforcement via `precondition` on `data.count`. |
</phase_requirements>

## Project Constraints (from CLAUDE.md)

Extracted directives the planner MUST honor:

- **Commit messages:** Never mention Claude Code, AI tools, or Co-Authored-By AI. Keep messages concise. GPG signing is enabled by default — do NOT pass `-c commit.gpgsign=false`.
- **File Provider errors:** Any error crossing the File Provider boundary MUST be in `NSFileProviderErrorDomain` or `NSCocoaErrorDomain`. **Phase 12 ships DS3Lib code, which is BELOW the File Provider boundary** — DS3Lib errors (Soto `AWSErrorType`, `DS3ClientError`, raw Swift errors) are correct at this layer. Phase 13 consumers wrap at the boundary. **Do not do domain remapping in Phase 12.**
- **OSLog privacy:** Use `privacy: .public` on dynamic strings (existing codebase convention).
- **App Group:** `group.X889956QSM.io.cubbit.DS3Drive` — unchanged in Phase 12.
- **Swift 6 strict concurrency** enabled on DS3Lib (`DS3Lib/Package.swift:21`). `Schema.Version` is NOT `Sendable` (per `MEMORY.md`); V3's `versionIdentifier` **must** use `public nonisolated static let versionIdentifier = Schema.Version(3, 0, 0)` — same shape as V1/V2 at `SyncedItem.swift:7` and `:65`. CI uses Xcode 16.2 which is stricter than local — Phase 12 concurrency changes must pass `swift test --package-path DS3Lib` without warnings.
- **Git LFS:** `exif6-portrait.heic`, `exif6-portrait.jpg`, `large-test.png`, `unsupported.pdf` are already LFS-tracked and live at `DS3Lib/Tests/DS3LibTests/Fixtures/`. No new fixtures needed in Phase 12.
- **macOS 14+ / iOS 17+** — all Phase 12 APIs available on both minima.
- **Build command:** `swift test --package-path DS3Lib` for DS3Lib tests; `xcodebuild -project DS3Drive.xcodeproj -scheme DS3Drive test -destination 'platform=macOS'` for extension tests. Per Phase 11 validation, `DS3DriveProviderTests/ThumbnailGeneratorTests.swift` is reachable via the `DS3Drive` scheme's test action.

## Standard Stack

Phase 12 adds **zero new dependencies**. All work uses already-linked DS3Lib + Apple system frameworks. Every library below is present today; versions VERIFIED against `DS3Lib/Package.swift:8-11`.

### Core

| Library / Framework | Version | Purpose | Where it lives |
|---------------------|---------|---------|----------------|
| Soto `SotoS3` | 6.8.0+ (`DS3Lib/Package.swift:9`) | S3 `PutObjectRequest.metadata: [String: String]?` — Soto strips `x-amz-meta-` prefix automatically [VERIFIED: `soto/Sources/Soto/Services/S3/S3_shapes.swift:1597,1600`] | DS3Lib |
| swift-atomics | 1.2.0+ (`DS3Lib/Package.swift:10`) | Thread-safe state (existing) | DS3Lib |
| swift-nio | 2.62.0+ (`DS3Lib/Package.swift:11`) | Soto transport | DS3Lib |
| SwiftData (system) | iOS 17 / macOS 14 | `@Model`, `VersionedSchema`, `MigrationStage.lightweight`, `Schema(versionedSchema:)`, `ModelContainer(for:migrationPlan:configurations:)` — exact APIs used by V1→V2 at `SyncedItem.swift:179-197` | DS3Lib (`@ModelActor` + `@Model`) |
| `ImageIO` (system) | macOS 14 / iOS 17 | Raster decode (macOS only — `#if os(macOS)` gate) | DS3Lib `Thumbnails/` (new) |
| `UniformTypeIdentifiers` (system) | macOS 14 / iOS 17 | `CGImageSourceGetType` UTI comparison | DS3Lib `Thumbnails/` (new) |
| `os` / `os.log` (system) | Always | `os_proc_available_memory()` memory guard | DS3Lib `Thumbnails/` |
| XCTest (system) | Always | Unit + migration tests | `DS3LibTests` target |

**Version verification:** `swift-tools-version: 6.0` at `DS3Lib/Package.swift:1` with `.swiftLanguageMode(.v6)` at `:21`. No version bump needed in Phase 12.

### Alternatives Considered

None. CONTEXT has 39 locked decisions; Phase 12 is execution, not re-design. Alternatives (multipart thumbnails, PDFKit video paths, DB-migration-time classification, per-drive renderer instances) were rejected during the discuss-phase.

## Architecture Patterns

### System Architecture Diagram

```
                        Phase 12 payload (silent — no caller invokes coordinator)
                        ══════════════════════════════════════════════════════════

   DS3Lib Sources                                                      Coordinator scaffolded
  ┌────────────────────────────────────────────────────────┐           (no production caller)
  │                                                        │                    ▲
  │  Constants/DefaultSettings.swift                       │                    │
  │    + enum Thumbnail { formatVersion,                   │                    │
  │                       sourceETagMetadataKey,           │                    │
  │                       formatVersionMetadataKey,        │                    │
  │                       maxSinglePartBytes }             │                    │
  │    + FileNames.thumbnailSettingsFileName               │                    │
  │                                                        │                    │
  │  Thumbnails/                               NEW DIR     │                    │
  │    ├── ThumbnailRenderer.swift  #if os(macOS)          │                    │
  │    │     struct with init; renderJPEG(from:)           │ ─ lazy constructed ┤
  │    └── ThumbnailBackfillCoordinator.swift  actor       │ ◀──────────────────┘
  │          init(metadataStore:s3Client:drive:)           │
  │          runBatch(maxItems:) → BatchResult             │ ─ uses ────┐
  │                                                        │            │
  │  DS3S3Client+Thumbnails.swift        NEW FILE          │            │
  │    (public extension DS3S3ClientProtocol)              │            │
  │    + putThumbnail(bucket:key:data:sourceETag:) → ETag  │ ◀──────────┤
  │    + getThumbnailBytes(bucket:key:) → Data?  (nil=404) │ ◀──────────┤
  │    + deleteThumbnail(bucket:key:)  (silent on 404)     │ ◀──────────┤
  │                                                        │            │
  │  Metadata/SyncedItem.swift                             │            │
  │    + enum SyncedItemSchemaV3: VersionedSchema          │            │
  │         @Model SyncedItem { thumbnailStatus: String }  │            │
  │         @Transient thumbnail: ThumbnailStatus          │            │
  │    + enum ThumbnailStatus { .notApplicable/pending/    │            │
  │                             .uploaded/.failed }        │            │
  │    + migrateV2toV3 (lightweight)                       │            │
  │    + typealias SyncedItem = V3.SyncedItem              │            │
  │                                                        │            │
  │  Metadata/MetadataStore.swift                          │            │
  │    Schema(versionedSchema: V2) → V3                    │            │
  │                                                        │            │
  │  Metadata/MetadataStore+Queries.swift                  │            │
  │    + struct PendingThumbnail: Sendable                 │            │
  │    + fetchPendingThumbnails(driveId:limit:)            │ ◀──────────┤
  │    + setThumbnailStatus(s3Key:driveId:status:)         │ ◀──────────┤
  │                                                        │            │
  │  SharedData/SharedData+thumbnailSettings.swift  NEW    │            │
  │    + struct ThumbnailSettings { enabled: Bool = false }│            │
  │    + loadThumbnailSettings(forDrive:)                  │            │
  │    + saveThumbnailSettings(forDrive:settings:)         │            │
  │                                                        │            │
  └────────────────────────────────────────────────────────┘            │
                                                                         │
   DS3DriveProvider                                                      │
  ┌────────────────────────────────────────────────────────┐            │
  │                                                        │            │
  │  FileProviderExtension+Thumbnails.swift                │            │
  │    fetchThumbnails (lines 157-249) consumer            │            │
  │    downloadThumbnailImage (lines 267-366)              │            │
  │       lines 338-346: was utType.conforms cascade       │            │
  │       ────────→ becomes single ThumbnailRenderer call  │            │
  │                                                        │            │
  │  FileProviderExtension+ThumbnailGenerators.swift       │            │
  │    ────────────→ DELETED entirely                      │            │
  │                                                        │            │
  └────────────────────────────────────────────────────────┘            │
                                                                         │
   Tests                                                                 │
  ┌────────────────────────────────────────────────────────┐            │
  │  DS3LibTests/                                          │            │
  │    + ThumbnailRendererTests.swift  (moved from         │ ◀──────────┤
  │        DS3DriveProviderTests; fixtures stay put)       │            │
  │    + DS3S3Client+ThumbnailsTests.swift  (new)          │ ◀──────────┤
  │    + SchemaV3MigrationTests.swift  (new)               │            │
  │    + MetadataStore+ThumbnailQueriesTests.swift (new)   │            │
  │    + SharedData+thumbnailSettingsTests.swift (new)     │            │
  │    + ThumbnailBackfillCoordinatorTests.swift (new)     │ ◀──────────┘
  │                                                        │
  │  DS3DriveProviderTests/                                │
  │    ThumbnailGeneratorTests.swift  ──→ DELETED          │
  │    Fixture PBXFileReferences      ──→ REMOVED from     │
  │                                       pbxproj          │
  └────────────────────────────────────────────────────────┘
```

### Component Responsibilities

| Component | File | Responsibility | Phase 12 Action |
|-----------|------|----------------|-----------------|
| Renderer (extracted) | `DS3Lib/Sources/DS3Lib/Thumbnails/ThumbnailRenderer.swift` | Decode image → 512-px JPEG Data | **CREATE** (mechanical extraction from Phase 11's generator) |
| S3 thumbnail service | `DS3Lib/Sources/DS3Lib/DS3S3Client+Thumbnails.swift` | put/get/delete thumbnails with metadata headers | **CREATE** (3 methods on `DS3S3ClientProtocol` extension) |
| Thumbnail constants | `DS3Lib/Sources/DS3Lib/Constants/DefaultSettings.swift` | New `.Thumbnail` namespace + settings filename | **MODIFY** (append `.Thumbnail` enum after `.S3`, `.Trash`, before `.Update` — around line 215; add one line to `.FileNames`) |
| V3 schema | `DS3Lib/Sources/DS3Lib/Metadata/SyncedItem.swift` | `SyncedItemSchemaV3` + `ThumbnailStatus` + `migrateV2toV3` + typealias | **MODIFY** (append V3 after V2 ends at line 156; update migration plan at 179-197; bump typealias at 200) |
| Store container bind | `DS3Lib/Sources/DS3Lib/Metadata/MetadataStore.swift:16,24,42` | Schema used by `createContainer()` | **MODIFY** (one-line change: `SyncedItemSchemaV2.self` → `V3.self`) |
| Query surface | `DS3Lib/Sources/DS3Lib/Metadata/MetadataStore+Queries.swift` | `fetchPendingThumbnails` + `setThumbnailStatus` + `PendingThumbnail` DTO | **MODIFY** (append new section after line 200) |
| Thumbnail settings | `DS3Lib/Sources/DS3Lib/SharedData/SharedData+thumbnailSettings.swift` | Per-drive JSON in App Group | **CREATE** (1:1 mirror of `+trashSettings.swift`) |
| Backfill coordinator | `DS3Lib/Sources/DS3Lib/Thumbnails/ThumbnailBackfillCoordinator.swift` | Actor, dormant scaffold | **CREATE** (renders macOS-only, shell cross-platform) |
| Extension consumer rewrite | `DS3DriveProvider/FileProviderExtension+Thumbnails.swift:338-346` | `fetchThumbnails` fallback call site | **MODIFY** (replace the utType-conforms cascade with a single `ThumbnailRenderer` instance call; drop video/pdf branches; drop the `@preconcurrency import ImageIO` if no other reference remains) |
| Generator file | `DS3DriveProvider/FileProviderExtension+ThumbnailGenerators.swift` | Currently hosts `generateImageThumbnail/Video/PDF` + `jpegData` | **DELETE** (verified only caller is `+Thumbnails.swift:338-346`; grep confirmed no other references in the repo) |
| Renderer test | `DS3Lib/Tests/DS3LibTests/ThumbnailRendererTests.swift` | Moved from `DS3DriveProviderTests/ThumbnailGeneratorTests.swift` | **CREATE** (new home) + **DELETE old file** + remove 1 PBXBuildFile + 1 PBXFileReference from pbxproj (2 entries at lines 86 and 319 / 1308) |
| Test fixture refs | `DS3Drive.xcodeproj/project.pbxproj` | 4 LFS fixtures currently bundled into DS3DriveProviderTests Resources | **REMOVE** 4 PBXBuildFile + 4 PBXFileReference entries (lines 86/319-323 / 1307-1308 / resources section with `B11105011…A7F01…04`) — fixtures continue to live in `DS3Lib/Tests/DS3LibTests/Fixtures/` and are auto-picked-up by the SPM `.process("Fixtures")` declaration at `Package.swift:30`. No file deletions on disk. |

### Pattern 1: Protocol-default extension method for mockable tests (CRITICAL)

Phase 11's `inspectThumbnailPrefix` sets the template that Phase 12's three new S3 methods MUST follow. Implementation goes on `public extension DS3S3ClientProtocol` — NOT on `DS3S3Client`:

```swift
// Source: DS3Lib/Sources/DS3Lib/DS3S3Client+ThumbnailPrefix.swift:20-60 — VERBATIM shape
public extension DS3S3ClientProtocol {
    func inspectThumbnailPrefix(bucket: String, prefix: String?) async throws -> ThumbnailPrefixState {
        let thumbPrefix = S3PathUtils.thumbnailsPrefix(forDrivePrefix: prefix)
        let result = try await listObjects(
            bucket: bucket,
            prefix: thumbPrefix,
            delimiter: nil,
            maxKeys: 10,
            continuationToken: nil
        )
        // ...
    }
}
```

Phase 12's `+Thumbnails.swift` adopts the same shape:

```swift
// Phase 12 NEW — DS3Lib/Sources/DS3Lib/DS3S3Client+Thumbnails.swift
public extension DS3S3ClientProtocol {
    func putThumbnail(
        bucket: String, key: String, data: Data, sourceETag: String
    ) async throws -> String {
        precondition(data.count < DefaultSettings.Thumbnail.maxSinglePartBytes,
                     "Thumbnails must be <500 KB single-part")
        // Call into something mockable. Candidate: existing `putObjectData` is mockable on
        // the protocol but doesn't carry metadata; the minimal move is to either (a) extend
        // the protocol with a metadata-aware putObjectData variant, or (b) make the
        // metadata path concrete on `DS3S3Client` and have the protocol extension dispatch
        // via a type check. Option (a) is cleaner — see Open Question #2 below.
        // ...
    }

    func getThumbnailBytes(bucket: String, key: String) async throws -> Data? { ... }

    func deleteThumbnail(bucket: String, key: String) async throws { ... }
}
```

**Why this matters:** `MockDS3S3Client` at `DS3Lib/Tests/DS3LibTests/MockDS3S3Client.swift:5` conforms to `DS3S3ClientProtocol` — it gets all three new methods for free via the protocol extension, provided the methods only call `self.listObjects(...)` / `self.putObjectData(...)` / `self.getObject(...)` / `self.deleteObject(...)` which are ALREADY on the protocol. See `InspectThumbnailPrefixTests.swift:25-29` for the exact call-into-mock pattern.

### Pattern 2: SwiftData versioned schema with raw-string + @Transient enum accessor

Verbatim from V2 at `SyncedItem.swift:70-98`:

```swift
@Model
public final class SyncedItem {
    // ...
    public var syncStatus: String  // raw string for @Predicate macros

    @Transient public var status: SyncStatus {
        get { SyncStatus(rawValue: syncStatus) ?? .pending }
        set { syncStatus = newValue.rawValue }
    }
}

public enum SyncStatus: String, Codable, Sendable { case pending, syncing, /* ... */ }
```

Phase 12's V3 `SyncedItem` adds one stored field + one `@Transient` accessor using the identical template — ONLY additive, no fields renamed or removed. Example shape for V3:

```swift
// Phase 12 NEW — SyncedItem.swift, appended after line 156 (end of V2)
public enum SyncedItemSchemaV3: VersionedSchema {
    public nonisolated static let versionIdentifier = Schema.Version(3, 0, 0)
    public static var models: [any PersistentModel.Type] {
        [SyncedItem.self, SyncAnchorRecord.self]
    }

    @Model
    public final class SyncedItem {
        // [all V2 fields copied VERBATIM — see lines 72-116]

        /// Thumbnail status stored as raw string for SwiftData predicate compatibility.
        public var thumbnailStatus: String = ThumbnailStatus.pending.rawValue

        /// Type-safe accessor for `thumbnailStatus`.
        @Transient public var thumbnail: ThumbnailStatus {
            get { ThumbnailStatus(rawValue: thumbnailStatus) ?? .pending }
            set { thumbnailStatus = newValue.rawValue }
        }

        public init(
            s3Key: String, driveId: UUID, size: Int64 = 0,
            syncStatus: String = SyncStatus.pending.rawValue,
            thumbnailStatus: String = ThumbnailStatus.pending.rawValue
        ) {
            self.s3Key = s3Key
            self.driveId = driveId
            self.uniqueKey = "\(driveId.uuidString):\(s3Key)"
            self.size = size
            self.syncStatus = syncStatus
            self.thumbnailStatus = thumbnailStatus
        }
    }

    @Model
    public final class SyncAnchorRecord {
        // [V2's SyncAnchorRecord copied VERBATIM — no changes]
    }
}

public enum ThumbnailStatus: String, Codable, Sendable {
    case notApplicable, pending, uploaded, failed
}
```

**Important:** V2's `SyncAnchorRecord` is part of V2's `models` array (`SyncedItem.swift:67`). V3 **must also list `SyncAnchorRecord.self`** in its `models` even though no change is made to that model — otherwise the lightweight migration loses the anchor entity. The V3 definition redeclares `SyncAnchorRecord` byte-identically so the schema contains both entities.

### Pattern 3: Lightweight migration stage

Verbatim from V1→V2 at `SyncedItem.swift:193-196`:

```swift
nonisolated static let migrateV1toV2 = MigrationStage.lightweight(
    fromVersion: SyncedItemSchemaV1.self,
    toVersion: SyncedItemSchemaV2.self
)
```

Phase 12's V2→V3 migration adopts the identical shape:

```swift
// Phase 12 modification to SyncedItem.swift
public enum SyncedItemMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] {
        [SyncedItemSchemaV1.self, SyncedItemSchemaV2.self, SyncedItemSchemaV3.self]
    }

    public static var stages: [MigrationStage] {
        [migrateV1toV2, migrateV2toV3]
    }

    nonisolated static let migrateV1toV2 = MigrationStage.lightweight(
        fromVersion: SyncedItemSchemaV1.self, toVersion: SyncedItemSchemaV2.self
    )

    nonisolated static let migrateV2toV3 = MigrationStage.lightweight(
        fromVersion: SyncedItemSchemaV2.self, toVersion: SyncedItemSchemaV3.self
    )
}

public typealias SyncedItem = SyncedItemSchemaV3.SyncedItem  // was V2
```

**Swift default on the @Model class (CONTEXT question about `@Attribute(…default:)`):** SwiftData's lightweight migration **does** honor Swift-level defaults on `@Model` properties — the default on `public var thumbnailStatus: String = ThumbnailStatus.pending.rawValue` is what gets populated for existing rows. **No `@Attribute(…default:)` literal is needed.** This is how V1→V2's `isMaterialized: Bool = false` default at `SyncedItem.swift:111` is implemented and it has been shipping in production since Phase 2 without issue. Proof: migration tests at `MetadataStoreMigrationTests.swift:7-22` (V2 test) verify `isMaterialized` defaults to `false` for existing rows post-migration.

### Pattern 4: Sendable DTO for cross-actor queries

`MetadataStore+Queries.swift:40-47` defines `CachedChildItem: Sendable` — a plain struct with value-type fields. `fetchChildren` at lines 56-83 materializes `SyncedItem` rows into `CachedChildItem` snapshots inside the actor, then returns the array across the boundary. Phase 12's `PendingThumbnail` mirrors this exactly:

```swift
// Phase 12 addition to MetadataStore+Queries.swift
public struct PendingThumbnail: Sendable {
    public let s3Key: String
    public let etag: String?
    public let contentType: String?
    public let size: Int64
}

public extension MetadataStore {
    func fetchPendingThumbnails(driveId: UUID, limit: Int) throws -> [PendingThumbnail] {
        let pendingRaw = ThumbnailStatus.pending.rawValue
        let predicate = #Predicate<SyncedItem> {
            $0.driveId == driveId && $0.thumbnailStatus == pendingRaw
        }
        var descriptor = FetchDescriptor<SyncedItem>(predicate: predicate)
        descriptor.fetchLimit = limit  // bounded by `limit` per D-22
        let items = try modelExecutor.modelContext.fetch(descriptor)

        // Raster allow-list filter runs in Swift after fetch (D-22 explicitly notes
        // that SwiftData predicates don't compose cleanly over a dynamic content-type
        // allow-list). Acceptable because fetch is already bounded.
        let rasterExtensions: Set<String> = ["jpg","jpeg","png","heic","heif","webp","gif","tiff","tif"]
        return items.compactMap { item -> PendingThumbnail? in
            let ext = (item.s3Key as NSString).pathExtension.lowercased()
            guard rasterExtensions.contains(ext) else { return nil }
            return PendingThumbnail(
                s3Key: item.s3Key,
                etag: item.etag,
                contentType: item.contentType,
                size: item.size
            )
        }
    }

    func setThumbnailStatus(s3Key: String, driveId: UUID, status: ThumbnailStatus) throws {
        guard let item = try findItem(byKey: s3Key, driveId: driveId) else { return }
        item.thumbnailStatus = status.rawValue
        try modelExecutor.modelContext.save()
    }
}
```

Note: `fetchLimit` is applied BEFORE the allow-list filter, so the actually-returned count may be `< limit`. Phase 13's backfill caller must tolerate this. Documented in function docstring.

### Pattern 5: 1:1 SharedData JSON mirror

`SharedData+trashSettings.swift:1-90` is the exact template. The delta for Phase 12 is: (a) type renamed `TrashSettings` → `ThumbnailSettings`, (b) fields collapsed from `{enabled, retentionDays}` to `{enabled}`, (c) file URL helper renamed `trashSettingsURL()` → `thumbnailSettingsURL()`, (d) load-all helper renamed `loadAllTrashSettings` → `loadAllThumbnailSettings`. No new `SharedData` primitives needed — `coordinatedWrite`, `coordinatedRead`, and `sharedContainerURL` are already in `SharedData.swift`.

### Pattern 6: Extension file pattern for DS3S3Client

| File | Purpose | Introduced |
|------|---------|-----------|
| `DS3S3Client.swift` | Core init + list/head/delete/copy | Phase 1 |
| `DS3S3Client+Transfers.swift` | Downloads, uploads, multipart | Phase 1 |
| `DS3S3ClientProtocol.swift` | Mockable protocol | Phase 4 |
| `DS3S3Client+Protocol.swift` | Protocol conformance (note: actual file appears split into the protocol in `DS3S3ClientProtocol.swift`) | Phase 4 |
| `DS3S3Client+Presign.swift` | Presigned GET URLs | Phase 10 |
| `DS3S3Client+ThumbnailPrefix.swift` | `inspectThumbnailPrefix` + `ThumbnailPrefixState` enum | Phase 11 |
| **`DS3S3Client+Thumbnails.swift`** | **NEW in Phase 12** | Phase 12 |

### Anti-Patterns to Avoid

- **Don't put `putThumbnail` on the concrete `DS3S3Client` class only.** Tests use `MockDS3S3Client` which conforms to `DS3S3ClientProtocol`. Putting the method only on the concrete class means the mock can't be exercised directly via the same call site. The Phase 11 precedent is to put methods on `public extension DS3S3ClientProtocol` so both real and mock clients see them.
- **Don't add `thumbnailStatus` as `@Attribute(.unique)` or into `uniqueKey`.** The composite uniqueness `"\(driveId):\(s3Key)"` at `SyncedItem.swift:126` is preserved identically in V3. Adding a new unique attribute would break migration.
- **Don't drop `SyncAnchorRecord` from `V3.models`.** Even though that model doesn't change, the migration plan expects both entities to be present in the target schema.
- **Don't invoke the coordinator from any production code path in Phase 12.** Phase 12 success criterion #5 explicitly says "runnable (though unused)". The `FileProviderExtension+Thumbnails.swift` consumer stays pointed at `ThumbnailRenderer` directly; Phase 13 rewires the cache-first path through the coordinator.
- **Don't special-case iOS inside `ThumbnailRenderer`.** The whole-type `#if os(macOS)` gate means the type doesn't exist on iOS. Attempting a runtime guard inside `renderJPEG` would defeat the compile-time gate required by THUMB-07. See CONTEXT D-03.
- **Don't pass the `x-amz-meta-` prefix in the metadata dict.** Soto strips this prefix automatically (VERIFIED). Passing `["x-amz-meta-source-etag": ...]` would result in a header like `x-amz-meta-x-amz-meta-source-etag`, which is what the S3 protocol actually ships. Use bare keys: `["source-etag": sourceETag, "ds3drive-thumb-version": "1"]`.
- **Don't extract a new `DefaultSettings.Thumbnail` namespace for the PHASE-11 constants (`thumbnailsPrefix`, `thumbnailMaxDimension`, `thumbnailJPEGQuality`).** Phase 11 D-17 deliberately chose flat constants on `DefaultSettings.S3`. Moving them in Phase 12 churns every Phase 11 call site for zero benefit. Phase 12 only ADDS the new `DefaultSettings.Thumbnail` namespace with NEW constants.
- **Don't pass custom errors from the DS3Lib layer to the File Provider boundary.** Per CLAUDE.md, only `NSFileProviderErrorDomain` / `NSCocoaErrorDomain` cross that boundary. DS3Lib's three new methods (`putThumbnail` / `getThumbnailBytes` / `deleteThumbnail`) throw raw Soto errors (`AWSErrorType`, `S3ErrorType`) and raw Swift errors. Phase 13's consumer does the wrap.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| `x-amz-meta-*` header encoding | Manual header building on `PutObjectRequest` | `S3.PutObjectRequest(metadata: [String: String])` with bare keys | Soto v6 declares `AWSMemberEncoding(label: "metadata", location: .headerPrefix("x-amz-meta-"))` at `S3_shapes.swift:1597` — it prepends the prefix per-key automatically [VERIFIED] |
| ETag normalization | String manipulation by hand | `ETagUtils.normalize` (existing) at `DS3Lib/Sources/DS3Lib/Utils/ETagUtils.swift` | Already used by every other DS3S3Client method; see `+Transfers.swift:27` |
| "Not found" error detection | `error.localizedDescription.contains("NoSuchKey")` | `DS3S3Client.isNotFoundError(_:)` at `DS3S3Client.swift:378-381` | Official helper; handles both `NoSuchKey` and `NotFound` error codes from any Soto error type |
| SwiftData migration boilerplate | Custom row-walking code | `MigrationStage.lightweight(fromVersion:toVersion:)` | V1→V2 uses it (`SyncedItem.swift:193`); SwiftData handles defaulted-additive fields without custom code |
| Temporary file handling | Tracking `NSTemporaryDirectory()` paths by hand | `FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)` + `defer { try? FileManager.default.removeItem(at: url) }` | Standard pattern used throughout DS3DriveProvider |
| Memory probing | `task_info` / `mach_task_basic_info` by hand | `os_proc_available_memory()` (already used at Phase 11 generator line 35) | Darwin system call, single line, unchanged in Phase 12 extraction |
| Autoreleasepool across async | `Task.yield()` alone | Explicit `autoreleasepool { ... }` around the decode (preserved from Phase 11 at lines 42-74) | Swift async doesn't insert pools at suspension points |
| JSON file in App Group | Hand-rolled file I/O | `SharedData.coordinatedWrite` / `coordinatedRead` (existing in `SharedData.swift:55-110`) | Already handles `NSFileCoordinator` semantics and error paths |
| Test fixture loading | `Bundle(for: Self.self)` (extension-target pattern) | `Bundle.module.url(forResource:withExtension:)` (SPM testTarget with `resources: [.process("Fixtures")]`) | `Package.swift:30` already declares the resource path; relocated tests use `Bundle.module` |

**Key insight:** Every piece of new machinery in Phase 12 either already exists (Soto metadata, ETag normalization, error detection, SwiftData migrations, SharedData coordinated I/O, Bundle.module) or is a one-line Apple / Soto call. **Phase 12 is 100% assembly of existing parts** with the sole exception of the `ThumbnailBackfillCoordinator` actor shell — and even that is a ~60-line orchestration around existing DS3Lib primitives.

## ListObjectsV2 Call-Site Audit

Not applicable in Phase 12 — this was Phase 11's work. Phase 12 does NOT add new list sites.

## Runtime State Inventory

Phase 12 involves a SwiftData schema bump (V2 → V3), which touches stored data. Every category below is answered explicitly.

| Category | Items Found | Action Required |
|----------|-------------|------------------|
| **Stored data** | (1) `SyncedItems.store{,-shm,-wal}` under `~/Library/Group Containers/group.X889956QSM.io.cubbit.DS3Drive/Library/Application Support/` — SwiftData V2 rows. V2→V3 lightweight migration will populate `thumbnailStatus = "pending"` on every existing row on first open of the V3 container. (2) Zero thumbnail objects exist yet in any user's S3 bucket — Phase 12 never invokes `putThumbnail` from production. (3) No `thumbnail-settings.json` files in any user's App Group container yet. | **Data migration:** automatic via SwiftData lightweight stage — no manual data migration code needed. **Code edit:** all operating on new V3 fields via the `@Transient` accessor. Validation: `SchemaV3MigrationTests` seeds a V2 store, re-opens as V3, asserts existing rows acquire `.pending` status. |
| **Live service config** | None. No external service (Cubbit IAM, DS3 Composer, Finder/Files, iOS file provider) carries `thumbnailStatus` / `ThumbnailSettings` references. No webhook configurations. No CI config stores any thumbnail-related values. | None — verified by grep: no "thumbnailStatus", "thumbnail-settings", or "DefaultSettings.Thumbnail" references anywhere outside the DS3Lib source tree. |
| **OS-registered state** | None. No LaunchServices registration, no Task Scheduler entries, no launchd plists touch Phase 12 artifacts. The File Provider extension is already registered and its `Info.plist` is unaffected (no `NSExtensionFileProviderDocumentGroup` change). | None — verified by repo-wide grep on plist files: no thumbnail references in `Info.plist` files. |
| **Secrets / env vars** | None. Phase 12 introduces no new secrets, no new API keys, no new coordinator URLs, no new entitlements. S3 thumbnail PUT uses existing Cubbit IAM credentials already in `SharedData` / App Group. | None. |
| **Build artifacts / installed packages** | (1) `DS3Lib/.build/` — will rebuild on first `swift test` invocation after the V3 schema lands (incremental SwiftData macro expansion). (2) Xcode `DerivedData/DS3Drive-*/` — rebuilt on next `xcodebuild` invocation. (3) `DS3DriveProviderTests` Xcode target currently bundles `exif6-portrait.heic`, `exif6-portrait.jpg`, `large-test.png`, `unsupported.pdf` as Resources (pbxproj lines around 86, 319-323, 1307-1308, resources section). Phase 12 removes those PBXBuildFile / PBXFileReference entries from the pbxproj; the underlying on-disk files at `DS3Lib/Tests/DS3LibTests/Fixtures/` stay put. | **Code edit:** 8 pbxproj entry deletions (4 PBXBuildFile, 4 PBXFileReference) + 1 target-membership removal for `ThumbnailGeneratorTests.swift` + file deletion for the test .swift file itself. No git-lfs re-track needed (fixtures stay in place). |

**The canonical question:** *After every file in the repo is updated, what runtime systems still have the old string cached, stored, or registered?* **Answer:** SwiftData stores that last opened with V2 will migrate automatically on first V3 open. All other state categories are clean.

## Common Pitfalls

### Pitfall 1: Swift 6 `Schema.Version` is NOT `Sendable` — V3 must use `nonisolated static let`

**What goes wrong:** Developer declares `public static let versionIdentifier = Schema.Version(3, 0, 0)` for V3, mirroring what looks like V1 at a glance. CI (Xcode 16.2, stricter than local Xcode) emits "Non-sendable type 'Schema.Version' passed in a conforming declaration" errors and the DS3Lib package fails to compile. This is documented in `MEMORY.md` under "Swift 6 Concurrency".

**Why it happens:** V1 at `SyncedItem.swift:7` and V2 at `:65` both use `public nonisolated static let versionIdentifier = Schema.Version(...)`. The `nonisolated` modifier is load-bearing.

**How to avoid:** Copy the V2 declaration verbatim into V3 and change the version tuple only: `public nonisolated static let versionIdentifier = Schema.Version(3, 0, 0)`. Plan Task should quote V1/V2 declaration exactly.

**Warning signs:** Local `swift build` succeeds but CI fails with a concurrency warning on the V3 enum. Indicator: you used `public static let` and forgot `nonisolated`.

**Source:** `MEMORY.md` project memory + `DS3Lib/Sources/DS3Lib/Metadata/SyncedItem.swift:7,65`.

### Pitfall 2: Soto `metadata` dict with `x-amz-meta-` prefix double-encoded

**What goes wrong:** Developer writes `request = S3.PutObjectRequest(metadata: ["x-amz-meta-source-etag": sourceETag, "x-amz-meta-ds3drive-thumb-version": "1"], ...)`. Soto prepends `x-amz-meta-` per its `_encoding` table. Result: HTTP header `x-amz-meta-x-amz-meta-source-etag: <value>`. Phase 13's stale-detection reads the header expecting `x-amz-meta-source-etag` and always sees `nil`. Every thumbnail on S3 looks stale. Backfill runs forever.

**Why it happens:** Intuition says "headers start with `x-amz-meta-`, so I should put them in the dict that way." Soto's encoding abstraction inverts this.

**How to avoid:** Pass BARE keys in the dict: `["source-etag": sourceETag, "ds3drive-thumb-version": "1"]`. The `DefaultSettings.Thumbnail.sourceETagMetadataKey` and `formatVersionMetadataKey` constants already declare the bare keys per CONTEXT D-11. Assertion in tests: after PUT, inspect `headObject(bucket:key:).metadata` and verify the returned dict has bare keys (Soto strips the prefix on the response side too — symmetric).

**Warning signs:** Phase 13 integration tests report "every thumbnail is stale" when source ETags haven't changed. Check the raw HTTP header (via Soto debug logging) for `x-amz-meta-x-amz-meta-`.

**Source:** `soto/Sources/Soto/Services/S3/S3_shapes.swift:1597` — `AWSMemberEncoding(label: "metadata", location: .headerPrefix("x-amz-meta-"))`.

### Pitfall 3: V3 migration forgets `SyncAnchorRecord` in `models`

**What goes wrong:** Developer, focused on `SyncedItem`, declares `V3.models` as `[SyncedItem.self]`. The lightweight migration stage runs, and because `SyncAnchorRecord` is not in the target schema's model list, all `SyncAnchorRecord` rows are deleted during migration. Every drive's `lastSyncDate`, `lastSuccessfulSync`, `consecutiveFailures`, `itemCount` reset to defaults. On next app launch the BFS indexer treats every drive as "never synced" and re-lists the entire bucket. Users with large buckets hit S3 rate limits.

**Why it happens:** V1→V2 added `SyncAnchorRecord` as a NEW entity. V3 neither adds nor removes entities, but the `models` declaration must still list both. Easy to miss when copy-pasting only the `SyncedItem` model.

**How to avoid:** V3's `models` array must be `[SyncedItem.self, SyncAnchorRecord.self]` identically to V2 at `SyncedItem.swift:67`. Lift the entire V2 enum block when authoring V3. Add a `SchemaV3MigrationTests.testSyncAnchorRecordSurvivesV3Migration` test that seeds a V2 store with a `SyncAnchorRecord`, migrates to V3, and asserts the anchor row is intact.

**Source:** `SyncedItem.swift:66-68` (V2 models declaration); SwiftData `VersionedSchema` contract.

### Pitfall 4: `ThumbnailRenderer` not actually unrepresentable on iOS

**What goes wrong:** Developer wraps only the method bodies (not the struct declaration) in `#if os(macOS)`. The type exists on iOS with a single stub method that returns nil. iOS tests pass. Code reviewers don't notice. THUMB-07 success criterion #2 "Importing `ThumbnailRenderer` from iOS FileProvider target fails to compile" is silently violated. Future Phase 14 iOS contributor writes `let renderer = ThumbnailRenderer()` in iOS code thinking it's a no-op, hits runtime jetsam on first call.

**Why it happens:** `#if os(macOS)` can wrap almost anything — field, method body, whole type. Only whole-type gating satisfies the compile-time requirement.

**How to avoid:** The `#if os(macOS)` marker must sit OUTSIDE `public struct ThumbnailRenderer { ... }`. On iOS the struct identifier is not declared at all. Validation: add a file to `DS3DriveProviderTests` (iOS config) that attempts `_ = ThumbnailRenderer.self` and verifies the build fails with "Cannot find 'ThumbnailRenderer' in scope" — but note this file cannot actually ship in a test target, since it must fail to compile. The pragmatic test is a CI step that `xcodebuild -destination 'platform=iOS Simulator,name=iPhone 15'` the iOS target and confirms the bundle links successfully without any `ThumbnailRenderer` symbol in its linkmap. See Validation Architecture below for Dimension 6.

**Source:** CONTEXT D-03; ROADMAP Phase 12 success criterion #2.

### Pitfall 5: `fetchLimit` interaction with raster allow-list filter

**What goes wrong:** Phase 13 caller does `try await metadataStore.fetchPendingThumbnails(driveId: d, limit: 10)` expecting up to 10 items. SwiftData's `fetchLimit` applies BEFORE the in-Swift raster-extension filter. If 9 of the first 10 pending rows are non-raster files (e.g., `.pdf`, `.mov`), the function returns 1 item. Phase 13 reads "1 < 10, must be end of queue" and stops the backfill pass, leaving hundreds of actual pending raster files unprocessed.

**Why it happens:** The `limit` semantics are ambiguous: "limit on rows fetched from SwiftData" vs. "limit on returned thumbnails-to-process." D-22 picks the first (fetch-bounded, filter-in-Swift) for SwiftData predicate-composition reasons.

**How to avoid:** Document the `limit` contract in the method docstring: *"Returns at most `limit` items. May return fewer, even when more pending items exist, because the raster allow-list filter runs in Swift after the SwiftData fetch is bounded. Callers should not infer end-of-queue from `result.count < limit`."* Phase 13 callers that want "process 5 actual thumbnails per pass" must loop with a larger initial `limit` (e.g., 20) and post-filter. Phase 12 scaffold caller in the coordinator test uses `limit: 1` with zero pending items — interaction doesn't matter in the scaffold.

**Source:** CONTEXT D-22; SwiftData `FetchDescriptor.fetchLimit` semantics.

### Pitfall 6: Test target fixture double-registration

**What goes wrong:** Developer removes `ThumbnailGeneratorTests.swift` from `DS3DriveProviderTests` but forgets to remove the 4 fixture PBXFileReference entries from the pbxproj. Xcode copies 4 fixtures into the test bundle AND SPM's `.process("Fixtures")` does the same into `DS3LibTests`. Both copies work for their respective callers but the Xcode-side fixtures occupy Git LFS bandwidth on every clone for no reason. Alternatively, developer removes the pbxproj PBXFileReferences but leaves the `ThumbnailGeneratorTests.swift` source file — the Xcode test target fails to compile because `Bundle(for: Self.self).url(forResource:"unsupported",withExtension:"pdf")` returns nil.

**Why it happens:** pbxproj edits are easy to miss because Xcode's UI doesn't surface "Resources currently in target". The .swift test file deletion and the fixture de-registration must happen atomically.

**How to avoid:** Plan task that does the relocation enumerates both: (1) delete `DS3DriveProviderTests/ThumbnailGeneratorTests.swift`, (2) remove 1 Sources entry + 4 Resources entries from pbxproj (8 PBXBuildFile/FileReference lines total). A follow-up `xcodebuild clean && xcodebuild test -scheme DS3Drive -only-testing:DS3DriveProviderTests` confirms the target builds without the .swift file. Also run `swift test --package-path DS3Lib --filter ThumbnailRendererTests` and confirm fixtures load via `Bundle.module`.

**Source:** `DS3Drive.xcodeproj/project.pbxproj` lines 86, 319-323, 1307-1308, plus the Resources build phase entries.

### Pitfall 7: `FileProviderExtension+Thumbnails.swift` imports broken by generator file deletion

**What goes wrong:** After deleting `FileProviderExtension+ThumbnailGenerators.swift`, the consumer file still has `import ImageIO` and `import UniformTypeIdentifiers` at lines 3 and 5 — needed by the generator's static-method signatures. These are now used only by `isThumbnailable(_ utType:)` at lines 256-258 and the `utType.conforms(to: .image)` check at 338-346. If the Phase 12 rewrite removes the `utType.conforms` cascade (because it delegates to `ThumbnailRenderer.renderJPEG` which does its own UTI check), `UniformTypeIdentifiers` is still needed for `UTType(filenameExtension:)` at line 301. `ImageIO` import becomes dead.

**Why it happens:** The old generator statics directly used `CGImageSourceCreateWithURL` etc., requiring `import ImageIO`. The consumer file imported ImageIO through habit.

**How to avoid:** After the rewrite at lines 338-346, audit the consumer file's imports:
- `import ImageIO` — **remove** (no direct use left; Phase 13 will re-add if cache-first needs it)
- `import UniformTypeIdentifiers` — **keep** (still used at line 301 for `UTType(filenameExtension:)`)
- `import DS3Lib` — **keep** (now also pulls `ThumbnailRenderer`)
- `@preconcurrency import FileProvider` — **keep** (still used)
- `import os.log` — **keep**

Run `swiftlint` to catch any unused import warnings.

**Source:** `DS3DriveProvider/FileProviderExtension+Thumbnails.swift:1-5`.

### Pitfall 8: Using `DS3S3Client.putObjectData` as-is for thumbnail PUT

**What goes wrong:** Developer inspects `DS3S3Client+Transfers.swift:157-169` and sees `putObjectData(bucket:key:data:)` and thinks "great, I'll just use this from the protocol extension." But `putObjectData` constructs `S3.PutObjectRequest` **without any metadata**. The resulting PUT has no `x-amz-meta-source-etag` header. THUMB-10 is silently violated.

**Why it happens:** `putObjectData` is the obvious candidate on the protocol. Its existing signature doesn't accept metadata.

**How to avoid:** Two options for Phase 12:
1. **Extend `DS3S3ClientProtocol` with a `putObjectData(bucket:key:data:metadata:)` variant** that accepts `[String: String]?`, and have `putThumbnail` call it. Concrete `DS3S3Client` implementation is a 5-line addition to `+Transfers.swift`. `MockDS3S3Client` gets one more conformance method.
2. **Make `putThumbnail` a concrete method on `DS3S3Client` (not the protocol)** and have tests use a concrete subclass of `DS3S3Client` that overrides the internal `s3.putObject` call. Messier.

**Recommendation: option (1).** It preserves the Phase 11 protocol-extension pattern, keeps mocks simple, and gives Phase 13 a reusable metadata-aware PUT for cascade / orphan-sweep (both of which may need custom metadata later). See Open Question #2 below for plan-time resolution.

**Source:** `DS3S3Client+Transfers.swift:157-169`; `DS3S3ClientProtocol.swift:44-56`.

### Pitfall 9: Coordinator's download temp file leaks on error

**What goes wrong:** Coordinator's `runBatch` downloads the original via `DS3S3Client.getObject(bucket:key:toFile: tempURL)`. Render fails (nil). Coordinator marks item `.failed` and iterates to the next. The `tempURL` is never cleaned up. Over many backfill passes, `/tmp` fills with orphaned downloads.

**How to avoid:** `defer { try? FileManager.default.removeItem(at: tempURL) }` inside the per-item loop body, placed BEFORE the download call so it always runs on any exit path (success, render-fail, throw). Match the pattern at `FileProviderExtension+Thumbnails.swift:219-224`:
```swift
var downloadedFiles: [URL] = []
defer {
    for file in downloadedFiles {
        try? FileManager.default.removeItem(at: file)
    }
}
```
The coordinator's test can verify cleanup by counting files in the temp directory before and after.

**Source:** `FileProviderExtension+Thumbnails.swift:219-224` existing precedent.

### Pitfall 10: SwiftLint file_length on `SyncedItem.swift` after V3 append

**What goes wrong:** `SyncedItem.swift` is currently 200 lines. V3 is ~60 additional lines (the nearly-verbatim V2 `SyncedItem` + `SyncAnchorRecord` redeclarations plus the `migrateV2toV3` stage plus the `ThumbnailStatus` enum). Total ~260 lines. `.swiftlint.yml` warning at 600, error at 1000 — plenty of headroom. **No action needed.**

**If discretion elects to split:** `ThumbnailStatus.swift` in `DS3Lib/Sources/DS3Lib/Metadata/` for the enum only, with V3 staying in `SyncedItem.swift`. CONTEXT D-17's "Claude's Discretion" allows either.

**Source:** `wc -l DS3Lib/Sources/DS3Lib/Metadata/SyncedItem.swift` = 200 today.

## Code Examples

Verified patterns from the live codebase. The planner can reference these directly in `<action>` fields.

### Example 1: Phase 11 generator body (the extraction source)

```swift
// Source: DS3DriveProvider/FileProviderExtension+ThumbnailGenerators.swift:29-75 — VERBATIM
static func generateImageThumbnail(from fileURL: URL, fitting maxSize: CGSize) -> Data? {
    #if canImport(UIKit)
        let availableMemory = os_proc_available_memory()
        if availableMemory > 0, availableMemory < minAvailableMemoryBytes {
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
              allowedRasterUTIs.contains(sourceType)
        else { return nil }

        let maxDimension = max(maxSize.width, maxSize.height)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            kCGImageSourceCreateThumbnailWithTransform: true,
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

**Phase 12 shape — `DS3Lib/Sources/DS3Lib/Thumbnails/ThumbnailRenderer.swift`:**

```swift
import Foundation
import CoreGraphics
import ImageIO
import os
import UniformTypeIdentifiers

#if os(macOS)
public struct ThumbnailRenderer: Sendable {
    public let maxDimension: CGFloat
    public let jpegQuality: Float

    private nonisolated(unsafe) static let allowedRasterUTIs: Set<CFString> = [
        "public.jpeg" as CFString, "public.png" as CFString,
        "public.heic" as CFString, "public.heif" as CFString,
        "org.webmproject.webp" as CFString, "com.compuserve.gif" as CFString,
        "public.tiff" as CFString
    ]

    private static let minAvailableMemoryBytes: Int = 64 * 1024 * 1024

    public init(
        maxDimension: CGFloat = CGFloat(DefaultSettings.S3.thumbnailMaxDimension),
        jpegQuality: Float = DefaultSettings.S3.thumbnailJPEGQuality
    ) {
        self.maxDimension = maxDimension
        self.jpegQuality = jpegQuality
    }

    public func renderJPEG(from fileURL: URL) -> Data? {
        // [body: VERBATIM copy of lines 29-75, replacing `maxSize` with self.maxDimension
        //  and the static jpegData quality constant with self.jpegQuality]
    }

    private func jpegData(from cgImage: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(
            dest, cgImage,
            [kCGImageDestinationLossyCompressionQuality: Double(jpegQuality)] as CFDictionary
        )
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}
#endif
```

Note the iOS memory-guard branch is preserved inside `renderJPEG` at the appropriate position — it's `#if canImport(UIKit)` inside the function body. On pure macOS the `#if canImport(UIKit)` branch is elided; on iOS the whole TYPE is elided by the outer `#if os(macOS)`. Both gates are belt-and-suspenders and can coexist.

### Example 2: V2 schema (the template for V3)

```swift
// Source: DS3Lib/Sources/DS3Lib/Metadata/SyncedItem.swift:64-156 — EXCERPT
public enum SyncedItemSchemaV2: VersionedSchema {
    public nonisolated static let versionIdentifier = Schema.Version(2, 0, 0)
    public static var models: [any PersistentModel.Type] {
        [SyncedItem.self, SyncAnchorRecord.self]
    }

    @Model
    public final class SyncedItem {
        public var s3Key: String
        public var driveId: UUID
        @Attribute(.unique) public var uniqueKey: String
        // ...
        public var syncStatus: String

        @Transient public var status: SyncStatus {
            get { SyncStatus(rawValue: syncStatus) ?? .pending }
            set { syncStatus = newValue.rawValue }
        }

        public var isMaterialized: Bool = false  // Added in V2 via lightweight migration
        public var originalKey: String?           // Added in V2 via lightweight migration
        // ...
    }

    @Model
    public final class SyncAnchorRecord { /* ... */ }
}
```

### Example 3: Existing V1→V2 migration (template for V2→V3)

```swift
// Source: DS3Lib/Sources/DS3Lib/Metadata/SyncedItem.swift:179-197 — VERBATIM
public enum SyncedItemMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] {
        [SyncedItemSchemaV1.self, SyncedItemSchemaV2.self]
    }

    public static var stages: [MigrationStage] {
        [migrateV1toV2]
    }

    nonisolated static let migrateV1toV2 = MigrationStage.lightweight(
        fromVersion: SyncedItemSchemaV1.self,
        toVersion: SyncedItemSchemaV2.self
    )
}

public typealias SyncedItem = SyncedItemSchemaV2.SyncedItem
```

### Example 4: Existing consumer call site (the rewrite target)

```swift
// Source: DS3DriveProvider/FileProviderExtension+Thumbnails.swift:338-346 — VERBATIM
let thumbnailData: Data? = if utType.conforms(to: .image) {
    Self.generateImageThumbnail(from: fileURL, fitting: size)
} else if utType.conforms(to: .movie) {
    await Self.generateVideoThumbnail(from: fileURL, fitting: size)
} else if utType.conforms(to: .pdf) {
    Self.generatePDFThumbnail(from: fileURL, fitting: size)
} else {
    nil
}
```

**Phase 12 rewrite** — the video/pdf branches are gone; the image branch delegates to `ThumbnailRenderer` directly:

```swift
let thumbnailData: Data? = utType.conforms(to: .image)
    ? ThumbnailRenderer().renderJPEG(from: fileURL)
    : nil
```

The `isThumbnailable(_ utType:)` filter at line 256-258 must also be narrowed to image-only (the video and pdf branches are out of scope per THUMB-09):

```swift
// Phase 12 — DS3DriveProvider/FileProviderExtension+Thumbnails.swift:256-258 replacement
private static func isThumbnailable(_ utType: UTType) -> Bool {
    utType.conforms(to: .image)
}
```

This removes the pre-network UTI eligibility check for movies and PDFs, meaning Phase 12's consumer will skip them at lines 300-306 before hitting the S3 HEAD. Zero behavior change for users — movies and PDFs never rendered a thumbnail anyway (Phase 11's allow-list rejected them inside `generateImageThumbnail`).

### Example 5: Existing trash settings file (1:1 template for thumbnail settings)

```swift
// Source: DS3Lib/Sources/DS3Lib/SharedData/SharedData+trashSettings.swift:1-43 — EXCERPT
public struct TrashSettings: Codable, Sendable {
    public var enabled: Bool
    public var retentionDays: Int
    public init(enabled: Bool = true, retentionDays: Int = DefaultSettings.Trash.defaultRetentionDays) {
        self.enabled = enabled
        self.retentionDays = retentionDays
    }
}

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

    // [private helpers: trashSettingsURL, loadAllTrashSettings — see lines 71-82]
}
```

**Phase 12 shape — `DS3Lib/Sources/DS3Lib/SharedData/SharedData+thumbnailSettings.swift`:** Identical structure, with `TrashSettings` → `ThumbnailSettings`, `retentionDays` removed, `default = false` per D-24.

### Example 6: Coordinator scaffold shape

```swift
// Phase 12 NEW — DS3Lib/Sources/DS3Lib/Thumbnails/ThumbnailBackfillCoordinator.swift
import Foundation

public struct BatchResult: Sendable {
    public let processed: Int
    public let succeeded: Int
    public let skipped: Int
    public let failed: Int
}

public actor ThumbnailBackfillCoordinator {
    private let metadataStore: MetadataStore
    private let s3Client: DS3S3Client
    private let drive: DS3Drive

    public init(metadataStore: MetadataStore, s3Client: DS3S3Client, drive: DS3Drive) {
        self.metadataStore = metadataStore
        self.s3Client = s3Client
        self.drive = drive
    }

    public func runBatch(maxItems: Int) async throws -> BatchResult {
        let pending = try await metadataStore.fetchPendingThumbnails(
            driveId: drive.id, limit: maxItems
        )
        guard !pending.isEmpty else {
            return BatchResult(processed: 0, succeeded: 0, skipped: 0, failed: 0)
        }

        var succeeded = 0, skipped = 0, failed = 0
        let tempDir = FileManager.default.temporaryDirectory

        #if os(macOS)
        let renderer = ThumbnailRenderer()
        for item in pending {
            let tempURL = tempDir.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: tempURL) }

            do {
                // Create empty file for streaming target (see getObject contract)
                FileManager.default.createFile(atPath: tempURL.path, contents: nil)

                let download = try await s3Client.getObject(
                    bucket: drive.syncAnchor.bucket.name,
                    key: item.s3Key,
                    toFile: tempURL,
                    onProgress: nil
                )
                guard let thumbnailData = renderer.renderJPEG(from: tempURL) else {
                    // UTI check via CGImageSourceGetType already inside renderer;
                    // nil here means unsupported format OR decode failure. Phase 12
                    // conservatively marks .failed; Phase 13 refines to .notApplicable.
                    try await metadataStore.setThumbnailStatus(
                        s3Key: item.s3Key, driveId: drive.id, status: .failed
                    )
                    failed += 1
                    continue
                }
                let thumbKey = S3PathUtils.thumbnailKey(forOriginalKey: item.s3Key)
                guard let sourceETag = download.etag else {
                    try await metadataStore.setThumbnailStatus(
                        s3Key: item.s3Key, driveId: drive.id, status: .failed
                    )
                    failed += 1
                    continue
                }
                _ = try await s3Client.putThumbnail(
                    bucket: drive.syncAnchor.bucket.name,
                    key: thumbKey,
                    data: thumbnailData,
                    sourceETag: sourceETag
                )
                try await metadataStore.setThumbnailStatus(
                    s3Key: item.s3Key, driveId: drive.id, status: .uploaded
                )
                succeeded += 1
            } catch {
                try await metadataStore.setThumbnailStatus(
                    s3Key: item.s3Key, driveId: drive.id, status: .failed
                )
                failed += 1
            }
        }
        #else
        // iOS: no render path in Phase 12. Phase 14 extends this.
        // For now, mark all returned pending items as .failed to avoid an infinite
        // fetch-then-no-op loop. Phase 14 swaps this branch.
        for item in pending {
            try await metadataStore.setThumbnailStatus(
                s3Key: item.s3Key, driveId: drive.id, status: .failed
            )
            failed += 1
        }
        #endif

        return BatchResult(
            processed: pending.count, succeeded: succeeded, skipped: skipped, failed: failed
        )
    }
}
```

Note: the `#else` branch is required because Phase 12 ships a cross-platform type (D-29). Phase 14 will rewrite the iOS branch with a native-iOS render path or an IPC-to-main-app path. Phase 12's iOS behavior is "mark all fetched items as `.failed`" which is deliberately safe — no caller invokes the coordinator from iOS in Phase 12.

### Example 7: Proposed `putObjectData` metadata extension (resolves Pitfall 8)

```swift
// Phase 12 addition to DS3Lib/Sources/DS3Lib/DS3S3Client+Transfers.swift
public extension DS3S3Client {
    /// Small-object PUT with S3 metadata headers. Metadata keys must be bare
    /// (without `x-amz-meta-` prefix) — Soto prepends the prefix automatically.
    func putObjectData(
        bucket: String,
        key: String,
        data: Data,
        metadata: [String: String]?
    ) async throws -> String? {
        let request = S3.PutObjectRequest(
            body: .byteBuffer(ByteBuffer(data: data)),
            bucket: bucket,
            key: key,
            metadata: metadata
        )
        let response = try await s3.putObject(request)
        return response.eTag
    }
}
```

Mirror signature in `DS3S3ClientProtocol.swift`:

```swift
// Phase 12 addition to DS3S3ClientProtocol.swift after line 56
func putObjectData(
    bucket: String,
    key: String,
    data: Data,
    metadata: [String: String]?
) async throws -> String?
```

Mock addition to `MockDS3S3Client.swift` (one method + one captured-params storage):

```swift
// Phase 12 addition to MockDS3S3Client.swift
var lastPutObjectMetadata: [String: String]?

func putObjectData(
    bucket: String, key: String, data: Data, metadata: [String: String]?
) async throws -> String? {
    record("putObjectData(key:\(key),size:\(data.count),meta:\(metadata?.count ?? 0))")
    lastPutObjectMetadata = metadata
    if let error = shouldThrow { throw error }
    return putObjectDataEtag
}
```

Tests then assert `mock.lastPutObjectMetadata?["source-etag"] == "<expected>"` etc.

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Static methods on `FileProviderExtension` for thumbnail generation | `ThumbnailRenderer` struct in DS3Lib with `#if os(macOS)` whole-type gate | Phase 12 (this phase) | Enables Phase 14 iOS-specific renderer variants without touching extension code; THUMB-07 enforced at compile time |
| SwiftData V2 with `syncStatus` + `isMaterialized` | SwiftData V3 adds `thumbnailStatus` field, lightweight migration populates `.pending` for existing rows | Phase 12 (this phase) | Phase 13's backfill knows what still needs processing; zero downtime on upgrade |
| No S3 thumbnail service (v2.0 generator wrote nothing) | `putThumbnail` / `getThumbnailBytes` / `deleteThumbnail` with mandatory `source-etag` + `ds3drive-thumb-version` metadata | Phase 12 (this phase) | Phase 13's stale-thumbnail detection and Phase 14's format migration both have data to work with from day one |
| Phase 11 hardened generator in extension | Lifted verbatim into DS3Lib; generator file in extension deleted | Phase 12 (this phase) | Single-source for thumbnail rendering; Phase 14 iOS can reuse DS3Lib APIs |

**Nothing deprecated** outside of the three private generator statics (video/PDF/image old signatures) that no other file in the repo references. Their file is deleted cleanly.

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | Soto v6 `S3.PutObjectRequest.metadata: [String: String]?` prepends `x-amz-meta-` per-key automatically, and `headObject` response `metadata` field strips the prefix symmetrically. | Pattern 1, Pitfall 2 | [VERIFIED: `soto/Sources/Soto/Services/S3/S3_shapes.swift:1597-1600`] — encoding entry is `headerPrefix("x-amz-meta-")`. Response-side stripping is symmetric by Soto convention but not separately verified in this session — plan-time integration test with a real bucket would confirm. Low risk. |
| A2 | SwiftData's `MigrationStage.lightweight` honors Swift-level defaults on `@Model` properties without `@Attribute(…default:)` literals. | Pattern 3 | [VERIFIED: V1→V2 migration at `SyncedItem.swift:193` ships `isMaterialized: Bool = false` via the identical pattern and has been in production since Phase 2]. |
| A3 | `SyncAnchorRecord` in V3 must be byte-identical to V2's to survive the lightweight migration. | Pitfall 3 | [ASSUMED] — SwiftData's `VersionedSchema.models` contract suggests this; not separately tested with an intentional breaking-change test. The safe implementation is to copy V2's `SyncAnchorRecord` declaration verbatim into V3's enum. |
| A4 | The `DS3DriveProviderTests` Xcode target currently has 4 fixture PBXFileReference entries + 1 ThumbnailGeneratorTests.swift source entry that must be removed during relocation. | Pitfall 6, Component table | [VERIFIED: grepped pbxproj at lines 86, 319-323, 1307-1308]. |
| A5 | `FileProviderExtension+Thumbnails.swift` is 521 lines and the ONLY caller of the old generator statics in the repo. | Summary finding #3 | [VERIFIED: `wc -l` = 521; `grep -rn "generateImageThumbnail\|generateVideoThumbnail\|generatePDFThumbnail"` outside the target file returns only the test file reference, no other callers]. |
| A6 | `inspectThumbnailPrefix` lives on `public extension DS3S3ClientProtocol` (not concrete `DS3S3Client`), which is the pattern Phase 12's new methods must follow. | Pattern 1 | [VERIFIED: `DS3S3Client+ThumbnailPrefix.swift:20` declares `public extension DS3S3ClientProtocol { ... }`; `InspectThumbnailPrefixTests.swift:27` calls `mock.inspectThumbnailPrefix` directly]. |
| A7 | The existing `DS3S3Client.getObject(bucket:key:toFile:onProgress:)` at `+Transfers.swift:17-32` is the correct download entry point for the coordinator's original-file fetch step; the `toFile` URL must already exist as an empty file. | Example 6, coordinator | [VERIFIED: method signature and file-handle contract at `+Transfers.swift:53-55` require `FileHandle(forWritingTo: fileURL)` to succeed, which fails on a nonexistent file]. |
| A8 | `DefaultSettings.S3.thumbnailMaxDimension = 512` (Int) and `thumbnailJPEGQuality: Float = 0.7` are the Phase 11 constants that Phase 12 consumes via `CGFloat(...)` and direct pass-through, respectively. | Example 1 init | [VERIFIED: `DefaultSettings.swift:201-205`]. |
| A9 | Git LFS fixtures at `DS3Lib/Tests/DS3LibTests/Fixtures/` are loaded by the SPM testTarget via `Bundle.module` because `Package.swift:30` declares `resources: [.process("Fixtures")]`. | Test target layout | [VERIFIED: `Package.swift:30`; SPM documented behavior of `.process` resource rule]. |
| A10 | No new Git LFS track rules are needed for Phase 12 — all fixtures already exist. | Environment Availability | [VERIFIED: `ls DS3Lib/Tests/DS3LibTests/Fixtures/` shows all 4 files present]. |
| A11 | The coordinator's iOS `#else` branch marking items `.failed` is acceptable Phase 12 behavior because no iOS code invokes the coordinator in Phase 12. | Example 6 | [ASSUMED] — aligns with CONTEXT D-29 ("Phase 12 only ships the macOS-gated path; iOS behavior is formally undefined because no iOS caller exists yet"). Plan should note this explicitly in the coordinator docstring. |

## Open Questions (RESOLVED)

1. **`BatchResult.succeeded` vs. `.uploaded` naming.** CONTEXT D-31 spec has `succeeded`. Phase 13's UI (THUMB-24) will eventually display "N uploaded / M skipped" progress. If `.succeeded` reads less clearly than `.uploaded` in logs, the planner may pick either per CONTEXT Claude's Discretion.
   - **RESOLVED — Recommendation:** Stay with `.succeeded` per the literal spec. Phase 13 can rename if needed — it's a scaffold-only API in Phase 12.

2. **`DS3S3ClientProtocol` addition vs. `DS3S3Client`-concrete for metadata PUT.** Phase 12 needs a mockable PUT-with-metadata entry point for `putThumbnail`. Options are sketched in Pitfall 8. **RESOLVED — Recommendation: Option 1 — extend the protocol with `putObjectData(…, metadata:)`.** Provides a future-proof seam Phase 13 orphan sweep / cascade can also mock. One-line addition to protocol, ~5 lines of implementation, ~5 lines of mock conformance.
   - If the planner disagrees and prefers concrete-only, they should document why and note that Phase 13 will need to add the protocol method anyway for orphan-sweep mockability.

3. **Whether to add an `S3Lib+Thumbnails.swift` extension wrapper on the extension side that calls the new DS3Lib methods.** Phase 11's pattern at `DS3DriveProvider/S3Lib+Thumbnails.swift:1-22` threads `DS3Drive` through. Phase 13's cache-first `fetchThumbnails` may want convenience wrappers. Phase 12 could pre-add them.
   - **RESOLVED — Recommendation:** DON'T pre-add in Phase 12. The existing `S3Lib+Thumbnails.swift` only has path-helper wrappers, not network calls. Phase 12's coordinator calls `DS3S3Client` directly. Phase 13 can add wrappers when it rewrites `fetchThumbnails`.

4. **Renderer concurrency semantics in `ThumbnailBackfillCoordinator.runBatch`.** CONTEXT Claude's Discretion allows sequential vs. parallel. Phase 12 scaffold recommendation: sequential.
   - **RESOLVED — Recommendation:** Sequential in Phase 12 scaffold. `for item in pending { ... }` with `await` on each step. Phase 13/14 can add parallelism (`withThrowingTaskGroup`, bounded by `DefaultSettings.S3.multipartUploadConcurrency = 4` or a new Thumbnail namespace constant) once a real caller needs it.

5. **V3 `SyncedItem.init` signature backward-compatibility.** V2 init is `init(s3Key:driveId:size:syncStatus:)` at `SyncedItem.swift:118-123`. If V3 adds a required `thumbnailStatus` parameter, all existing construction sites (in `MetadataStore.applyUpsert` at line 127 and `MetadataStore+Queries.swift:138`) need updating.
   - **RESOLVED — Recommendation:** Add `thumbnailStatus: String = ThumbnailStatus.pending.rawValue` as a **defaulted parameter** in V3's init — backward-compatible with all existing callers who omit it. See Example 2. Existing call sites compile unchanged.

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| Xcode 16+ (CLI `xcodebuild`) | Build `DS3Drive` scheme, run `DS3DriveProviderTests` | ✓ | 16+ | — |
| Swift 6 toolchain (`swift` CLI) | `swift test --package-path DS3Lib` | ✓ (bundled with Xcode 16) | swift-tools-version 6.0 | — |
| macOS 15+ | Build host | ✓ | `Package.swift:6` requires `.macOS(.v15)` | — |
| Git LFS | Pull test fixtures | ✓ (per CLAUDE.md setup) | current | Fixtures already present on disk |
| ImageIO (system framework) | `ThumbnailRenderer` | ✓ | macOS 14+ | — |
| SwiftData (system framework) | Schema V3 migration | ✓ | macOS 14 / iOS 17 | — |
| SotoS3 6.8+ | `putThumbnail` metadata encoding | ✓ | `DS3Lib/Package.swift:9` | — |
| Soto DerivedData checkout | Read actual `S3.PutObjectRequest` struct for verification | ✓ | `~/Library/Developer/Xcode/DerivedData/DS3Drive-evoifzppmnwmpyacqbnenyegznle/SourcePackages/checkouts/soto/` | — |

**Missing dependencies with no fallback:** None.

**Missing dependencies with fallback:** None — all tools available.

## Validation Architecture

> `workflow.nyquist_validation` is absent from `.planning/config.json` (defaults to enabled) — this section is required.

### Test Framework

| Property | Value |
|----------|-------|
| Framework | XCTest (Swift 6 language mode) |
| Config file | `DS3Lib/Package.swift:24-31` (testTarget declaration); `DS3Drive.xcodeproj` (XCTest test plan for extension tests) |
| Quick run command (DS3Lib, per class) | `swift test --package-path DS3Lib --filter <TestClassName>` |
| Full suite command (DS3Lib) | `swift test --package-path DS3Lib` |
| Xcode-side full suite | `xcodebuild -project DS3Drive.xcodeproj -scheme DS3Drive test -destination 'platform=macOS'` |
| Estimated runtime | ~45s (DS3Lib full), ~3min (DS3Drive scheme full) |

### Validation Dimensions

Phase 12 has **8 distinct validation dimensions**, each answering a specific invariant:

**Dimension 1 — Renderer correctness (THUMB-08, THUMB-09):**
The extracted `ThumbnailRenderer.renderJPEG` on the four LFS fixtures must produce:
- `exif6-portrait.heic` and `exif6-portrait.jpg` → non-nil JPEG Data with pixel geometry satisfying `height > width` (EXIF orientation 6 applied).
- `large-test.png` → non-nil Data across 50 repeated invocations completing in < 5s wall clock.
- `unsupported.pdf` → `nil` silently (no throw, no crash).

Test class: `DS3LibTests/ThumbnailRendererTests` (moved from `DS3DriveProviderTests/ThumbnailGeneratorTests`). These are the same assertions already passing in Phase 11.

Command: `swift test --package-path DS3Lib --filter ThumbnailRendererTests`

**Dimension 2 — Schema V2→V3 migration (THUMB-04):**
A V2 store seeded with N `SyncedItem` rows (varied `syncStatus`) and M `SyncAnchorRecord` rows, re-opened with V3 schema + `migrateV2toV3` stage, must preserve all rows and populate `thumbnailStatus == "pending"` on every `SyncedItem`. `SyncAnchorRecord` rows survive byte-identically.

Test class: `DS3LibTests/SchemaV3MigrationTests` — mirrors `MetadataStoreMigrationTests.swift:7-42` structure. Two required tests: (a) lightweight V2→V3 populates `.pending` default; (b) `SyncAnchorRecord` persists across migration.

Command: `swift test --package-path DS3Lib --filter SchemaV3MigrationTests`

**Dimension 3 — S3 thumbnail PUT/GET/DELETE semantics (THUMB-10):**
Using `MockDS3S3Client`:
- `putThumbnail(data: Data(count: 100), sourceETag: "abc")` results in a `putObjectData` call where captured `metadata == ["source-etag": "abc", "ds3drive-thumb-version": "1"]`. **Bare keys** (no `x-amz-meta-` prefix).
- `putThumbnail(data: Data(count: 600_000), ...)` precondition traps (may require `XCTExpectFailure` wrapper or be deferred to runtime-only).
- `getThumbnailBytes` on mock returning `S3ErrorType.noSuchKey` returns `nil` (does not throw).
- `getThumbnailBytes` on mock returning valid bytes returns those bytes.
- `getThumbnailBytes` on mock returning 5xx throws.
- `deleteThumbnail` on mock returning `NoSuchKey` succeeds (does not throw).
- `deleteThumbnail` on mock returning 5xx throws.

Test class: `DS3LibTests/DS3S3Client+ThumbnailsTests`.

Command: `swift test --package-path DS3Lib --filter DS3S3Client`

**Dimension 4 — SharedData round-trip (D-38):**
- `saveThumbnailSettings(forDrive: id, settings: ThumbnailSettings(enabled: true))` followed by `loadThumbnailSettings(forDrive: id)` returns `.enabled == true`.
- Default-on-missing-file: `loadThumbnailSettings` against a nonexistent file returns `ThumbnailSettings(enabled: false)`.
- Multi-drive: two drives can independently persist different `enabled` values without stomping each other.
- Coordinated write safety: two parallel save operations don't corrupt the JSON file (mirror the existing `SharedDataPersistenceTests` pattern).

Test class: `DS3LibTests/SharedData+thumbnailSettingsTests`.

Command: `swift test --package-path DS3Lib --filter SharedData`

**Dimension 5 — Coordinator scaffold smoke (D-39):**
Construct `ThumbnailBackfillCoordinator` with a `MetadataStore` containing zero pending rows and a `MockDS3S3Client`. Call `runBatch(maxItems: 1)`. Assert:
- Returns `BatchResult(processed: 0, succeeded: 0, skipped: 0, failed: 0)`.
- `MockDS3S3Client.calls` does NOT contain `getObject` or `putObjectData` (coordinator short-circuits on empty pending list).

Test class: `DS3LibTests/ThumbnailBackfillCoordinatorTests`. Scaffold-only per D-39 — **do not add end-to-end flow tests in Phase 12**.

Command: `swift test --package-path DS3Lib --filter ThumbnailBackfillCoordinator`

**Dimension 6 — iOS compile-error assertion for `#if os(macOS)` gate (THUMB-07):**
This is the tricky one — it's a NEGATIVE test (code must FAIL to compile). Options:
- (a) CI step: `xcodebuild -project DS3Drive.xcodeproj -scheme DS3Drive -destination 'platform=iOS Simulator,name=iPhone 15' -skipPackagePluginValidation build` succeeds AND the resulting bundle does not contain a `ThumbnailRenderer` symbol (verify via `nm -gU` or `objdump -t` on the iOS binary).
- (b) Build-time grep: after the Phase 12 commits, CI runs `grep -rn "public struct ThumbnailRenderer" DS3Lib/` and confirms the match is inside a `#if os(macOS)` block. This is a weaker proof but catches the common regression (developer unwraps the guard).
- (c) A separate "iOS link test" target that attempts `_ = ThumbnailRenderer.self` and confirms it doesn't build (Xcode can't naturally express a target that must fail to compile).

**Recommendation:** Combine (a) + (b) — CI runs the iOS build + a grep check asserting the outer `#if os(macOS)` marker exists immediately before `public struct ThumbnailRenderer`. The Phase 12 plan wave 5 must include both steps.

Command: `xcodebuild -project DS3Drive.xcodeproj -scheme DS3DriveApp -destination 'platform=iOS Simulator,name=iPhone 15' build` + `grep -B1 "public struct ThumbnailRenderer" DS3Lib/Sources/DS3Lib/Thumbnails/ThumbnailRenderer.swift | head -2`

**Dimension 7 — Existing test target migration verification:**
After the test relocation, verify:
- `swift test --package-path DS3Lib --filter ThumbnailRendererTests` passes (new home works).
- `xcodebuild test -scheme DS3Drive -only-testing:DS3DriveProviderTests` passes (old target builds and runs without the deleted .swift file and without the 4 removed fixture refs).
- No grep match for `generateImageThumbnail\|generateVideoThumbnail\|generatePDFThumbnail` anywhere in the repo except in the new ThumbnailRendererTests that may reference the renamed API.

**Dimension 8 — Nyquist validation of the above:**
The plan-checker / Nyquist auditor runs the full DS3LibTests suite via `swift test --package-path DS3Lib` plus the DS3Drive scheme's `xcodebuild test` to verify no regression in existing tests (SyncEngine, MetadataStore V1→V2 migration, Presign, inspectThumbnailPrefix, S3KeyFilter). Every Phase 12 task's `<verify>` command must be present; there must be no 3-consecutive-task gap in automated coverage per Nyquist. The 7 manual human-verify checkpoints in the plan (if any) must all have a corresponding automated test either in Phase 12 or explicitly deferred to Phase 13 with a traceable reason.

### Per-Requirement Test Map (populated by planner)

| Req ID | Behavior | Dimension | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-----------|-------------------|-------------|
| THUMB-04 | Schema V3 persists `thumbnailStatus` + V2→V3 migration preserves rows | 2 | unit (in-memory container) | `swift test --package-path DS3Lib --filter SchemaV3MigrationTests` | ❌ Wave 0 (new file) |
| THUMB-04 | `fetchPendingThumbnails` returns only `.pending` rows, respects `limit` + `driveId` | 2 | unit | `swift test --package-path DS3Lib --filter MetadataStoreThumbnailQueriesTests` | ❌ Wave 0 (new file) |
| THUMB-07 | `ThumbnailRenderer` fails to compile on iOS | 6 | build-time assertion | `xcodebuild build -scheme DS3DriveApp -destination 'platform=iOS Simulator,name=iPhone 15'` + grep check | ✅ (existing iOS schemes) |
| THUMB-08 | EXIF-6 portrait input produces portrait-geometry thumbnail | 1 | unit w/ fixture + synthesized source | `swift test --package-path DS3Lib --filter ThumbnailRendererTests/testImageThumbnailAppliesEXIF6RotationToPortraitOutput` | ❌ Wave 0 (relocated file) |
| THUMB-09 | PDF fixture returns nil (allow-list rejection) | 1 | unit w/ fixture | `swift test --package-path DS3Lib --filter ThumbnailRendererTests/testImageThumbnailRejectsPDFByUTIAllowList` | ❌ Wave 0 (relocated file) |
| THUMB-09 | Repeated decode of large PNG stays under 5s | 1 | unit w/ fixture | `swift test --package-path DS3Lib --filter ThumbnailRendererTests/testImageThumbnailRepeatedInvocationsReturnNonNil` | ❌ Wave 0 (relocated file) |
| THUMB-10 | PUT carries both metadata headers with BARE keys | 3 | unit (mock) | `swift test --package-path DS3Lib --filter DS3S3ClientThumbnailsTests/testPutThumbnailIncludesBothMetadataHeaders` | ❌ Wave 0 (new file) |
| THUMB-10 | Single-part enforcement via precondition at 500KB | 3 | unit (boundary) | `swift test --package-path DS3Lib --filter DS3S3ClientThumbnailsTests/testPutThumbnailAtSizeBoundary` | ❌ Wave 0 (new file) |
| THUMB-10 | GET returns nil on NoSuchKey, bytes on 200, throws on 5xx | 3 | unit (mock) | `swift test --package-path DS3Lib --filter DS3S3ClientThumbnailsTests/testGetThumbnailBytes` | ❌ Wave 0 (new file) |
| THUMB-10 | DELETE succeeds on NoSuchKey, throws on 5xx | 3 | unit (mock) | `swift test --package-path DS3Lib --filter DS3S3ClientThumbnailsTests/testDeleteThumbnail` | ❌ Wave 0 (new file) |
| (D-23/D-38) | ThumbnailSettings round-trips per-drive, defaults to enabled=false | 4 | unit | `swift test --package-path DS3Lib --filter SharedDataThumbnailSettingsTests` | ❌ Wave 0 (new file) |
| (D-39) | Coordinator scaffold returns empty BatchResult on empty pending list | 5 | unit (mock) | `swift test --package-path DS3Lib --filter ThumbnailBackfillCoordinatorTests` | ❌ Wave 0 (new file) |

### Sampling Rate

- **Per task commit:** Run `swift test --package-path DS3Lib --filter <ClassName>` (≤10s per class).
- **Per wave merge:** Run `swift test --package-path DS3Lib` (~45s full suite) + `xcodebuild -project DS3Drive.xcodeproj -scheme DS3Drive -only-testing:DS3DriveProviderTests test` (~1min).
- **Phase gate:** Full DS3Lib suite green + full DS3Drive scheme green + iOS build succeeds + grep check for `#if os(macOS)` in front of `ThumbnailRenderer`. All 8 dimensions covered.
- **Max feedback latency:** 60 seconds per-task, 3 minutes per-wave.

### Wave 0 Gaps

The following files and targets must be created BEFORE the Phase 12 plan's task execution begins (Wave 0):

- [ ] `DS3Lib/Tests/DS3LibTests/ThumbnailRendererTests.swift` — relocated from `DS3DriveProviderTests`, using `Bundle.module` instead of `Bundle(for:)`. Covers Dimensions 1 per THUMB-08, THUMB-09.
- [ ] `DS3Lib/Tests/DS3LibTests/DS3S3Client+ThumbnailsTests.swift` — new file. Covers Dimension 3 per THUMB-10.
- [ ] `DS3Lib/Tests/DS3LibTests/SchemaV3MigrationTests.swift` — new file. Covers Dimension 2 per THUMB-04.
- [ ] `DS3Lib/Tests/DS3LibTests/MetadataStoreThumbnailQueriesTests.swift` — new file. Covers Dimension 2 per THUMB-04 (query surface).
- [ ] `DS3Lib/Tests/DS3LibTests/SharedDataThumbnailSettingsTests.swift` — new file. Covers Dimension 4.
- [ ] `DS3Lib/Tests/DS3LibTests/ThumbnailBackfillCoordinatorTests.swift` — new file. Covers Dimension 5.
- [ ] Deletion: `DS3DriveProviderTests/ThumbnailGeneratorTests.swift` + 4 PBXFileReference / PBXBuildFile entries in `DS3Drive.xcodeproj/project.pbxproj` (fixture refs).
- [ ] `MockDS3S3Client` addition (in `DS3Lib/Tests/DS3LibTests/MockDS3S3Client.swift`): `func putObjectData(bucket:key:data:metadata:)` + captured `lastPutObjectMetadata` property.

No test framework install needed — XCTest is already the codebase standard. No new CI hooks needed — the full DS3Lib suite and DS3Drive scheme are already wired into CI per `.github/workflows/` (existing, not modified by Phase 12).

## Out of Scope in Phase 12

Per CONTEXT `<deferred>` section, the following are explicitly NOT in Phase 12 and the plan must not drift into them:

- Cache-first `fetchThumbnails` rewrite → **Phase 13**. Phase 12 only rewrites the single call site at `FileProviderExtension+Thumbnails.swift:338-346`.
- Upload-path hook (`UploadThumbnailHook` at `createItem` / `modifyItem`) → **Phase 13**.
- Cascade hooks (delete/rename/move) → **Phase 13**.
- Orphan sweep (and thus the `headThumbnail` method) → **Phase 13**.
- BFS backfill invocation (calling `runBatch` from the indexer) → **Phase 13**.
- `ThumbnailFetchLimiter` (Finder fanout throttling) → **Phase 13**.
- Negative cache / 3-strike retry rule (THUMB-20) → **Phase 13**.
- Tray progress UI (THUMB-24) + `countPending(driveId:)` query → **Phase 13**.
- iOS `BGProcessingTask` + `ForegroundBackfillDriver` → **Phase 14**.
- Cellular gating + "Generate now" action → **Phase 14**.
- iOS settings progress UI → **Phase 14**.
- Parallel renders inside `runBatch` → **Phase 13/14**.
- EXIF thumbnail fast path (range-GET first ~64 KB) → **deferred beyond v3.1**.
- PNG fallback for line-art / screenshots → **deferred beyond v3.1**.
- Video / PDF / RAW thumbnail support → **out of scope per REQUIREMENTS**.
- WebP / AVIF thumbnail format → **deferred beyond v3.1** (`DefaultSettings.Thumbnail.formatVersion = 1` is the extension point).
- Persisting Phase 11's "Use anyway" collision choice → **Phase 13** re-runs `inspectThumbnailPrefix` on feature enable.

**Zero user-visible change in Phase 12.** The extension continues to show thumbnails for locally-downloaded files exactly as it does post-Phase-11 — the only behavior delta is that video/PDF items now skip the network HEAD entirely (via the narrower `isThumbnailable` check), which is strictly an improvement.

## Sources

### Primary (HIGH confidence — source code inspected this session)

- `DS3Lib/Package.swift` — test resources declaration + Swift 6 language mode
- `DS3Lib/Sources/DS3Lib/Constants/DefaultSettings.swift` — Phase 11 thumbnail constants on S3 namespace; FileNames structure
- `DS3Lib/Sources/DS3Lib/Metadata/SyncedItem.swift` — V1, V2, migration plan, typealias
- `DS3Lib/Sources/DS3Lib/Metadata/MetadataStore.swift` — `createContainer()` + schema binding at lines 16, 42
- `DS3Lib/Sources/DS3Lib/Metadata/MetadataStore+Queries.swift` — Sendable DTO pattern + predicate examples
- `DS3Lib/Sources/DS3Lib/DS3S3Client.swift` — core client + `S3ListingResult`/`S3ObjectMetadata` types + `isNotFoundError` helper
- `DS3Lib/Sources/DS3Lib/DS3S3ClientProtocol.swift` — mockable seam (protocol declaration)
- `DS3Lib/Sources/DS3Lib/DS3S3Client+Transfers.swift` — download/upload surface; `getObject(bucket:key:toFile:onProgress:)` signature
- `DS3Lib/Sources/DS3Lib/DS3S3Client+Presign.swift` — extension file pattern
- `DS3Lib/Sources/DS3Lib/DS3S3Client+ThumbnailPrefix.swift` — Phase 11 protocol-extension pattern (Pattern 1 template)
- `DS3Lib/Sources/DS3Lib/SharedData/SharedData.swift` — `coordinatedWrite` / `coordinatedRead` / `sharedContainerURL`
- `DS3Lib/Sources/DS3Lib/SharedData/SharedData+trashSettings.swift` — 1:1 settings template
- `DS3Lib/Sources/DS3Lib/Utils/S3PathUtils.swift` — Phase 11 thumbnail helpers at lines 98-158
- `DS3Lib/Sources/DS3Lib/Utils/S3KeyFilter.swift` — Phase 11 filter routing
- `DS3Lib/Sources/DS3Lib/Models/DS3Drive.swift` — coordinator constructor parameter shape
- `DS3Lib/Tests/DS3LibTests/MockDS3S3Client.swift` — protocol-conforming mock; `lastListObjectsMaxKeys` precedent for captured params
- `DS3Lib/Tests/DS3LibTests/InspectThumbnailPrefixTests.swift` — test-via-protocol-extension pattern
- `DS3Lib/Tests/DS3LibTests/MetadataStoreMigrationTests.swift` — V2 migration test template
- `DS3Lib/Tests/DS3LibTests/Fixtures/` — 4 LFS fixtures (ls verified)
- `DS3DriveProvider/FileProviderExtension+Thumbnails.swift` — consumer at 521 lines, rewrite target at 338-346
- `DS3DriveProvider/FileProviderExtension+ThumbnailGenerators.swift` — extraction source, 156 lines
- `DS3DriveProvider/S3Lib+Thumbnails.swift` — extension-side path helpers
- `DS3DriveProviderTests/ThumbnailGeneratorTests.swift` — tests to relocate
- `DS3Drive.xcodeproj/project.pbxproj` — PBXBuildFile/PBXFileReference entries at lines 86, 319-323, 1307-1308
- `~/Library/Developer/Xcode/DerivedData/DS3Drive-*/SourcePackages/checkouts/soto/Sources/Soto/Services/S3/S3_shapes.swift:1597-1602` — `S3.PutObjectRequest` `_encoding` table + `metadata: [String: String]?` declaration [VERIFIED]

### Secondary (MEDIUM confidence — cross-referenced from STACK.md / PITFALLS.md via Phase 11 context)

- `.planning/research/STACK.md` §"ImageIO" — the four mandatory ImageIO flags (already in Phase 11 shipped code)
- `.planning/research/STACK.md` §"Soto v6 small API surface" — three-method signature shape
- `.planning/research/PITFALLS.md` §5 (EXIF), §13 (autoreleasepool + memory guard)

### Tertiary (LOW confidence — not separately verified)

- Soto v6 `headObject` response `metadata` dict prefix-stripping symmetry (Pitfall 2 assumption A1). Would need a plan-time integration test against a real bucket to verify the round-trip.

## Metadata

**Confidence breakdown:**
- Standard stack: **HIGH** — every library version pinned in `Package.swift:8-11`, Soto metadata encoding verified at source
- Architecture: **HIGH** — all file paths, line numbers, and patterns read during this session
- Schema migration: **HIGH** — V1→V2 migration is the literal 1:1 template; SwiftData lightweight semantics verified in production
- Pitfalls: **HIGH** — 10 pitfalls grounded in concrete code, 2 [ASSUMED] escape hatches clearly flagged

**Research date:** 2026-04-24
**Valid until:** 2026-05-24 (30 days — Phase 11 shipped 2 weeks ago; the seams are stable)

## RESEARCH COMPLETE
