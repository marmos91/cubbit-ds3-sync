---
phase: 12-renderer-storage-schema
plan: 04
subsystem: imaging
tags: [imageio, exif, swift, dslib, fileprovider]

requires:
  - phase: 11-foundation-filtering
    provides: hardened generateImageThumbnail (all 4 ImageIO flags + autoreleasepool + UTI allow-list + os_proc_available_memory guard); 4 Git LFS fixtures (HEIC/JPEG EXIF-6, large PNG, unsupported PDF) already at DS3Lib/Tests/DS3LibTests/Fixtures/
  - phase: 12-02
    provides: DefaultSettings.S3.thumbnailMaxDimension and thumbnailJPEGQuality remain available for renderer init defaults
provides:
  - public struct ThumbnailRenderer in DS3Lib/Sources/DS3Lib/Thumbnails/ — macOS-only via whole-type #if os(macOS) gate
  - renderJPEG(from:) public API consumed by Phase 13's upload hook + Phase 12-05's coordinator scaffold
  - ThumbnailRendererTests in DS3LibTests with all 4 fixtures (relocated from DS3DriveProviderTests)
  - Clean consumer call site in FileProviderExtension+Thumbnails.swift
affects: [phase 13 (UploadThumbnailHook + fetchThumbnails rewrite), phase 14 (iOS coordinator render path)]

tech-stack:
  added: []  # ImageIO already linked
  patterns:
    - "Whole-type `#if os(macOS)` gate on ThumbnailRenderer (THUMB-07 — compile-time unrepresentable on iOS, not runtime guard)"
    - "Struct-with-init renderer (vs enum-of-statics) — config (maxDimension, jpegQuality) injectable for future iOS overnight backfill knobs"
    - "Test target relocation pattern: DS3DriveProviderTests Resources move into DS3Lib/Tests/DS3LibTests/Fixtures via SPM `.process(\"Fixtures\")` declaration; pbxproj surgery removes BuildFile/FileReference/Resources/Sources entries cleanly"
    - "Consumer-side `#if os(macOS)` wraps the renderer call site so the iOS extension compiles even when the renderer type does not exist"

key-files:
  created:
    - DS3Lib/Sources/DS3Lib/Thumbnails/ThumbnailRenderer.swift
    - DS3Lib/Tests/DS3LibTests/ThumbnailRendererTests.swift
  modified:
    - DS3DriveProvider/FileProviderExtension+Thumbnails.swift
    - DS3Drive.xcodeproj/project.pbxproj
  deleted:
    - DS3DriveProvider/FileProviderExtension+ThumbnailGenerators.swift
    - DS3DriveProviderTests/ThumbnailGeneratorTests.swift

key-decisions:
  - "Whole-type `#if os(macOS)` gate, not body-level (D-03 / Pitfall 4) — guarantees THUMB-07 'fails to compile' contract; runtime guard would pass tests but fail success criterion #2"
  - "Verbatim extraction (D-04) — generateImageThumbnail body lifted with all 4 ImageIO flags + autoreleasepool + UTI allow-list + os_proc_available_memory guard intact; no logic rewrite"
  - "Video and PDF generators DELETED entirely (D-05) — v3.1 is raster-only per THUMB-09; not moved, not deprecated"
  - "Old extension file deleted, no shim retained (D-06) — Phase 13 inherits clean call site"
  - "Tests relocated to DS3LibTests as ThumbnailRendererTests; fixtures already on disk under SPM `.process(\"Fixtures\")` per Phase 11 D-07 verification"
  - "Consumer call site rewritten to `ThumbnailRenderer().renderJPEG(from:)` wrapped in `#if os(macOS)` — iOS branch returns nil without linking ImageIO"

patterns-established:
  - "Macros-free SPM resource bundling for Swift tests via `.process(\"Fixtures\")` — fixtures co-located with DS3LibTests; loaded via Bundle.module in tests"
  - "Pbxproj surgery checklist: PBXBuildFile + PBXFileReference + PBXGroup children + PBXResourcesBuildPhase + PBXSourcesBuildPhase entries must all be removed for clean test target removal (Pitfall 6)"

requirements-completed: [THUMB-07, THUMB-08, THUMB-09]

duration: ~22min
completed: 2026-04-25
---

# Phase 12-04: ThumbnailRenderer Extraction Summary

**Phase 11's hardened image generator extracted verbatim into DS3Lib as a macOS-only public struct, video/PDF generators dropped, consumer rewired, tests relocated to DS3LibTests, pbxproj scrubbed — iOS scheme proves the renderer is compile-time unrepresentable in the iOS File Provider extension.**

## Performance

- **Duration:** ~22 minutes
- **Tasks:** 2/2
- **Files created:** 2
- **Files modified:** 2
- **Files deleted:** 2
- **Tests:** ThumbnailRendererTests 4/4 pass; iOS + macOS xcodebuild scheme builds succeed

## Accomplishments

- **`public struct ThumbnailRenderer`** at `DS3Lib/Sources/DS3Lib/Thumbnails/ThumbnailRenderer.swift` — entire type wrapped in `#if os(macOS)`. Importing it from the iOS File Provider extension target fails to compile (THUMB-07 success-criterion verified by `xcodebuild -scheme DS3DriveApp -destination 'generic/platform=iOS Simulator' build` succeeding without the type linked).
- **Verbatim extraction** of Phase 11's hardened generator: all 4 ImageIO flags (`kCGImageSourceShouldCache: false`, `kCGImageSourceCreateThumbnailFromImageAlways: true`, `kCGImageSourceCreateThumbnailWithTransform: true`, `kCGImageSourceShouldCacheImmediately: true`), the `autoreleasepool`, the `CGImageSourceGetType` raster allow-list (jpg/jpeg/png/heic/heif/webp/gif/tiff), and the `os_proc_available_memory()` guard. Zero logic rewrite — the move is mechanical.
- **`generateVideoThumbnail` and `generatePDFThumbnail` deleted** — out of v3.1 scope per THUMB-09. Not moved, not deprecated.
- **Tests relocated** to `DS3Lib/Tests/DS3LibTests/ThumbnailRendererTests.swift`. All 4 LFS fixtures (HEIC-EXIF-6 portrait, JPEG-EXIF-6 portrait, large PNG, unsupported PDF) already lived under `DS3Lib/Tests/DS3LibTests/Fixtures/` from Phase 11; `Bundle.module` loads them.
- **Pbxproj surgery clean:** 6 PBXBuildFile + 6 PBXFileReference + DS3DriveProviderTests group children + Resources build phase + both Sources build phase entries removed. `grep -c "ThumbnailGeneratorTests" project.pbxproj == 0` and `grep -c "FileProviderExtension+ThumbnailGenerators" project.pbxproj == 0`.
- **Consumer rewritten** at `FileProviderExtension+Thumbnails.swift:337-355`: replaced the static `FileProviderExtension.generateImageThumbnail` call with `ThumbnailRenderer().renderJPEG(from:)`, wrapped in `#if os(macOS)`. The iOS branch returns `nil` without linking ImageIO. `import ImageIO` removed from the consumer.
- **Build self-checks:**
  - `xcodebuild -project DS3Drive.xcodeproj -scheme DS3Drive -destination 'platform=macOS' build` — **BUILD SUCCEEDED**
  - `xcodebuild -project DS3Drive.xcodeproj -scheme DS3DriveApp -destination 'generic/platform=iOS Simulator' build` — **BUILD SUCCEEDED**
  - `swift test --package-path DS3Lib --filter ThumbnailRendererTests` — 4/4 pass
- **Caller audit clean:** `grep -rn "generateImageThumbnail\|generateVideoThumbnail\|generatePDFThumbnail" DS3DriveProvider/ DS3Drive/ DS3DriveApp/` returns 0 matches. No orphan callers.

## Task Commits

1. **Task 1 — extract ThumbnailRenderer + relocate tests** — `76e094a`
2. **Task 2 — wire consumer + delete old generators + pbxproj cleanup** — `ac17dbe`

## Files Created/Modified

- `DS3Lib/Sources/DS3Lib/Thumbnails/ThumbnailRenderer.swift` — public struct with `init(maxDimension:jpegQuality:)` and `renderJPEG(from:) -> Data?`; entire type wrapped in `#if os(macOS) ... #endif`.
- `DS3Lib/Tests/DS3LibTests/ThumbnailRendererTests.swift` — 4 fixture-driven tests (EXIF-6 portrait HEIC, EXIF-6 portrait JPEG, large PNG, unsupported PDF returns nil); `Bundle.module` for fixture loading.
- `DS3DriveProvider/FileProviderExtension+Thumbnails.swift` — consumer at lines 337-355 calls `ThumbnailRenderer().renderJPEG(from:)`; `#if os(macOS)` wraps the call; `import ImageIO` removed.
- `DS3Drive.xcodeproj/project.pbxproj` — removed all references to deleted test file and 4 fixtures; removed reference to deleted generator file.
- `DS3DriveProvider/FileProviderExtension+ThumbnailGenerators.swift` — DELETED (entire file, including unused video/PDF generators).
- `DS3DriveProviderTests/ThumbnailGeneratorTests.swift` — DELETED (relocated as ThumbnailRendererTests in DS3LibTests).

## Decisions Made

None beyond the locked decisions D-01..D-07. Plan executed exactly as written.

## Deviations from Plan

None — plan executed exactly as written.

## Issues Encountered

- Mid-execution, the 1Password SSH signing agent began refusing operations. Per the parallel-execution contract ("If GPG fails: STOP, write checkpoint, return — do NOT bypass signing silently"), the executor agent halted at the staged Task 2 GREEN state and returned a checkpoint. The user re-approved 1Password and the orchestrator drove the final two commits (Task 2 GREEN + this SUMMARY) on its retry path.

## Next Phase Readiness

- Phase 13's upload-path hook can call `ThumbnailRenderer().renderJPEG(from: tempURL)` directly after a successful PUT.
- Phase 12-05's coordinator scaffold composes this renderer with the S3 service from 12-03 and the MetadataStore queries from 12-01 — all three artifacts are now landed.
- iOS scheme is verified clean; the iOS extension will continue to compile through Phase 13 even as Phase 13's `fetchThumbnails` rewrite extends the consumer-side path.
- THUMB-07's "compile-time unrepresentable" contract is enforced structurally — any future regression that unwraps the `#if os(macOS)` guard will fail iOS scheme builds in CI.

---
*Phase: 12-renderer-storage-schema*
*Completed: 2026-04-25*
