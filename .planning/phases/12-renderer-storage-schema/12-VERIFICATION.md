---
phase: 12-renderer-storage-schema
verified: 2026-04-25T11:35:00Z
status: passed
score: 5/5 must-haves verified
overrides_applied: 0
---

# Phase 12: Renderer, Storage & Schema Verification Report

**Phase Goal:** DS3Lib exposes a platform-gated, memory-safe thumbnail renderer, an S3 put/get/delete service with staleness metadata, a Schema V3 migration that tracks per-item thumbnail status, and a scaffolded backfill coordinator — all wired into unit tests but not yet invoked from any user-facing code path.

**Verified:** 2026-04-25T11:35:00Z
**Status:** PASSED
**Re-verification:** No — initial verification

## Goal Achievement

### Observable Truths (ROADMAP Success Criteria)

| #   | Truth   | Status     | Evidence       |
| --- | ------- | ---------- | -------------- |
| 1   | MetadataStore answers "which items still need a thumbnail?" + persists per-item state across restarts + V2→V3 migration succeeds | VERIFIED | `SyncedItemSchemaV3` declared at SyncedItem.swift:198, `thumbnailStatus: String = "pending"` field at line 261, `@Transient public var thumbnail: ThumbnailStatus` accessor at line 264, `migrateV2toV3` lightweight stage at line 313, `typealias SyncedItem = SyncedItemSchemaV3.SyncedItem` at line 321, `MetadataStore.createContainer` binds `Schema(versionedSchema: SyncedItemSchemaV3.self)` at MetadataStore.swift:16. `fetchPendingThumbnails(driveId:limit:)` at MetadataStore+Queries.swift:229 + `setThumbnailStatus` at line 259. `SchemaV3MigrationTests` (3 tests) + `MetadataStoreThumbnailQueriesTests` (7 tests) all green. Migration test seeds V2 store with 3 SyncedItem + 1 SyncAnchorRecord, re-opens as V3, confirms all rows survive with thumbnailStatus == "pending". |
| 2   | `import ThumbnailRenderer` from iOS extension target fails to compile — whole-type `#if os(macOS)` gate | VERIFIED | ThumbnailRenderer.swift:15 has `#if os(macOS)` BEFORE `public struct ThumbnailRenderer` at line 26; `#endif` at line 132 AFTER the closing brace. iOS scheme `xcodebuild -scheme DS3DriveApp -destination 'generic/platform=iOS Simulator' build` → **BUILD SUCCEEDED**. `grep -rn "ThumbnailRenderer" DS3DriveApp/ DS3DriveShareExtension/` returns 0. The macOS extension consumer at FileProviderExtension+Thumbnails.swift:337-351 wraps the call site in `#if os(macOS)` with explicit comment about the compile gate. |
| 3   | Unit tests on Git LFS fixtures prove right-side-up JPEGs for portrait EXIF-6 photos + nil for unsupported formats | VERIFIED | `ThumbnailRendererTests` (4 tests) green: `testRenderJPEGAppliesEXIF6RotationToPortraitOutput` (HEIC + JPEG), `testRenderJPEGRejectsPDFByUTIAllowList`, `testRenderJPEGRepeatedInvocationsReturnNonNil`, `testRenderJPEGDefaultInitProducesValidJPEG`. Bundle.module loading of fixtures verified. Fixtures present: exif6-portrait.heic, exif6-portrait.jpg, large-test.png, unsupported.pdf at `DS3Lib/Tests/DS3LibTests/Fixtures/`. `kCGImageSourceCreateThumbnailWithTransform: true` confirmed at ThumbnailRenderer.swift:81 (load-bearing for EXIF). All 4 ImageIO memory-safety flags present (lines 64, 79, 81, 82). Old PDF/video generators deleted. |
| 4   | `ThumbnailS3Service.put` writes both `x-amz-meta-source-etag` + `x-amz-meta-ds3drive-thumb-version` on every PUT (single-part) — verified via mock S3 tests | VERIFIED | DS3S3Client+Thumbnails.swift:42-45 constructs metadata dict using `DefaultSettings.Thumbnail.sourceETagMetadataKey` and `DefaultSettings.Thumbnail.formatVersionMetadataKey`. Bare keys in DefaultSettings.swift:236 (`"source-etag"`) and :241 (`"ds3drive-thumb-version"`). Single-part precondition at ThumbnailRenderer.swift:40 (`precondition(data.count < DefaultSettings.Thumbnail.maxSinglePartBytes, ...)`). `putThumbnail` lives on `public extension DS3S3ClientProtocol` at line 14 — not on concrete class. `DS3S3ClientThumbnailsTests` (9 tests) green: bare-key metadata, normalized ETag, size-cap, get 200/404/5xx, delete 204/404/5xx. The 3 `x-amz-meta-` matches in the codebase are doc comments only — no header-prefix literals in code. |
| 5   | `SharedData+thumbnailSettings` round-trips `enabled` flag across App Group + `ThumbnailBackfillCoordinator` actor exists with runnable batch entry point | VERIFIED | `ThumbnailSettings { enabled: Bool = false }` at SharedData+thumbnailSettings.swift:12-20 with default `false` at init AND fallback (`return ThumbnailSettings()` at line 31, 34). `loadThumbnailSettings(forDrive:)` and `saveThumbnailSettings(forDrive:settings:)` round-trip via `coordinatedRead`/`coordinatedWrite` (same machinery as trashSettings). `SharedDataThumbnailSettingsTests` (12 tests) green: default-disabled, round-trip, multi-drive isolation, missing-drive fallback, 50-cycle persistence. `ThumbnailBackfillCoordinator` public actor declared at ThumbnailBackfillCoordinator.swift:23 (NOT `@ModelActor`), cross-platform shell with `#if os(macOS)` only on render branch (line 139), `BatchResult` struct with `processed/succeeded/skipped/failed` (lines 46-58). `runBatch(maxItems:) async throws -> BatchResult` at line 65 wired end-to-end (fetchPending → getObject → renderJPEG → putThumbnail → setThumbnailStatus). `defer` temp-file cleanup at line 114. `ThumbnailBackfillCoordinatorTests` (2 tests) green: empty store returns zero counts, no S3 calls. `grep -rn "ThumbnailBackfillCoordinator(" DS3DriveProvider/ DS3Drive/ DS3DriveApp/ DS3DriveShareExtension/` returns 0 — scaffold-only as required. |

**Score:** 5/5 truths verified

### Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `DS3Lib/Sources/DS3Lib/Metadata/SyncedItem.swift` | V3 schema + thumbnailStatus + migrateV2toV3 + V3 typealias | VERIFIED | All 4 elements present; V1+V2+V3 schemas coexist; lightweight migration; SyncAnchorRecord typealias to V2 class (avoids re-declaration trap documented in 12-01-SUMMARY) |
| `DS3Lib/Sources/DS3Lib/Metadata/MetadataStore.swift` | V3 container bind | VERIFIED | Line 16: `Schema(versionedSchema: SyncedItemSchemaV3.self)`. Catch-recovery branch inherits V3 |
| `DS3Lib/Sources/DS3Lib/Metadata/MetadataStore+Queries.swift` | PendingThumbnail + fetchPendingThumbnails + setThumbnailStatus | VERIFIED | Lines 207-263. Sendable DTO. Pitfall 5 contract documented in docstring. setThumbnailStatus is no-op on missing row (D-22 satisfied) |
| `DS3Lib/Sources/DS3Lib/Constants/DefaultSettings.swift` | Thumbnail namespace + thumbnailSettingsFileName | VERIFIED | Lines 220-247: 4 constants with bare metadata keys + Pitfall 2 doc. Line 160: filename constant |
| `DS3Lib/Sources/DS3Lib/SharedData/SharedData+thumbnailSettings.swift` | ThumbnailSettings + load/save | VERIFIED | 65 lines, exact 1:1 mirror of SharedData+trashSettings. Default `enabled = false` at init + fallback (D-24 satisfied) |
| `DS3Lib/Sources/DS3Lib/DS3S3Client+Thumbnails.swift` | put/get/delete on protocol extension | VERIFIED | 86 lines. `public extension DS3S3ClientProtocol` (NOT concrete class — D-08 satisfied). Bare metadata keys. precondition for size cap. 404 → nil for get, 404 → silent for delete |
| `DS3Lib/Sources/DS3Lib/DS3S3ClientProtocol.swift` | putObjectData(metadata:) + getObjectData | VERIFIED | Lines 44, 58-63. Default extension at lines 93-103 forwards 3-arg overload to 4-arg with `metadata: nil` (backward-compat) |
| `DS3Lib/Sources/DS3Lib/Thumbnails/ThumbnailRenderer.swift` | macOS-only struct with renderJPEG | VERIFIED | 132 lines. `#if os(macOS)` at line 15 wraps entire `public struct ThumbnailRenderer` (line 26) through `#endif` at line 132. All 4 ImageIO flags + autoreleasepool + UTI allow-list + memory guard intact (verbatim Phase 11 extraction) |
| `DS3Lib/Sources/DS3Lib/Thumbnails/ThumbnailBackfillCoordinator.swift` | Public actor with runBatch | VERIFIED | 199 lines. Cross-platform shell. `BatchResult { processed, succeeded, skipped, failed }`. `runBatch(maxItems:)` end-to-end wired. defer temp-file cleanup. iOS placeholder branch marks .failed (Phase 14 extends) |
| `DS3Lib/Tests/DS3LibTests/SchemaV3MigrationTests.swift` | V2→V3 migration + SyncAnchorRecord survival proof | VERIFIED | 3 tests, all green. `testV2ToV3LightweightMigrationPreservesRowsAndDefaultsThumbnailStatus` proves rows survive with default. |
| `DS3Lib/Tests/DS3LibTests/MetadataStoreThumbnailQueriesTests.swift` | Query surface tests | VERIFIED | 7 tests, all green. Covers driveId/limit/raster-filter/transition semantics |
| `DS3Lib/Tests/DS3LibTests/SharedDataThumbnailSettingsTests.swift` | Round-trip + default + Pitfall 2 guards | VERIFIED | 12 tests, all green. |
| `DS3Lib/Tests/DS3LibTests/DS3S3ClientThumbnailsTests.swift` | put/get/delete branch coverage | VERIFIED | 9 tests, all green. Includes bare-key metadata assertion. |
| `DS3Lib/Tests/DS3LibTests/ThumbnailRendererTests.swift` | EXIF + unsupported format coverage via Bundle.module | VERIFIED | 4 tests, all green. EXIF-6 portrait HEIC, EXIF-6 portrait JPEG, PDF rejection, default init smoke. |
| `DS3Lib/Tests/DS3LibTests/ThumbnailBackfillCoordinatorTests.swift` | Scaffold smoke test | VERIFIED | 2 tests, all green. |

### Key Link Verification

| From | To  | Via | Status | Details |
|------|-----|-----|--------|---------|
| MetadataStore.createContainer() | SyncedItemSchemaV3 | `Schema(versionedSchema: SyncedItemSchemaV3.self)` | WIRED | MetadataStore.swift:16 |
| SyncedItemMigrationPlan.stages | migrateV2toV3 | `MigrationStage.lightweight(fromVersion: V2.self, toVersion: V3.self)` | WIRED | SyncedItem.swift:298, 313 |
| typealias SyncedItem | SyncedItemSchemaV3.SyncedItem | `public typealias` | WIRED | SyncedItem.swift:321 |
| FileProviderExtension+Thumbnails.swift:337-351 | DS3Lib.ThumbnailRenderer | `renderer.renderJPEG(from: fileURL)` wrapped in `#if os(macOS)` | WIRED | Consumer rewrite landed; iOS branch returns nil cleanly |
| ThumbnailRendererTests.swift | Fixtures/ | `Bundle.module.url(forResource:withExtension:)` | WIRED | All 4 tests load fixtures via Bundle.module |
| DS3S3Client+Thumbnails.swift | DefaultSettings.Thumbnail.* | constant references in metadata dict + precondition | WIRED | Lines 38-44 |
| ThumbnailBackfillCoordinator.runBatch | MetadataStore.fetchPendingThumbnails / setThumbnailStatus | `await metadataStore.fetchPendingThumbnails / setThumbnailStatus` | WIRED | Lines 66, 128, 151, 178, 193 |
| ThumbnailBackfillCoordinator (#if os(macOS) branch) | ThumbnailRenderer | `ThumbnailRenderer()` lazy instantiation | WIRED | Line 146 |
| ThumbnailBackfillCoordinator | DS3S3ClientProtocol.putThumbnail / getObject | `await s3Client.putThumbnail / getObject(toFile:)` | WIRED | Lines 121, 162 |

### Behavioral Spot-Checks

| Behavior | Command | Result | Status |
|----------|---------|--------|--------|
| DS3Lib package builds | `swift build --package-path DS3Lib` | "Build complete! (7.25s)" | PASS |
| Full DS3Lib test suite green | `swift test --package-path DS3Lib` | 500 tests, 31 skipped, 0 failures | PASS |
| iOS scheme builds (THUMB-07 compile gate) | `xcodebuild ... -scheme DS3DriveApp -destination 'generic/platform=iOS Simulator' build` | `** BUILD SUCCEEDED **` | PASS |
| macOS scheme builds (consumer rewrite) | `xcodebuild ... -scheme DS3Drive -destination 'platform=macOS' build` | `** BUILD SUCCEEDED **` (with note about removed stale generator .o files) | PASS |
| No `x-amz-meta-` literals in code | `grep -n "x-amz-meta-" DS3S3Client+Thumbnails.swift DefaultSettings.swift` | 3 matches, all in /// doc comments referring to Pitfall 2 — no code literals | PASS |
| iOS gate is whole-type | `grep -n "^#if os(macOS)\|^public struct ThumbnailRenderer\|^#endif" ThumbnailRenderer.swift` | `#if os(macOS)` at L15, struct at L26, `#endif` at L132 — gate wraps entire type | PASS |
| Both V2 + V3 list both models | `grep -c "[SyncedItem.self, SyncAnchorRecord.self]"` | 2 (V2 line 67 + V3 line 201) | PASS |
| Lightweight migration | `grep -c "MigrationStage.lightweight"` | 2 (V1→V2 + V2→V3) | PASS |
| typealias bumped to V3 | `grep "typealias SyncedItem = "` | `public typealias SyncedItem = SyncedItemSchemaV3.SyncedItem` | PASS |
| Old generator file deleted | `test ! -f DS3DriveProvider/FileProviderExtension+ThumbnailGenerators.swift` | OK_GENERATOR_DELETED | PASS |
| Old test file deleted | `test ! -f DS3DriveProviderTests/ThumbnailGeneratorTests.swift` | OK_TEST_RELOCATED | PASS |
| pbxproj cleaned | `grep -c "ThumbnailGeneratorTests" DS3Drive.xcodeproj/project.pbxproj` | 0 | PASS |
| No production caller of coordinator | `grep -rn "ThumbnailBackfillCoordinator(" DS3DriveProvider/ DS3Drive/ DS3DriveApp/ DS3DriveShareExtension/` | 0 | PASS |
| iOS targets cannot reference renderer | `grep -rn "ThumbnailRenderer" DS3DriveApp/ DS3DriveShareExtension/` | 0 | PASS |
| All 5 SUMMARY files present | `ls .planning/phases/12-renderer-storage-schema/12-0*-SUMMARY.md \| wc -l` | 5 | PASS |
| Test fixtures present | `ls DS3Lib/Tests/DS3LibTests/Fixtures/` | exif6-portrait.heic, exif6-portrait.jpg, large-test.png, unsupported.pdf | PASS |

### Requirements Coverage

| Requirement | Source Plan | Description | Status | Evidence |
|-------------|-------------|-------------|--------|----------|
| THUMB-04 | 12-01-PLAN | SyncedItem tracks per-item thumbnail status via Schema V3 migration | SATISFIED | `thumbnailStatus: String` field on V3, `@Transient thumbnail: ThumbnailStatus` accessor, lightweight V2→V3 migration. SchemaV3MigrationTests prove migration preserves rows + defaults `pending`. |
| THUMB-07 | 12-04-PLAN | iOS extension is strictly consume-only — `#if os(macOS)` gates on generator type | SATISFIED | Whole-type gate at ThumbnailRenderer.swift:15-132. iOS build succeeds without the type. Consumer call site at FileProviderExtension+Thumbnails.swift:337-351 wraps renderer reference in `#if os(macOS)`. |
| THUMB-08 | 12-04-PLAN | Generator applies EXIF orientation correctly | SATISFIED | `kCGImageSourceCreateThumbnailWithTransform: true` at ThumbnailRenderer.swift:81. `testRenderJPEGAppliesEXIF6RotationToPortraitOutput` proves portrait HEIC + JPEG produce height>width. |
| THUMB-09 | 12-04-PLAN | Generator supports raster formats; unsupported silently skipped | SATISFIED | Allow-list at ThumbnailRenderer.swift:115-123 (jpeg/png/heic/heif/webp/gif/tiff). `testRenderJPEGRejectsPDFByUTIAllowList` proves PDF returns nil silently. |
| THUMB-10 | 12-03-PLAN | Thumbnail PUT is single-part with `x-amz-meta-source-etag` + `x-amz-meta-ds3drive-thumb-version` | SATISFIED | `putThumbnail` at DS3S3Client+Thumbnails.swift:32-51 always writes both metadata headers. precondition enforces single-part. `testPutThumbnailIssuesBareMetadataKeys` asserts BARE keys in mock-recorded dict. |

**All 5 phase requirements SATISFIED. No orphans (REQUIREMENTS.md maps exactly THUMB-04, 07, 08, 09, 10 to Phase 12).**

### Anti-Patterns Found

None blocking. The grep audit produced:
- 3 occurrences of `x-amz-meta-` — all in `///` doc comments documenting Pitfall 2 (intentional; Soto auto-prepends the prefix; bare keys in code are correct).
- One commit (`b823329 docs(12-01)`) shows GPG signature `N` instead of `G`. This is a doc-only commit; user instructions ("Always sign commits when possible") are honored on all 19 of 20 commits. No code change is unsigned. INFO-level only.

### Human Verification Required

None for this phase. Per ROADMAP.md, Phase 12 is "scaffolded but not invoked from any user-facing code path" — the explicit acceptance criterion `grep -rn "ThumbnailBackfillCoordinator(" DS3Drive...` returns 0, and no UI is added in Phase 12. There is therefore nothing for a human to "see"; all goals are testable programmatically and have been programmatically verified above. Phase 13 is the first user-visible thumbnails phase and will require human verification at that point.

### Gaps Summary

No gaps. All 5 ROADMAP success criteria are satisfied with primary evidence in the codebase, all 5 requirements are satisfied with traceable test coverage, all 19 plan-required artifacts exist with substantive content (no stubs), all key wiring links are present, both Xcode schemes build, and the full DS3Lib test suite is 500 tests green / 0 failures. The Phase 12 scope guard (no production caller of `ThumbnailBackfillCoordinator`) is enforced by grep returning 0. The "silent payload" contract is honored — `ThumbnailSettings.enabled` defaults to `false` at both init and fallback, and there is no UI flipping it in this phase.

The plan execution exhibited disciplined deviation handling (e.g., 12-01 SUMMARY documents the SwiftData re-declaration trap on `SyncAnchorRecord` and the typealias-based fix that satisfies Pitfall 3's intent without the runtime crash). The auto-fix is documented and tested.

---

_Verified: 2026-04-25T11:35:00Z_
_Verifier: Claude (gsd-verifier)_
