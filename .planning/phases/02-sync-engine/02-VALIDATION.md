---
phase: 2
slug: sync-engine
status: draft
nyquist_compliant: true
wave_0_complete: true
created: 2026-03-12
---

# Phase 2 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | XCTest (Xcode 16+) |
| **Config file** | DS3Lib/Package.swift (testTarget already declared) |
| **Quick run command** | `swift test --package-path DS3Lib` |
| **Full suite command** | `swift test --package-path DS3Lib` |
| **Estimated runtime** | ~15 seconds |

---

## Sampling Rate

- **After every task commit:** Run `swift test --package-path DS3Lib`
- **After every plan wave:** Run `swift test --package-path DS3Lib` + `xcodebuild build -project DS3Drive.xcodeproj -scheme DS3Drive -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`
- **Before `/gsd:verify-work`:** Full suite must be green
- **Max feedback latency:** 30 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|-----------|-------------------|-------------|--------|
| 02-01-01 | 01 | 1 | SYNC-01 | unit | `swift test --package-path DS3Lib --filter MetadataStoreMigrationTests/testSchemaV2HasIsMaterializedField` | Plan 01 T1 creates | pending |
| 02-01-02 | 01 | 1 | SYNC-01 | unit | `swift test --package-path DS3Lib --filter MetadataStoreMigrationTests/testSchemaV2IncludesSyncAnchorRecord` | Plan 01 T1 creates | pending |
| 02-01-03 | 01 | 1 | SYNC-05 | unit | `swift test --package-path DS3Lib --filter MetadataStoreMigrationTests/testMetadataStoreActorIsolation` | Plan 01 T1 creates | pending |
| 02-01-04 | 01 | 1 | SYNC-04 | unit | `swift test --package-path DS3Lib --filter ExponentialBackoffTests/testSucceedsOnFirstAttempt` | Plan 01 T2 creates | pending |
| 02-01-05 | 01 | 1 | SYNC-04 | unit | `swift test --package-path DS3Lib --filter ExponentialBackoffTests/testRetriesOnFailure` | Plan 01 T2 creates | pending |
| 02-01-06 | 01 | 1 | SYNC-04 | unit | `swift test --package-path DS3Lib --filter ExponentialBackoffTests/testThrowsAfterMaxRetries` | Plan 01 T2 creates | pending |
| 02-01-07 | 01 | 1 | SYNC-04 | unit | `swift test --package-path DS3Lib --filter ExponentialBackoffTests/testDelayIncreasesBetweenRetries` | Plan 01 T2 creates | pending |
| 02-02-01 | 02 | 2 | SYNC-04 | unit | `swift test --package-path DS3Lib --filter SyncEngineTests/testDetectsNewItems` | Plan 02 T1 creates | pending |
| 02-02-02 | 02 | 2 | SYNC-04 | unit | `swift test --package-path DS3Lib --filter SyncEngineTests/testDetectsModifiedItems` | Plan 02 T1 creates | pending |
| 02-02-03 | 02 | 2 | SYNC-04 | unit | `swift test --package-path DS3Lib --filter SyncEngineTests/testDetectsDeletedItems` | Plan 02 T1 creates | pending |
| 02-02-04 | 02 | 2 | SYNC-04 | unit | `swift test --package-path DS3Lib --filter SyncEngineTests/testMassDeletionWarning` | Plan 02 T1 creates | pending |
| 02-02-05 | 02 | 2 | SYNC-05 | unit | `swift test --package-path DS3Lib --filter SyncEngineTests/testSyncAnchorAdvances` | Plan 02 T1 creates | pending |
| 02-02-06 | 02 | 2 | SYNC-05 | unit | `swift test --package-path DS3Lib --filter SyncEngineTests/testSyncAnchorPersistence` | Plan 02 T1 creates | pending |
| 02-02-07 | 02 | 2 | SYNC-06 | unit | `swift test --package-path DS3Lib --filter SyncEngineTests/testDefaultContentPolicy` | Plan 02 T1 creates | pending |
| 02-02-08 | 02 | 2 | ERR | unit | `swift test --package-path DS3Lib --filter SyncEngineTests/testConsecutiveFailureErrorState` | Plan 02 T1 creates | pending |
| 02-02-09 | 02 | 2 | ERR | unit | `swift test --package-path DS3Lib --filter SyncEngineTests/testErrorCountResetOnSuccess` | Plan 02 T1 creates | pending |
| 02-02-10 | 02 | 2 | SYNC-04 | unit | `swift test --package-path DS3Lib --filter SyncEngineTests/testNetworkCheckBeforeReconciliation` | Plan 02 T1 creates | pending |
| 02-02-11 | 02 | 2 | SYNC-04 | unit | `swift test --package-path DS3Lib --filter SyncEngineTests/testOnlyReportsDeletedForSyncedItems` | Plan 02 T1 creates | pending |
| 02-02-12 | 02 | 2 | SYNC-04 | unit | `swift test --package-path DS3Lib --filter SyncEngineTests/testUpdatesMetadataStoreAfterReconciliation` | Plan 02 T1 creates | pending |
| 02-03-01 | 03 | 3 | SYNC-04,05,06 | build | `xcodebuild build -project DS3Drive.xcodeproj -scheme DS3Drive -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO` | N/A (integration) | pending |
| 02-03-02 | 03 | 3 | SYNC-01,04 | build | `xcodebuild build -project DS3Drive.xcodeproj -scheme DS3Drive -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO` | N/A (integration) | pending |
| 02-03-03 | 03 | 3 | SYNC-06 | build | `xcodebuild build -project DS3Drive.xcodeproj -scheme DS3Drive -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO` | N/A (integration) | pending |

*Status: pending / green / red / flaky*

---

## Wave 0 Requirements

- [x] `DS3Lib/Tests/DS3LibTests/SyncEngineTests.swift` — Wave 0 XCTFail stubs created by Plan 01 Task 1, replaced with real tests by Plan 02 Task 1
- [x] `DS3Lib/Tests/DS3LibTests/MetadataStoreMigrationTests.swift` — Created by Plan 01 Task 1 with real assertions for SchemaV2 migration
- [x] `DS3Lib/Tests/DS3LibTests/ExponentialBackoffTests.swift` — Created by Plan 01 Task 2 with real assertions for backoff behavior
- [x] In-memory SwiftData container helper in test fixtures (extend existing `MetadataStore.init(container:)` pattern for ModelActor)

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Files appear as cloud placeholders in Finder | SYNC-06 | Requires Finder UI observation with registered File Provider domain | 1. Create drive 2. Add files to S3 bucket 3. Open Finder at drive location 4. Verify cloud download icon on files 5. Double-click to trigger download |
| Deleted S3 files disappear from Finder | SYNC-04 | Requires live S3 + Finder interaction | 1. With synced drive, delete file via S3 console 2. Wait for sync cycle 3. Verify file gone from Finder |
| Pinning keeps files downloaded | SYNC-06 | Requires Finder context menu | 1. Right-click file in Finder 2. Select "Keep Downloaded" 3. Verify file stays materialized after eviction cycle |

---

## Validation Sign-Off

- [x] All tasks have `<automated>` verify or Wave 0 dependencies
- [x] Sampling continuity: no 3 consecutive tasks without automated verify
- [x] Wave 0 covers all MISSING references
- [x] No watch-mode flags
- [x] Feedback latency < 30s
- [x] `nyquist_compliant: true` set in frontmatter

**Approval:** approved (revised 2026-03-12)
