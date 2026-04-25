---
phase: 12
slug: renderer-storage-schema
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-04-24
---

# Phase 12 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | XCTest (Swift 6 language mode) |
| **Config file** | `DS3Lib/Package.swift` testTarget declaration; `DS3Drive.xcodeproj` XCTest test plans |
| **Quick run command** | `swift test --package-path DS3Lib --filter <TestClassName>` |
| **Full suite command** | `swift test --package-path DS3Lib` |
| **Xcode-side full suite** | `xcodebuild -project DS3Drive.xcodeproj -scheme DS3Drive test -destination 'platform=macOS'` |
| **Estimated runtime** | ~45s DS3Lib full suite; ~3min Xcode scheme full |

---

## Sampling Rate

- **After every task commit:** Run the targeted `--filter` command for the class(es) touched
- **After every plan wave:** Run `swift test --package-path DS3Lib` (DS3Lib full suite)
- **Before `/gsd-verify-work`:** Full DS3Lib suite green + macOS scheme builds + iOS scheme builds
- **Max feedback latency:** ~45 seconds for DS3Lib full suite

---

## Validation Dimensions (8)

See `12-RESEARCH.md §Validation Architecture` for authoritative detail. Summary:

| # | Dimension | Requirement | Test Class | Command |
|---|-----------|-------------|------------|---------|
| 1 | Renderer correctness | THUMB-08, THUMB-09 | `ThumbnailRendererTests` | `swift test --package-path DS3Lib --filter ThumbnailRendererTests` |
| 2 | Schema V2→V3 migration | THUMB-04 | `SchemaV3MigrationTests` | `swift test --package-path DS3Lib --filter SchemaV3MigrationTests` |
| 3 | S3 PUT/GET/DELETE semantics | THUMB-10 | `DS3S3Client+ThumbnailsTests` | `swift test --package-path DS3Lib --filter DS3S3Client` |
| 4 | SharedData+thumbnailSettings round-trip | D-38 | `SharedData+thumbnailSettingsTests` | `swift test --package-path DS3Lib --filter SharedData` |
| 5 | Coordinator scaffold smoke | D-39 | `ThumbnailBackfillCoordinatorTests` | `swift test --package-path DS3Lib --filter ThumbnailBackfillCoordinator` |
| 6 | iOS `#if os(macOS)` compile gate | THUMB-07 | CI step + grep | `xcodebuild -scheme DS3DriveApp build -destination 'platform=iOS Simulator'` + `grep -B1 "public struct ThumbnailRenderer"` |
| 7 | Test target relocation | D-07 | Verify pbxproj + file presence | `grep -c "ThumbnailGeneratorTests" DS3DriveProvider.xcodeproj/project.pbxproj` == 0 |
| 8 | Nyquist validation of the above | — | Auditor reviews this file | `/gsd-validate-phase 12` |

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Threat Ref | Secure Behavior | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|------------|-----------------|-----------|-------------------|-------------|--------|
| *To be populated by planner in step 8* | | | | | | | | | ⬜ pending |

---

## Wave 0 Requirements

- [ ] `DS3Lib/Tests/DS3LibTests/ThumbnailRendererTests.swift` — new test class (moved from `DS3DriveProviderTests/ThumbnailGeneratorTests.swift`)
- [ ] `DS3Lib/Tests/DS3LibTests/SchemaV3MigrationTests.swift` — new file (mirrors `MetadataStoreMigrationTests.swift` structure)
- [ ] `DS3Lib/Tests/DS3LibTests/DS3S3Client+ThumbnailsTests.swift` — new file
- [ ] `DS3Lib/Tests/DS3LibTests/SharedData+thumbnailSettingsTests.swift` — new file
- [ ] `DS3Lib/Tests/DS3LibTests/ThumbnailBackfillCoordinatorTests.swift` — new file (scaffold-only)

Git LFS fixtures already exist at `DS3Lib/Tests/DS3LibTests/Fixtures/` per research D-07 verification; `Package.swift:30` declares `resources: [.process("Fixtures")]`. No Wave 0 fixture ingestion needed.

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| iOS build still produces a distributable DS3DriveApp despite `ThumbnailRenderer` not existing on iOS | THUMB-07 | Xcode scheme build with iOS destination; no automated harness proves "extension target cannot accidentally import" better than the build itself | Run `xcodebuild -scheme DS3DriveApp -destination 'platform=iOS Simulator,name=iPhone 15' build` locally before the verification step; confirm clean build |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 45s for DS3Lib full suite
- [ ] `nyquist_compliant: true` set in frontmatter after planner populates per-task map

**Approval:** pending
