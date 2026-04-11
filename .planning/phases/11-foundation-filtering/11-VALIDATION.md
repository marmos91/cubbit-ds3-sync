---
phase: 11
slug: foundation-filtering
status: draft
nyquist_compliant: false
wave_0_complete: false
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
| 11-01-01 | 01 | 0 | THUMB-05 | — | N/A | unit | `swift test --package-path DS3Lib --filter DefaultSettingsThumbnailTests` | ❌ W0 | ⬜ pending |
| 11-01-02 | 01 | 0 | THUMB-03 | — | N/A | unit | `swift test --package-path DS3Lib --filter S3PathUtilsTests` | ❌ W0 | ⬜ pending |
| 11-01-03 | 01 | 0 | THUMB-01 | — | N/A | unit | `swift test --package-path DS3Lib --filter S3KeyFilterTests` | ❌ W0 | ⬜ pending |
| 11-02-01 | 02 | 1 | THUMB-01 | T-11-01 | `.thumbnails/` keys never reach observer/MetadataStore | unit | `swift test --package-path DS3Lib --filter S3KeyFilterTests` | ❌ W0 | ⬜ pending |
| 11-02-02 | 02 | 1 | THUMB-01 | — | N/A | unit | `swift test --package-path DS3Lib --filter S3KeyFilterTests.testUserVisibleEdgeCases` | ❌ W0 | ⬜ pending |
| 11-03-01 | 03 | 1 | THUMB-02 | T-11-02 | Structural check rejects foreign `.thumbnails/` content | unit (mocked) | `swift test --package-path DS3Lib --filter InspectThumbnailPrefixTests` | ❌ W0 | ⬜ pending |
| 11-03-02 | 03 | 1 | THUMB-02 | T-11-03 | Log collision keys with privacy: .private | unit (mocked) | `swift test --package-path DS3Lib --filter InspectThumbnailPrefixTests` | ❌ W0 | ⬜ pending |
| 11-04-01 | 04 | 2 | THUMB-02 | — | Wizard blocks on `.conflicting` | manual | Manual UI test — exercise wizard against seeded bucket | N/A | ⬜ pending |
| 11-05-01 | 05 | 2 | (D-19) | T-11-04 | UTI check rejects filename-spoofed files | unit w/ fixture | `xcodebuild ... -only-testing:DS3DriveProviderTests/ThumbnailGeneratorTests` | ❌ W0 | ⬜ pending |
| 11-05-02 | 05 | 2 | (D-19) | T-11-05 | autoreleasepool prevents memory leak | unit w/ fixture | same target | ❌ W0 | ⬜ pending |
| 11-05-03 | 05 | 2 | (D-19) | — | EXIF-6 orientation preserved | unit w/ fixture | same target | ❌ W0 | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] `DS3Lib/Tests/DS3LibTests/S3KeyFilterTests.swift` — stubs for THUMB-01 filter table
- [ ] `DS3Lib/Tests/DS3LibTests/InspectThumbnailPrefixTests.swift` — stubs for THUMB-02 branches
- [ ] `DS3Lib/Tests/DS3LibTests/Fixtures/` directory — create with LFS-tracked binary fixtures
- [ ] `DS3Lib/Package.swift` — add `resources: [.process("Fixtures")]` to testTarget
- [ ] `.gitattributes` — add LFS tracking for `*.heic`, `*.jpg`, `*.png` in test fixtures
- [ ] New Xcode `DS3DriveProviderTests` test target — for generator hardening tests

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Wizard collision warning screen appears on `.conflicting` | THUMB-02 | UI interaction on both macOS + iOS; no headless UI test infra | 1. Seed bucket with non-DS3Drive `.thumbnails/` object. 2. Run setup wizard to confirm step. 3. Verify blocking warning appears. 4. Verify "Use anyway" proceeds. 5. Verify clean bucket proceeds silently. |
| `.thumbnails/` folder invisible in Finder sidebar | THUMB-01 | File Provider enumeration is end-to-end through `fileproviderd` | 1. Add drive with `.thumbnails/` objects in bucket. 2. Browse in Finder. 3. Confirm no `.thumbnails/` folder visible. |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 60s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
