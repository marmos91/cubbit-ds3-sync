# Phase 12: Renderer, Storage & Schema - Context

**Gathered:** 2026-04-24
**Status:** Ready for planning

<domain>
## Phase Boundary

Phase 12 lands the **storage + generation primitives** that Phase 13 will wire into user-facing code paths. Specifically, DS3Lib gains:

1. **`ThumbnailRenderer`** — a platform-gated (`#if os(macOS)` around the entire type), memory-safe image → JPEG renderer extracted from the already-hardened `FileProviderExtension+ThumbnailGenerators.swift`. Struct with init. Delivers THUMB-07, THUMB-08, THUMB-09.
2. **`DS3S3Client+Thumbnails.swift`** — `putThumbnail` / `getThumbnailBytes` / `deleteThumbnail` on `DS3S3Client`. Single-part PUT only, carries both `x-amz-meta-source-etag` and `x-amz-meta-ds3drive-thumb-version` on every write. Delivers THUMB-10.
3. **Schema V3** — `SyncedItem.thumbnailStatus: String` field with `ThumbnailStatus` enum (`.notApplicable` / `.pending` / `.uploaded` / `.failed`), lightweight V2→V3 migration, and a new `fetchPendingThumbnails(driveId:limit:)` query on `MetadataStore`. Delivers THUMB-04.
4. **`SharedData+thumbnailSettings.swift`** — per-drive `ThumbnailSettings(enabled: Bool = false)` mirroring `SharedData+trashSettings.swift` 1:1. App-Group JSON, opt-in everywhere.
5. **`ThumbnailBackfillCoordinator` actor** — scaffolded in `DS3Lib/Thumbnails/` with a runnable `runBatch(maxItems:) → BatchResult` entry point. Cross-platform shell; only the render step is macOS-gated. Unused in Phase 12.

**Not in this phase:** no upload-path hook (Phase 13), no `fetchThumbnails` rewrite (Phase 13), no cascade hooks (Phase 13), no orphan sweep (Phase 13), no BFS backfill invocation (Phase 13), no tray progress UI (Phase 13), no iOS `BGProcessingTask` or `ForegroundBackfillDriver` (Phase 14), no cellular gating (Phase 14). **Phase 12 writes zero bytes to S3 in practice** — the coordinator exists and is runnable but no caller invokes it.

</domain>

<decisions>
## Implementation Decisions

### Renderer (THUMB-07, THUMB-08, THUMB-09)

- **D-01:** `ThumbnailRenderer` is a **struct with an initializer**, not an enum-of-statics. Signature: `public struct ThumbnailRenderer { public init(maxDimension: CGFloat = CGFloat(DefaultSettings.S3.thumbnailMaxDimension), jpegQuality: Float = DefaultSettings.S3.thumbnailJPEGQuality); public func renderJPEG(from fileURL: URL) -> Data? }`. Instance state is the two config knobs; allows future injection (e.g., a smaller quality for overnight iOS backfill) without breaking the API. Renderer has no state that needs an actor — the decode path is pure.
- **D-02:** File location: `DS3Lib/Sources/DS3Lib/Thumbnails/ThumbnailRenderer.swift`. Opens a new `Thumbnails/` directory under DS3Lib that Phase 12 also uses for `ThumbnailBackfillCoordinator.swift`. The S3 service stays as a `DS3S3Client+Thumbnails.swift` extension file at the root of DS3Lib sources — consistent with `+Presign.swift`, `+Transfers.swift`, `+ThumbnailPrefix.swift`.
- **D-03:** **`#if os(macOS)` wraps the entire type declaration** (not just method bodies). On iOS targets, `ThumbnailRenderer` literally does not exist — `import DS3Lib` + `ThumbnailRenderer()` is a compile error, which is exactly what THUMB-07 / phase success-criterion #2 demands ("Importing `ThumbnailRenderer` from the iOS File Provider extension target fails to compile"). This is load-bearing — a runtime guard or no-op stub does NOT satisfy the criterion.
- **D-04:** The renderer is a **mechanical extraction** of the Phase 11-hardened static functions in `DS3DriveProvider/FileProviderExtension+ThumbnailGenerators.swift`. All four ImageIO flags (`kCGImageSourceShouldCache: false`, `kCGImageSourceCreateThumbnailFromImageAlways: true`, `kCGImageSourceCreateThumbnailWithTransform: true`, `kCGImageSourceShouldCacheImmediately: true`), the `autoreleasepool`, the `CGImageSourceGetType` allow-list check, and the `os_proc_available_memory()` guard move verbatim. Phase 12 does NOT rewrite any of this logic — it lifts it into the new struct and re-points tests.
- **D-05:** **`generateVideoThumbnail` and `generatePDFThumbnail` are deleted entirely**, not moved. v3.1 scope is raster-only per THUMB-09 and REQUIREMENTS Out of Scope. They're not called by any code we're keeping. Leaving them behind as dead-but-public API in DS3Lib invites misuse.
- **D-06:** **`FileProviderExtension+ThumbnailGenerators.swift` is deleted** once extraction completes. Its only caller (`FileProviderExtension+Thumbnails.swift:157-249`'s `fetchThumbnails` fallback) is rewritten in this phase to call `ThumbnailRenderer` directly via an instance. No shim, no deprecation file, no re-export. Phase 13's big `fetchThumbnails` rewrite inherits a clean call site.
- **D-07:** **`ThumbnailGeneratorTests.swift` moves from `DS3DriveProviderTests/` to `DS3LibTests/`**. Fixtures already in Git LFS move with them (via `Bundle(for:)` path update, or by relocating the Resources build phase to the DS3LibTests target). Tests become `ThumbnailRendererTests`. The macOS-only XCTest pattern stays — iOS can't compile these at all now that the type is `#if os(macOS)`.

### S3 Service (THUMB-10)

- **D-08:** **Methods live on `DS3S3Client`** as a new extension file `DS3Lib/Sources/DS3Lib/DS3S3Client+Thumbnails.swift`. Mirrors the existing extension pattern (`+Presign.swift`, `+Transfers.swift`, `+ThumbnailPrefix.swift`). The name "ThumbnailS3Service" in the phase goal is conceptual — the implementation shape is three functions on the same client that already owns Soto. This keeps the mockable `DS3S3Client+Protocol` seam intact: Phase 12 extends the protocol with the three new entry points.
- **D-09:** **API surface (exact signatures):**
  ```swift
  public func putThumbnail(
      bucket: String,
      key: String,
      data: Data,
      sourceETag: String
  ) async throws -> String  // returns thumbnail ETag

  public func getThumbnailBytes(
      bucket: String,
      key: String
  ) async throws -> Data?  // nil on 404, throws otherwise

  public func deleteThumbnail(
      bucket: String,
      key: String
  ) async throws  // silent success on 404
  ```
  `sourceETag` is a **required non-optional parameter** on `putThumbnail` — staleness-blind uploads are unrepresentable at the call site.

- **D-10:** **Both metadata headers always present on PUT:**
  - `x-amz-meta-source-etag: <sourceETag>` — for Phase 13's stale-thumbnail detection (original ETag changes → thumbnail needs regen)
  - `x-amz-meta-ds3drive-thumb-version: 1` — for future format migrations (e.g., WebP/AVIF in a v3.2 milestone)
- **D-11:** **Open a `DefaultSettings.Thumbnail` namespace** in `DS3Lib/Sources/DS3Lib/Constants/DefaultSettings.swift`. Phase 11 left the size/quality/prefix constants flat on `DefaultSettings.S3` (Phase 11 D-16/D-17 explicitly deferred the namespace until tuning knobs arrive). Phase 12 adds:
  ```swift
  public enum Thumbnail {
      public static let formatVersion = 1
      public static let sourceETagMetadataKey = "source-etag"     // Soto strips the x-amz-meta- prefix
      public static let formatVersionMetadataKey = "ds3drive-thumb-version"
      public static let maxSinglePartBytes = 500_000  // single-part enforcement threshold
  }
  ```
  The size/quality/prefix constants stay where Phase 11 put them (`DefaultSettings.S3`) — moving them would churn Phase 11 call sites for zero benefit. New knobs live under `DefaultSettings.Thumbnail`.

- **D-12:** **Single-part PUT enforcement** via `precondition(data.count < DefaultSettings.Thumbnail.maxSinglePartBytes)` at the top of `putThumbnail`. `putThumbnail` uses Soto's single-shot `S3.putObject(PutObjectRequest)` directly — NOT the multipart-capable path in `+Transfers.swift`. Thumbnails at 512px JPEG Q0.7 are reliably <100KB; a >500KB thumbnail means the renderer is misbehaving, and `precondition` surfaces that loudly in dev/CI rather than letting a corrupt thumbnail ship silently.
- **D-13:** **`getThumbnailBytes` returns `Data?`** with nil = 404. Network / auth / 5xx errors throw through to the caller. This is the shape Phase 13's cache-first `fetchThumbnails` rewrite needs: `nil` = "generate later", `throw` = "S3 is broken, let the caller decide". No `NSFileProviderErrorDomain` at this layer — DS3Lib is deeper than the File Provider boundary.
- **D-14:** **`deleteThumbnail` is silent on 404.** Phase 13's cascade-on-delete and orphan-sweep paths both produce 404s as a normal outcome (thumbnail never existed, or was already swept). Throwing would force every caller to wrap in a try/catch they'd always swallow. Network / auth errors still throw.
- **D-15:** A `HEAD` method is **NOT** added in Phase 12. Phase 13's orphan-sweep may want one, but that's Phase 13's call. Shipping only what Phase 12's spec requires.

### Schema V3 + MetadataStore (THUMB-04)

- **D-16:** New `SyncedItemSchemaV3` in `DS3Lib/Sources/DS3Lib/Metadata/SyncedItem.swift`, mirroring the existing V1 / V2 definitions in the same file. `SyncedItemSchemaV2.SyncedItem` becomes `SyncedItemSchemaV3.SyncedItem` with **one new stored field and one new `@Transient` accessor**:
  ```swift
  // New stored field, raw string for SwiftData predicate compatibility
  public var thumbnailStatus: String = ThumbnailStatus.pending.rawValue

  // Typed accessor, same pattern as syncStatus
  @Transient public var thumbnail: ThumbnailStatus {
      get { ThumbnailStatus(rawValue: thumbnailStatus) ?? .pending }
      set { thumbnailStatus = newValue.rawValue }
  }
  ```
  The `SyncAnchorRecord` sibling model in V2 stays byte-identical in V3 (no fields added).

- **D-17:** `public enum ThumbnailStatus: String, Codable, Sendable` with four cases: `.notApplicable` / `.pending` / `.uploaded` / `.failed`. Ships alongside `SyncStatus` in the same file.
- **D-18:** **Lightweight V2→V3 migration** — `MigrationStage.lightweight(fromVersion: SyncedItemSchemaV2.self, toVersion: SyncedItemSchemaV3.self)` appended to `SyncedItemMigrationPlan.stages`. Existing rows get the Swift default (`.pending`) on the new field. SwiftData handles this without custom code. Matches the V1→V2 pattern already shipped.
- **D-19:** **Fresh rows default to `.pending`**; classification (raster vs non-raster) happens at **query time**, not upsert time. The upsert path in `MetadataStore` stays untouched. The query filter applies the raster allow-list. Status transitions to `.notApplicable` / `.uploaded` / `.failed` only through explicit `setThumbnailStatus` calls from the coordinator. **Consequence:** the V2→V3 lightweight migration is 100% safe — it just adds a defaulted field. No classification work runs during migration. Existing installs upgrade cleanly even with 100,000 rows.
- **D-20:** `typealias SyncedItem = SyncedItemSchemaV3.SyncedItem` replaces the V2 alias at the bottom of the file. `MetadataStore.createContainer()` updates from `Schema(versionedSchema: SyncedItemSchemaV2.self)` to `V3.self`. **Existing `SyncedItem` call sites do not change** — the typealias absorbs the version bump, so no other DS3Lib / extension code recompiles meaningfully.
- **D-21:** **Migration-failed fallback stays** — `MetadataStore.createContainer`'s existing catch block (which deletes `SyncedItems.store{,-shm,-wal}` and recreates) inherits V3 automatically. If someone upgrades from a pre-V2 corrupt store, the metadata rebuilds from S3 as it does today. Phase 12 tests this path: seed a V2 store, open as V3, assert migration succeeds. No separate test needed for the "broken store" path — it's covered by existing behavior.
- **D-22:** **New MetadataStore query surface (added to `MetadataStore+Queries.swift`):**
  ```swift
  public struct PendingThumbnail: Sendable {
      public let s3Key: String
      public let etag: String?
      public let contentType: String?
      public let size: Int64
  }

  func fetchPendingThumbnails(driveId: UUID, limit: Int) throws -> [PendingThumbnail]
  func setThumbnailStatus(s3Key: String, driveId: UUID, status: ThumbnailStatus) throws
  ```
  The predicate on `fetchPendingThumbnails`: `driveId == X AND thumbnailStatus == "pending"`. The raster-extension / content-type filter runs in Swift **after** the fetch — SwiftData predicates don't compose across a dynamic content-type allow-list cleanly, and the fetch is already bounded by `limit`. `countPending` is NOT added in Phase 12 — Phase 13 can add it when tray progress UI (THUMB-24) actually needs it.

### SharedData + Settings

- **D-23:** **`SharedData+thumbnailSettings.swift` is a 1:1 mirror of `SharedData+trashSettings.swift`.** Per-drive, JSON in App Group:
  ```swift
  public struct ThumbnailSettings: Codable, Sendable {
      public var enabled: Bool
      public init(enabled: Bool = false) { self.enabled = enabled }
  }

  extension SharedData {
      public func loadThumbnailSettings(forDrive driveId: UUID) throws -> ThumbnailSettings
      public func saveThumbnailSettings(forDrive driveId: UUID, settings: ThumbnailSettings) throws
  }
  ```
  Uses the same `coordinatedWrite` / `coordinatedRead` + `[String: ThumbnailSettings]` keyed-by-driveId-uuidString pattern.

- **D-24:** **Default `enabled = false`** for all drives, including existing drives upgrading to V3. Phase 12 ships no user-visible change; Phase 13 is what flips this on (either automatically on macOS for eligible drives, or via an explicit setting — Phase 13's call). Keeping default off means Phase 12 is load-free for every user who installs it.
- **D-25:** **No speculative fields** in `ThumbnailSettings`. Not `cellularAllowed`, not `forceQuitAcknowledged`, not `manualOverride`. Settings is Codable — Phase 14 can add fields without migration pain. Phase 11 made the same call on `TrashSettings` and it was correct.
- **D-26:** **Phase 11's "Use anyway" collision choice is NOT persisted in Phase 12.** The collision is re-checked by Phase 13's feature-enable path via the existing `inspectThumbnailPrefix`. If the bucket has diverged (externally added conflicting keys), the user sees the warning again — intentional re-consent. This matches Phase 11 D-10 and keeps `ThumbnailSettings` free of transient ack state. Also: the collision override belongs with the drive / wizard flow, not with the thumbnail feature toggle.
- **D-27:** `DefaultSettings.FileNames` (or its moral equivalent — check current file) gets a new `thumbnailSettingsFileName` constant pointing at e.g. `thumbnail-settings.json`. Follows the `trashSettingsFileName` naming precedent.

### Backfill Coordinator Scaffold

- **D-28:** **`public actor ThumbnailBackfillCoordinator`** at `DS3Lib/Sources/DS3Lib/Thumbnails/ThumbnailBackfillCoordinator.swift`. Actor isolation guarantees Swift 6 strict-concurrency compliance without `@unchecked Sendable` escape hatches.
- **D-29:** **Cross-platform shell, macOS-only render.** The actor itself compiles on iOS + macOS so Phase 14's iOS main app can reuse it verbatim. Only the **render step inside `runBatch`** is `#if os(macOS)` — when compiled on iOS, the render branch is replaced with a fatalError-free early-return that marks items `.failed` (or, more likely, the iOS main app extends the actor in Phase 14 with a different renderer path). Phase 12 only ships the macOS-gated path; iOS behavior of the actor in Phase 12 is formally undefined because no iOS caller exists yet.
- **D-30:** **Construction signature:**
  ```swift
  public init(
      metadataStore: MetadataStore,
      s3Client: DS3S3Client,
      drive: DS3Drive
  )
  ```
  One coordinator per drive. Phase 13 owns the "create one per drive on launch" logic. Renderer is lazily constructed inside `runBatch` with DefaultSettings knobs — not injected, because Phase 12's single renderer config suffices; Phase 14 can extend the init if per-coordinator render config is needed.

- **D-31:** **Batch entry point:**
  ```swift
  public struct BatchResult: Sendable {
      public let processed: Int
      public let succeeded: Int
      public let skipped: Int     // .notApplicable transitions
      public let failed: Int      // .failed transitions
  }

  public func runBatch(maxItems: Int) async throws -> BatchResult
  ```
  Phase 12 ships this as **runnable but scaffolded** — the happy path works end-to-end (fetch pending → render → PUT thumbnail → mark uploaded), but it's never invoked from production code. Phase 13's BFS backfill hook calls this with `maxItems: 5`. Phase 14's iOS overnight task calls it in a loop until expiration. One API, two cadences, no overloading.

- **D-32:** **Render-fail policy in Phase 12 scaffold:** if `ThumbnailRenderer.renderJPEG` returns nil, the coordinator checks the file's UTI (via the existing allow-list in Phase 11's generator): unsupported → `.notApplicable`, supported-but-failed → `.failed`. This is the minimum policy needed for the phase success criterion #1 ("MetadataStore can answer 'which items still need a thumbnail'"). Retry budgets, negative cache, and 3-strike rules (THUMB-20) are **Phase 13** — not Phase 12.
- **D-33:** Coordinator downloads the **original file** via existing `DS3S3Client+Transfers.swift` (`getObjectToFile` or equivalent) to a temp URL, renders, uploads the thumbnail, deletes the temp file. No streaming — the renderer needs a file URL because `CGImageSourceCreateWithURL` is the memory-safe path.

### Test Strategy

- **D-34:** **`ThumbnailRendererTests`** lives in `DS3LibTests`, moved from `DS3DriveProviderTests`. All Phase 11 fixtures (HEIC-EXIF-6, JPEG-EXIF-6, large PNG, `unsupported.pdf`) move with the tests. Assertions stay identical — the generator logic is unchanged, only the home moves.
- **D-35:** **`DS3S3Client+ThumbnailsTests`** — mocked via the existing `DS3S3Client+Protocol` seam, matching the Phase 11 `inspectThumbnailPrefix` test pattern. Assertions:
  - `putThumbnail` issues a PutObject with both `x-amz-meta-source-etag` and `x-amz-meta-ds3drive-thumb-version: 1` headers (inspect the captured request).
  - `putThumbnail` with `data.count == 600_000` traps via precondition (use `XCTExpectFailure` or a wrapper; alternatively test boundary at 499_999 succeeds, 500_001 would trap — skip the trap test if harness can't catch it, rely on runtime signal in dev).
  - `getThumbnailBytes` returns `nil` on a canned `NoSuchKey` response, returns bytes on 200, rethrows on 5xx.
  - `deleteThumbnail` succeeds on 204 and on `NoSuchKey` response, rethrows on 5xx.
- **D-36:** **`SchemaV3MigrationTests`** — seed a V2 store with N rows, close container, re-open with V3 schema + V2→V3 stage, assert all rows present and `thumbnailStatus == "pending"`. Add one test that seeds rows with varied `syncStatus` to prove the new field is additive.
- **D-37:** **`MetadataStore+ThumbnailQueriesTests`** — `fetchPendingThumbnails` returns only `.pending` rows, respects `driveId`, respects `limit`, returns Sendable DTO. `setThumbnailStatus` transitions correctly and persists across re-fetch.
- **D-38:** **`SharedData+thumbnailSettingsTests`** — round-trip `enabled: true` / `false`, default-on-missing-file, coordinated-write safety (mirror Phase 1+ `SharedData+trashSettingsTests` if present).
- **D-39:** **`ThumbnailBackfillCoordinatorTests`** — scaffold test only in Phase 12: construct the coordinator with mock MetadataStore + mock `DS3S3Client`, call `runBatch(maxItems: 1)`, assert it returns `BatchResult(processed: 0, ...)` when no pending items exist. End-to-end flow tests (fetch → render → put) can be added in Phase 13 when real callers wire it up. **Do not over-test a scaffold** that will be revisited next phase.

### Claude's Discretion

- Exact file layout under `DS3Lib/Sources/DS3Lib/Thumbnails/` (single file per type vs `ThumbnailRenderer.swift` + `ThumbnailRenderer+Internal.swift` split).
- Whether `ThumbnailStatus` lives in `SyncedItem.swift` next to `SyncStatus` or in a new `ThumbnailStatus.swift` sibling file.
- Whether to store `ThumbnailSettings` under a new `[driveId: ThumbnailSettings]` JSON or consolidated into an existing settings file — **the file layout should mirror `trashSettings` exactly (separate file)** per D-23 unless there's a concrete reason not to.
- Minor internal naming (e.g., `BatchResult.succeeded` vs `.uploaded`).
- Whether `ThumbnailBackfillCoordinator.runBatch` uses a `TaskGroup` for parallel renders in Phase 12's scaffold or stays sequential (recommend sequential scaffold; Phase 13/14 can add parallelism when caller needs it — macOS can afford 2-4 per STACK.md).
- Whether to temporarily keep an internal `typealias ThumbnailGenerator = ThumbnailRenderer` for grep-discoverability during the Phase 12 → Phase 13 seam (probably no — clean break is better).

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Project & Milestone Specs
- `.planning/PROJECT.md` — v3.1 Thumbnails milestone definition, out-of-scope list, constraints (macOS 14+ / iOS 17+), no-custom-backend principle.
- `.planning/REQUIREMENTS.md` §v3.1 Requirements → THUMB-04, THUMB-07, THUMB-08, THUMB-09, THUMB-10 (Phase 12 scope). Future Requirements / Out of Scope sections bound what Phase 12 must *not* do (no EXIF fast-path, no RAW, no PDF, no video, no multiple sizes).
- `.planning/ROADMAP.md` §"Phase 12: Renderer, Storage & Schema" — goal, success criteria (5 items), depends-on chain to Phase 11.

### Prior Phase Context (Phase 11 — load-bearing for Phase 12)
- `.planning/phases/11-foundation-filtering/11-CONTEXT.md` §Decisions D-15 through D-20 — append-`.jpg` key rule, constants on `DefaultSettings.S3`, full generator hardening already landed. Phase 12 is a mechanical extraction of this work.
- `.planning/phases/11-foundation-filtering/11-CONTEXT.md` §"Deferred Ideas" — explicit hand-offs to Phase 12 (ThumbnailRenderer extraction, Schema V3, SharedData+thumbnailSettings).

### Milestone Research (the load-bearing context)
- `.planning/research/STACK.md` §"ImageIO — `CGImageSource` thumbnail extraction" — the four mandatory ImageIO flags, memory characteristics, iOS jetsam avoidance; all present in Phase 11's hardened generator.
- `.planning/research/STACK.md` §"Soto v6 range GETs" → "New small API surface needed" — the three signatures (`putThumbnail` / `getThumbnailBytes` / `deleteThumbnail`) Phase 12 ships; Phase 12 strengthens `putThumbnail` to require `sourceETag` and enforces single-part.
- `.planning/research/STACK.md` §"Platform-Specific Patterns" — macOS extension vs iOS main app vs iOS extension split; drives the `#if os(macOS)` hard gate (THUMB-07) and justifies the cross-platform coordinator shell.
- `.planning/research/PITFALLS.md` §Pitfall 1 (iOS jetsam — motivates THUMB-07 compile-time gate), §Pitfall 5 (EXIF orientation — preserved via the ThumbnailWithTransform flag Phase 11 already enforces), §Pitfall 13 (autoreleasepool + memory guard — preserved verbatim in extraction).
- `.planning/research/ARCHITECTURE.md` §"Component Inventory" → DS3Lib row and `DS3DriveProvider` row — Phase 12 shifts mass from the extension to DS3Lib.
- `.planning/research/FEATURES.md` — generator and storage feature rows.

### Existing Code — Phase 11 Delivered (the extraction source)
- `DS3DriveProvider/FileProviderExtension+ThumbnailGenerators.swift` (entire file, ~156 lines) — the hardened generator. Phase 12 extracts lines 29-75 (`generateImageThumbnail`) and lines 138-155 (`jpegData`) into `ThumbnailRenderer`. Lines 77-135 (`generateVideoThumbnail`, `generatePDFThumbnail`) are **deleted**, not moved.
- `DS3DriveProvider/FileProviderExtension+Thumbnails.swift:157-249` — `fetchThumbnails` consumer. Phase 12 updates call sites to use `ThumbnailRenderer` via an instance; Phase 13 rewrites the whole consumer cache-first.
- `DS3DriveProviderTests/ThumbnailGeneratorTests.swift` — test file moves from `DS3DriveProviderTests` to `DS3LibTests`, renamed `ThumbnailRendererTests`. Fixtures move with it.

### Existing Code — Schema Precedent (the 1:1 migration pattern)
- `DS3Lib/Sources/DS3Lib/Metadata/SyncedItem.swift` — V1 and V2 schema definitions + `SyncedItemMigrationPlan` + `migrateV1toV2`. Phase 12 adds `SyncedItemSchemaV3` + `migrateV2toV3` at the bottom, updates the `typealias SyncedItem = V3.SyncedItem`.
- `DS3Lib/Sources/DS3Lib/Metadata/MetadataStore.swift:15-47` — `createContainer()`'s two-path (happy + recovery-delete-and-recreate) logic. Phase 12 updates the `Schema(versionedSchema:)` call to V3 and the migration plan stays the same enum.
- `DS3Lib/Sources/DS3Lib/Metadata/MetadataStore+Queries.swift` — existing Sendable-DTO pattern (`CachedChildItem`, `CachedItemMetadata`, `fetchChildren`). Phase 12's `PendingThumbnail` + `fetchPendingThumbnails` follow this pattern exactly.

### Existing Code — SharedData Precedent (the 1:1 pattern)
- `DS3Lib/Sources/DS3Lib/SharedData/SharedData+trashSettings.swift` — the complete template. Phase 12's `SharedData+thumbnailSettings.swift` is a rename + field swap (`enabled: Bool` + remove `retentionDays`).
- `DS3Lib/Sources/DS3Lib/Constants/DefaultSettings.swift:196-205` — `trashPrefix` / `thumbnailsPrefix` / `thumbnailMaxDimension` / `thumbnailJPEGQuality` already flat on `DefaultSettings.S3` from Phase 11. Phase 12 adds a new `DefaultSettings.Thumbnail` namespace for `formatVersion`, metadata-key names, and `maxSinglePartBytes`.

### Existing Code — S3 Client Extension Precedent
- `DS3Lib/Sources/DS3Lib/DS3S3Client+Presign.swift` (Phase 10) — extension file pattern Phase 12's `+Thumbnails.swift` mirrors.
- `DS3Lib/Sources/DS3Lib/DS3S3Client+Transfers.swift` — existing object upload / download / range-GET surface. Phase 12's coordinator uses this to download originals.
- `DS3Lib/Sources/DS3Lib/DS3S3Client+ThumbnailPrefix.swift` (Phase 11) — `inspectThumbnailPrefix` collision check. Phase 12 does NOT call this; Phase 13's feature-enable path does.
- `DS3Lib/Sources/DS3Lib/DS3S3ClientProtocol.swift` — the mockable seam. Phase 12 extends the protocol with `putThumbnail` / `getThumbnailBytes` / `deleteThumbnail`.

### File Provider Error Rules (non-negotiable)
- `CLAUDE.md` (repo root) §"File Provider Error Handling" — errors crossing the File Provider boundary must be `NSFileProviderErrorDomain` or `NSCocoaErrorDomain`. Phase 12 stays below that boundary (DS3Lib), but Phase 13 consumers of `getThumbnailBytes` will wrap at the boundary — keeping DS3Lib errors as raw Soto / Swift errors here is correct.

### Soto v6 Reference
- `https://soto.codes/` (or the embedded Package.swift docs) — `S3.PutObjectRequest.metadata: [String: String]?` for the `x-amz-meta-*` headers. Soto strips the `x-amz-meta-` prefix automatically; callers pass the bare key (e.g., `"source-etag"`). Confirmed pattern — see Soto v6 S3 docs.

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- **Phase 11's hardened generator** (`FileProviderExtension+ThumbnailGenerators.swift`) is the verbatim source for `ThumbnailRenderer.renderJPEG`. Copy + delete, not rewrite.
- **`SyncedItemSchemaV1` → `SyncedItemSchemaV2`** migration in `SyncedItem.swift` is the 1:1 template for V2 → V3. Including the `@Attribute(.unique)` composite key pattern (no change needed — V3 adds a field, doesn't alter keys).
- **`SharedData+trashSettings.swift`** is the 1:1 template for `SharedData+thumbnailSettings.swift`. Rename, swap struct fields, done.
- **`DS3S3Client+Presign.swift`** is the 1:1 template for `DS3S3Client+Thumbnails.swift` (extension file pattern, protocol extension, test mocking pattern).
- **`MetadataStore+Queries.swift`'s `CachedChildItem` + `fetchChildren`** pattern is the 1:1 template for `PendingThumbnail` + `fetchPendingThumbnails`.
- **Git LFS test fixtures** (HEIC-EXIF-6, JPEG-EXIF-6, large PNG, `unsupported.pdf`) already land in Phase 11 — Phase 12 relocates the Resources build phase to `DS3LibTests`, zero re-adds.
- **`DS3S3Client+Protocol`** already abstracts S3 operations — extending it with three new entry points + mocking in DS3LibTests requires no new test infrastructure.

### Established Patterns
- **Raw-string + @Transient enum accessor** for SwiftData @Model fields. `SyncStatus` in V2 uses this; `ThumbnailStatus` in V3 follows identically. Predicates operate on the raw-string field; Swift code uses the accessor.
- **Lightweight migrations** for additive fields. Both V1→V2 and the upcoming V2→V3 use `MigrationStage.lightweight` — there's no project-internal custom migration runner yet, and this phase doesn't introduce one.
- **Sendable DTO pattern** in `MetadataStore+Queries.swift` — no `@Model` object ever escapes the actor. `PendingThumbnail` follows the same discipline.
- **Per-drive settings JSON in App Group** — `trashSettings` pattern with `coordinatedWrite` / `coordinatedRead` + `[String: Settings]` keyed by `driveId.uuidString`. File name constant in `DefaultSettings.FileNames` (or equivalent).
- **DS3S3Client extension files** at DS3Lib source root (not in a subdirectory): `+Presign.swift`, `+Transfers.swift`, `+ThumbnailPrefix.swift`. Phase 12's `+Thumbnails.swift` joins them. Types that deserve a dedicated home (like `ThumbnailRenderer`, `ThumbnailBackfillCoordinator`) go in `Thumbnails/` subdir.
- **`#if os(macOS)` / `#if canImport(UIKit)`** gating is already present in Phase 11's hardened generator (lines 30-39 for the memory guard). Phase 12 extends this to the whole-type gate for `ThumbnailRenderer`.

### Integration Points
- **No existing caller of `ThumbnailBackfillCoordinator.runBatch`** in Phase 12 — the actor is load-bearing for Phase 13 but dormant in Phase 12. Unit tests construct it with mocks; production code doesn't.
- **`DS3Drive` struct** (in DS3Lib Models) is already Sendable and carries bucket + prefix + driveId — the coordinator's init accepts one directly.
- **`MetadataStore` is an `@ModelActor`** with its own isolation domain — the coordinator actor calls into it via `await` without shared state.
- **Existing `FileProviderExtension+Thumbnails.swift:157-249`** `fetchThumbnails` fallback updates its call to use `ThumbnailRenderer` directly. One call-site change, no behavior change (Phase 13 rewrites the whole consumer anyway).

### Constraints
- **Swift 6 strict concurrency** is enabled on DS3Lib. Per `MEMORY.md`, `Schema.Version` is NOT `Sendable` — Phase 12's V3 `versionIdentifier` must use `nonisolated static let` exactly as V1 and V2 do. This is a known CI-vs-local Xcode stricter-on-CI footgun.
- **macOS 14+ / iOS 17+** — all Phase 12 APIs are available on both minima. `os_proc_available_memory()` already used in Phase 11's guard.
- **App Group identifier** — `group.X889956QSM.io.cubbit.DS3Drive`. `SharedData.coordinatedWrite` already knows this; Phase 12 thumbnail settings JSON rides the existing container.
- **SwiftLint file-length** — the existing `SyncedItem.swift` is ~200 lines; adding V3 pushes it closer to the limit. If it crosses, split V3 into `SyncedItemSchemaV3.swift` per the "Claude's Discretion" hint. `FileProviderExtension+Thumbnails.swift` is already at the limit per memory — Phase 12 only removes one generator call, doesn't add.
- **Git LFS** — any new fixtures must be `git lfs track`'d. Phase 12 does not add new fixtures; it reuses Phase 11's.
- **NEVER return custom error types to the File Provider system** (per `MEMORY.md`) — Phase 12 ships errors at the DS3Lib layer (raw Soto / Swift errors) which is below the File Provider boundary. Phase 13 wraps at the boundary. No domain remapping in Phase 12.

</code_context>

<specifics>
## Specific Ideas

- **Phase 12's raison d'être** is "make Phase 13 a wiring exercise, not an extraction exercise." Every decision above chooses the shape Phase 13 will consume over the shape that reads cleanest in Phase 12 isolation. Example: `putThumbnail(sourceETag: String)` is required-non-optional because Phase 13's upload hook has the source ETag in hand and should never be able to ship an unclassified thumbnail.
- **THUMB-07 is enforced at compile time**, not runtime. The whole-type `#if os(macOS)` gate is load-bearing for the success criterion. A runtime guard would pass unit tests but fail the phase contract.
- **Migration is lightweight, period.** No custom content-type classification during migration. Any classification runs at query time or via explicit `setThumbnailStatus` calls. This keeps the V2→V3 upgrade a no-op for existing users with large metadata stores.
- **`ThumbnailSettings.enabled` defaults to `false` everywhere**, including on existing drives upgrading to V3. Phase 12 is a silent payload; Phase 13 owns the rollout switch.
- **Phase 11's "Use anyway" collision override is explicitly NOT persisted in `ThumbnailSettings`.** Re-consent on feature-enable is intentional — it's a one-per-bucket-lifetime decision, not a feature-flag semantic.
- **The coordinator is a scaffold, not a black box.** `runBatch` is fully runnable end-to-end in Phase 12 — unit tests exercise the happy path with mocks. But no production caller wires into it. Phase 13 flips `ThumbnailSettings.enabled = true`, adds the BFS hook, adds the upload hook, and the scaffold wakes up.
- **Cross-platform coordinator is deliberate.** STACK.md §Platform Patterns argues one shared type. Phase 12 ships a type that compiles on iOS (so Phase 14 can extend it) but only runs the render step on macOS. Phase 14 adds an iOS render path if iOS native decode proves viable, or a "delegate render to main app via IPC" path otherwise. Keeping the type cross-platform now avoids a Phase-14 refactor.
- **Test strategy mirrors existing discipline.** Every new API in DS3Lib ships with a test file in DS3LibTests, using `DS3S3Client+Protocol` mocks and seeded SwiftData containers. No real-S3 integration tests in Phase 12.

</specifics>

<deferred>
## Deferred Ideas

- **Cache-first `fetchThumbnails` rewrite** — Phase 13. Phase 12 only points the existing consumer at `ThumbnailRenderer`.
- **Upload-path hook (`UploadThumbnailHook`)** — Phase 13.
- **Cascade hooks (delete/rename/move)** — Phase 13.
- **Orphan sweep** — Phase 13. If Phase 13 decides it needs `headThumbnail`, add then.
- **BFS backfill invocation (calling `runBatch` from the indexer)** — Phase 13.
- **`ThumbnailFetchLimiter`** — Phase 13.
- **Negative cache / 3-strike rule (THUMB-20)** — Phase 13.
- **Tray progress UI (THUMB-24)** — Phase 13. If Phase 13 needs `countPending(driveId:)`, add it there alongside the UI.
- **iOS `BGProcessingTask` + `ForegroundBackfillDriver`** — Phase 14. May extend `ThumbnailBackfillCoordinator` or wrap it in a driver.
- **Cellular gating + "Generate now" action** — Phase 14. Phase 14 extends `ThumbnailSettings` with the needed fields.
- **iOS settings progress UI** — Phase 14.
- **Parallel renders inside `runBatch`** — Phase 13 or 14 when a concrete caller needs it. Phase 12 scaffold is sequential.
- **EXIF thumbnail fast path (range-GET first ~64 KB)** — deferred beyond v3.1.
- **PNG fallback for line-art / screenshots** — deferred beyond v3.1 (JPEG Q0.7 ringing is a known limitation).
- **Video / PDF / RAW thumbnail support** — out of scope per REQUIREMENTS. Phase 12 deletes the existing video/PDF generators entirely.
- **WebP / AVIF thumbnail format** — deferred beyond v3.1. `DefaultSettings.Thumbnail.formatVersion = 1` is the extension point.
- **`headThumbnail(bucket:key:)` → `ThumbnailHead?`** — not added in Phase 12. Add in Phase 13 if orphan-sweep needs it.
- **`countPending(driveId:)` MetadataStore query** — not added in Phase 12. Add in Phase 13 alongside tray progress UI.

</deferred>

---

*Phase: 12-renderer-storage-schema*
*Context gathered: 2026-04-24*
