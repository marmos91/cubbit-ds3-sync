---
phase: 11
slug: foundation-filtering
status: validated
nyquist_compliant: true
wave_0_complete: true
created: 2026-04-12
---

# Phase 11 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | XCTest (Swift 6 language mode) |
| **Config file** | `DS3Lib/Package.swift` (testTarget declaration) |
| **Quick run command** | `swift test --package-path DS3Lib --filter <TestClassName>` |
| **Full suite command** | `swift test --package-path DS3Lib` |
| **Xcode extension tests** | `xcodebuild -project DS3Drive.xcodeproj -scheme DS3DriveProviderTests test` |
| **Estimated runtime** | ~30-60s (DS3Lib full suite) |

---

## Sampling Rate

- **After every task commit:** Run `swift test --package-path DS3Lib --filter <ClassName>` (≤5s)
- **After every plan wave:** Run `swift test --package-path DS3Lib` (full suite)
- **Before `/gsd-verify-work`:** Full suite must be green + Xcode DS3DriveProviderTests green
- **Max feedback latency:** 60 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Threat Ref | Secure Behavior | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|------------|-----------------|-----------|-------------------|-------------|--------|
| 11-01-01 | 01 | 0 | THUMB-05 | — | N/A | unit | `swift test --package-path DS3Lib --filter S3PathUtilsTests/testThumbnailsPrefixConstant\|testThumbnailMaxDimensionConstant\|testThumbnailJPEGQualityConstant` | ✅ | ✅ green |
| 11-01-02 | 01 | 0 | THUMB-03 | — | N/A | unit | `swift test --package-path DS3Lib --filter S3PathUtilsTests` | ✅ | ✅ green |
| 11-01-03 | 01 | 0 | THUMB-01 | — | N/A | unit | `swift test --package-path DS3Lib --filter S3KeyFilterTests` | ✅ | ✅ green |
| 11-02-01 | 02 | 1 | THUMB-01 | T-11-01 | `.thumbnails/` keys never reach observer/MetadataStore | unit | `swift test --package-path DS3Lib --filter S3KeyFilterTests` | ✅ | ✅ green |
| 11-02-02 | 02 | 1 | THUMB-01 | — | N/A | unit | `swift test --package-path DS3Lib --filter S3KeyFilterTests.testUserVisibleEdgeCases` | ✅ | ✅ green |
| 11-03-01 | 03 | 1 | THUMB-02 | T-11-02 | Structural check rejects foreign `.thumbnails/` content | unit (mocked) | `swift test --package-path DS3Lib --filter InspectThumbnailPrefixTests` | ✅ | ✅ green |
| 11-03-02 | 03 | 1 | THUMB-02 | T-11-03 | Log collision keys with privacy: .private | unit (mocked) | `swift test --package-path DS3Lib --filter InspectThumbnailPrefixTests` | ✅ | ✅ green |
| 11-04-01 | 04 | 2 | THUMB-02 | — | Wizard blocks on `.conflicting` | manual | Manual UI test — exercise wizard against seeded bucket | N/A | ⬜ pending |
| 11-05-01 | 05 | 2 | (D-19) | T-11-04 | UTI check rejects filename-spoofed files | unit w/ fixture | `xcodebuild -project DS3Drive.xcodeproj -scheme DS3Drive -only-testing:DS3DriveProviderTests/ThumbnailGeneratorTests/testImageThumbnailRejectsPDFByUTIAllowList test -destination 'platform=macOS'` | ✅ | ✅ green |
| 11-05-02 | 05 | 2 | (D-19) | T-11-05 | autoreleasepool prevents memory leak | unit w/ fixture | `xcodebuild -project DS3Drive.xcodeproj -scheme DS3Drive -only-testing:DS3DriveProviderTests/ThumbnailGeneratorTests/testImageThumbnailRepeatedInvocationsReturnNonNil test -destination 'platform=macOS'` | ✅ | ✅ green |
| 11-05-03 | 05 | 2 | (D-19) | — | EXIF-6 orientation preserved | unit w/ fixture | `xcodebuild -project DS3Drive.xcodeproj -scheme DS3Drive -only-testing:DS3DriveProviderTests/ThumbnailGeneratorTests/testImageThumbnailAppliesEXIF6RotationToPortraitOutput test -destination 'platform=macOS'` | ✅ | ✅ green |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [x] `DS3Lib/Tests/DS3LibTests/S3KeyFilterTests.swift` — 12 tests covering THUMB-01 filter table (trash, thumbnail, nested, nil/empty prefix, root)
- [x] `DS3Lib/Tests/DS3LibTests/InspectThumbnailPrefixTests.swift` — 7 tests covering THUMB-02 branches (empty, ours, non-jpg, non-raster, mixed, maxKeys, prefix)
- [x] `DS3Lib/Tests/DS3LibTests/Fixtures/` directory — LFS-tracked fixtures (`exif6-portrait.heic`, `exif6-portrait.jpg`, `large-test.png`, `unsupported.pdf`). Also referenced by the `DS3DriveProviderTests` Xcode target as Resources so `ThumbnailGeneratorTests` can load them via `Bundle(for:).url(forResource:withExtension:)`.
- [x] `DS3Lib/Package.swift` — `resources: [.process("Fixtures")]` on testTarget
- [x] `.gitattributes` — LFS tracking for `*.heic`, `*.jpg`, `*.png` under test fixtures
- [x] Xcode `DS3DriveProviderTests` test target — `DS3DriveProviderTests/ThumbnailGeneratorTests.swift` covers THUMB-05 format allow-list (PDF fixture), autoreleasepool smoke (50 PNG decodes), and EXIF-6 orientation (synthesized at runtime since shipped fixtures lack the orientation tag; see `makeEXIF6LandscapeJPEG`). Generator source file `FileProviderExtension+ThumbnailGenerators.swift` is compiled into the test bundle (no `@testable import DS3DriveProvider` needed; same pattern as existing `S3EnumeratorTests`).

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Wizard collision warning screen appears on `.conflicting` | THUMB-02 | UI interaction on both macOS + iOS; no headless UI test infra | 1. Seed bucket with non-DS3Drive `.thumbnails/` object. 2. Run setup wizard to confirm step. 3. Verify blocking warning appears. 4. Verify "Use anyway" proceeds. 5. Verify clean bucket proceeds silently. |
| `.thumbnails/` folder invisible in Finder sidebar | THUMB-01 | File Provider enumeration is end-to-end through `fileproviderd` | 1. Add drive with `.thumbnails/` objects in bucket. 2. Browse in Finder. 3. Confirm no `.thumbnails/` folder visible. |

---

## Validation Sign-Off

- [x] All tasks have `<automated>` verify or Wave 0 dependencies
- [x] Sampling continuity: no 3 consecutive tasks without automated verify
- [x] Wave 0 covers all MISSING references
- [x] No watch-mode flags
- [x] Feedback latency < 60s
- [x] `nyquist_compliant: true` set in frontmatter

**Approval:** validated 2026-04-24

---

## Validation Audit 2026-04-24

| Metric | Count |
|--------|-------|
| Gaps found | 3 (11-05-01, 11-05-02, 11-05-03) |
| Resolved | 3 |
| Escalated | 0 |

Gaps closed by adding `DS3DriveProviderTests/ThumbnailGeneratorTests.swift` (three tests: UTI allow-list, 50-iter decode loop, EXIF-6 transform). Unblocked the `DS3Drive` scheme by marking `DS3DriveTests/SyncSetupViewModelTests` as `@MainActor` (pre-existing Swift 6 concurrency debt, unrelated to phase 11). All three tests observed passing via `xcodebuild -scheme DS3Drive -only-testing:DS3DriveProviderTests/ThumbnailGeneratorTests`.
