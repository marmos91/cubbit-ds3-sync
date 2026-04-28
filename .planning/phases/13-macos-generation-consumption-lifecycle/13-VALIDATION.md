---
phase: 13
slug: macos-generation-consumption-lifecycle
status: draft
nyquist_compliant: true
wave_0_complete: true
created: 2026-04-25
---

# Phase 13 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | XCTest (Swift) — DS3LibTests + DS3DriveProviderTests |
| **Config file** | `DS3Drive.xcodeproj/xcshareddata/xcschemes/DS3Drive.xcscheme` |
| **Quick run command** | `xcodebuild test -scheme DS3Drive -destination 'platform=macOS' -only-testing:DS3LibTests` |
| **Full suite command** | `xcodebuild clean test -scheme DS3Drive -destination 'platform=macOS'` |
| **Estimated runtime** | ~120-180 seconds (clean build + tests) |

---

## Sampling Rate

- **After every task commit:** Run targeted test (e.g., `xcodebuild test -only-testing:DS3LibTests/ThumbnailUploaderTests`)
- **After every plan wave:** Run `xcodebuild test -scheme DS3Drive -destination 'platform=macOS'`
- **Before `/gsd-verify-work`:** Full suite must be green
- **Max feedback latency:** 180 seconds

---

## Per-Task Verification Map

Phase 13 ships as 11 plans (13-01 .. 13-11). Every implementation task (Task 2 in each plan)
has its in-plan Task 1 RED test as its Wave-0 dependency — the TDD-RED-then-GREEN within-plan
pattern (see "Wave 0 Requirements" below). The map below lists each task's automated verify
command and whether the supporting test file has been authored.

| Task ID | Plan | Wave | Requirement | Threat Ref | Secure Behavior | Test Type | Automated Command | Wave-0 Dep | Status |
|---------|------|------|-------------|------------|-----------------|-----------|-------------------|------------|--------|
| 13-01-01 | 01 | 1 | THUMB-23 | T-13-01 | DefaultSettings.Thumbnail constants exist (backfillBatchSize=5, maxOrphanDeletesPerPass=50, maxFailStrikes=3) | unit | `swift test --package-path DS3Lib --filter DefaultSettingsThumbnailTests` | in-plan (no Task 1 — pure constants edit) | ⬜ pending |
| 13-02-01 | 02 | 1 | THUMB-06 | T-13-04 | ThumbnailUploaderTests RED — missing impl produces compilation/test failures | unit RED | `swift test --package-path DS3Lib --filter ThumbnailUploaderTests` | — (this IS Wave 0) | ⬜ pending |
| 13-02-02 | 02 | 1 | THUMB-06 | T-13-04 | ThumbnailUploader produces correct thumbnail with sourceETag metadata | unit GREEN | `swift test --package-path DS3Lib --filter ThumbnailUploaderTests` | 13-02-01 | ⬜ pending |
| 13-03-01 | 03 | 1 | THUMB-18 | T-13-08 | CopyThumbnailTests RED — missing copyThumbnail extension fails | unit RED | `swift test --package-path DS3Lib --filter CopyThumbnailTests` | — (this IS Wave 0) | ⬜ pending |
| 13-03-02 | 03 | 1 | THUMB-18 | T-13-08 | copyThumbnail issues CopyObject preserving source-etag (metadataDirective default) | unit GREEN | `swift test --package-path DS3Lib --filter CopyThumbnailTests` | 13-03-01 | ⬜ pending |
| 13-04-01 | 04 | 2 | THUMB-20 | T-13-13..17 | SchemaV4MigrationTests + ThumbnailStrikeRuleTests RED — V4 + strike helper + ETag reset missing | unit RED | `swift test --package-path DS3Lib --filter "SchemaV4MigrationTests\|ThumbnailStrikeRuleTests"` | — (this IS Wave 0) | ⬜ pending |
| 13-04-02 | 04 | 2 | THUMB-20 | T-13-13..17 | V3→V4 lightweight migration + setThumbnailFailure (>=3 → .failed) + ETag reset on upsert + ThumbnailUploader retrofit | unit GREEN | `swift test --package-path DS3Lib --filter "SchemaV4MigrationTests\|ThumbnailStrikeRuleTests\|ThumbnailUploaderTests\|MetadataStoreThumbnailQueriesTests"` | 13-04-01 | ⬜ pending |
| 13-05-01 | 05 | 2 | THUMB-15, 21 | T-13-18..22 | ThumbnailBackfillCoordinator behavior tests RED | unit RED | `swift test --package-path DS3Lib --filter ThumbnailBackfillCoordinatorTests` | — (this IS Wave 0) | ⬜ pending |
| 13-05-02 | 05 | 2 | THUMB-15, 21 | T-13-18..22 | runBatch skips on thermal>=.serious; pause exits at iteration boundary | unit GREEN | `swift test --package-path DS3Lib --filter ThumbnailBackfillCoordinatorTests` | 13-05-01 | ⬜ pending |
| 13-06-01 | 06 | 2 | THUMB-14 | T-13-23..28 | ThumbnailFetchLimiterTests RED — limiter actor missing | unit RED | `xcodebuild test -only-testing:DS3DriveProviderTests/ThumbnailFetchLimiterTests` | — (this IS Wave 0) | ⬜ pending |
| 13-06-02 | 06 | 2 | THUMB-11..14, 13 | T-13-23..28 | Cache-first fetchThumbnails + 4-slot limiter + error mapping (404/5xx/Slow/auth) + S3Lib+Thumbnails audit decision | unit GREEN | `xcodebuild test -only-testing:DS3DriveProviderTests/ThumbnailFetchLimiterTests -only-testing:DS3DriveProviderTests/FetchThumbnailsTests -only-testing:DS3DriveProviderTests/FetchThumbnailsErrorMappingTests` | 13-06-01 | ⬜ pending |
| 13-07-01 | 07 | 3 | THUMB-06 | T-13-29..34 | UploadHookTests RED — hook calls don't exist; mock records zero putThumbnail calls | unit RED | `xcodebuild test -only-testing:DS3DriveProviderTests/UploadHookTests` | — (this IS Wave 0) | ⬜ pending |
| 13-07-02 | 07 | 3 | THUMB-06 | T-13-29..34 | createItem + modifyItem(content-change) post-PUT trigger ThumbnailUploader; metadata-only + rename branches untouched | unit GREEN | `xcodebuild test -only-testing:DS3DriveProviderTests/UploadHookTests` | 13-07-01 | ⬜ pending |
| 13-08-01 | 08 | 4 | THUMB-17, 18 | T-13-35..40 | CascadeDeleteTests + CascadeRenameTests RED | unit RED | `xcodebuild test -only-testing:DS3DriveProviderTests/CascadeDeleteTests -only-testing:DS3DriveProviderTests/CascadeRenameTests` | — (this IS Wave 0) | ⬜ pending |
| 13-08-02 | 08 | 4 | THUMB-17, 18 | T-13-35..40 | Delete + rename/move cascades; content-change suppresses rename cascade. Plan 13-07 tests `testModifyItemMetadataOnlyChangeDoesNotTriggerUploader` and `testModifyItemContentChangeTriggersThumbnailUploaderTask` MUST remain green. | unit GREEN | `xcodebuild test -only-testing:DS3DriveProviderTests/UploadHookTests -only-testing:DS3DriveProviderTests/CascadeDeleteTests -only-testing:DS3DriveProviderTests/CascadeRenameTests` | 13-08-01 + 13-07-02 | ⬜ pending |
| 13-09-01 | 09 | 5 | THUMB-19 | T-13-41..47 | OrphanSweepTests + BFSThumbnailHookTests RED | unit RED | `xcodebuild test -only-testing:DS3DriveProviderTests/OrphanSweepTests -only-testing:DS3DriveProviderTests/BFSThumbnailHookTests` | — (this IS Wave 0) | ⬜ pending |
| 13-09-02 | 09 | 5 | THUMB-15, 19, 23 | T-13-41..47 | OrphanSweeper struct + BFS pass-tail invokes coordinator.runBatch with maxItems == DefaultSettings.Thumbnail.backfillBatchSize; orphan sweep capped at 50 | unit GREEN | `xcodebuild test -only-testing:DS3DriveProviderTests/OrphanSweepTests -only-testing:DS3DriveProviderTests/BFSThumbnailHookTests` | 13-09-01 | ⬜ pending |
| 13-10-01 | 10 | 6 | THUMB-23 | T-13-48..53 | hasThumbnailSettings + ThumbnailRolloutTests RED; corrupt-JSON re-check test included | unit RED | `swift test --package-path DS3Lib --filter SharedDataThumbnailSettingsTests && xcodebuild test -only-testing:DS3DriveProviderTests/ThumbnailRolloutTests` | — (this IS Wave 0) | ⬜ pending |
| 13-10-02 | 10 | 6 | THUMB-23 | T-13-48..53 | First-launch silent rollout via ThumbnailRollout; subsequent launches no-op; corrupt JSON triggers re-check | unit GREEN | `xcodebuild test -only-testing:DS3DriveProviderTests/ThumbnailRolloutTests` | 13-10-01 | ⬜ pending |
| 13-11-01 | 11 | 7 | All Phase-13 | T-13-54..59 | Phase13IntegrationSmokeTests RED; integration-level cross-component contracts missing | unit RED | `swift test --package-path DS3Lib --filter Phase13IntegrationSmokeTests` | — (this IS Wave 0) | ⬜ pending |
| 13-11-02 | 11 | 7 | All Phase-13 | T-13-54..59 | Integration smoke: upload → marked uploaded → cache-first fetch → cascade round-trip; backfill flow; strike rule end-to-end. Old generator-path audit (S3Lib+Thumbnails decision finalized; no edits in 13-11). | integration GREEN | `swift test --package-path DS3Lib --filter Phase13IntegrationSmokeTests && xcodebuild build -scheme DS3Drive -destination 'platform=macOS'` | 13-11-01 | ⬜ pending |
| 13-11-03 | 11 | 7 | All Phase-13 | T-13-54..59 | Human verification of Finder thumbnails, sync badges, cascade behavior, pause/resume, no SlowDown, silent rollout, error-domain compliance | checkpoint:human-verify | gate (manual; see plan 13-11 Task 3 `<how-to-verify>`) | 13-11-02 | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

**Pattern: TDD-RED-then-GREEN within-plan.** Phase 13 does NOT use a separate Plan 13-00
"Wave 0 setup" pass. Instead, every plan that produces production code follows the standard
GSD TDD pattern documented in `tdd_integration` of the planner role:

- **Task 1 (RED):** authors the failing test file(s) committed at HEAD with the
  `test(13-NN): ...` commit message. The tests reference symbols / behavior that do not
  exist yet, so they fail (compile errors or assertion failures).
- **Task 2 (GREEN):** implements the production code, iterates until all RED tests pass,
  commits with `feat(13-NN): ...`.

Therefore every Task 2 (the implementation) has its corresponding Task 1 (the failing test
file) as its in-plan Wave-0 dependency. There are no orphan implementation tasks lacking a
test scaffold — every implementation has a RED test pinning its expected behavior committed
in the same plan.

The expected RED test files at the close of each plan's Task 1 are:

- **Plan 13-01** — pure constants addition; tests live alongside (DefaultSettings tests file extended in Task 1 inline, no separate RED commit needed)
- **Plan 13-02 Task 1:** `DS3Lib/Tests/DS3LibTests/ThumbnailUploaderTests.swift`
- **Plan 13-03 Task 1:** `DS3Lib/Tests/DS3LibTests/CopyThumbnailTests.swift`
- **Plan 13-04 Task 1:** `DS3Lib/Tests/DS3LibTests/SchemaV4MigrationTests.swift` + `DS3Lib/Tests/DS3LibTests/ThumbnailStrikeRuleTests.swift`
- **Plan 13-05 Task 1:** `DS3Lib/Tests/DS3LibTests/ThumbnailBackfillCoordinatorTests.swift` (extends Phase 12 stub)
- **Plan 13-06 Task 1:** `DS3DriveProviderTests/ThumbnailFetchLimiterTests.swift`
- **Plan 13-06 Task 2 (in-task RED prelude):** `DS3DriveProviderTests/FetchThumbnailsTests.swift` + `DS3DriveProviderTests/FetchThumbnailsErrorMappingTests.swift` authored at the start of Task 2 (per Plan 13-06 `<behavior>` block) before the rewrite
- **Plan 13-07 Task 1:** `DS3DriveProviderTests/UploadHookTests.swift`
- **Plan 13-08 Task 1:** `DS3DriveProviderTests/CascadeDeleteTests.swift` + `DS3DriveProviderTests/CascadeRenameTests.swift`
- **Plan 13-09 Task 1:** `DS3DriveProviderTests/OrphanSweepTests.swift` + `DS3DriveProviderTests/BFSThumbnailHookTests.swift`
- **Plan 13-10 Task 1:** `DS3DriveProviderTests/ThumbnailRolloutTests.swift` + `DS3Lib/Tests/DS3LibTests/SharedDataThumbnailSettingsTests.swift` (extension)
- **Plan 13-11 Task 1:** `DS3Lib/Tests/DS3LibTests/Phase13IntegrationSmokeTests.swift`

Test fixtures (Git LFS) are reused from Phase 11/12 — no new fixtures needed in Phase 13.

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Real Finder shows actual thumbnails after upload | THUMB-06, 11 | Visual / OS integration — automated tests cannot verify Finder rendering | (1) Build & install Phase 13 build, (2) drag photos/test.heic into a DS3 Drive folder in Finder, (3) verify thumbnail appears within ~5 seconds, (4) verify default UTType icon shown for unsupported.pdf with no error popup |
| Sync status badges still render correctly atop thumbnails | THUMB-12 | Visual — automated test cannot inspect compositing | Open a folder with mix of synced/syncing/error files in Finder, verify colored badges still visible on top of generated thumbnails |
| iOS Files app shows macOS-generated thumbnails | THUMB-11 | Cross-platform device test | Sync drive with iOS device, browse same folder in iOS Files app, verify thumbnails appear without iOS extension decoding |
| No SlowDown errors under bursty BFS + Finder folder open | THUMB-14, 23 | Real-world load — synthetic test won't reproduce S3 throttle | Sync a 1000-image folder via BFS while user opens fresh Finder windows; check `log show` for absence of `SlowDown` |
| Pause halts backfill within ~1 item | THUMB-21 | Timing-dependent state machine | Start backfill on drive with 100+ pending; pause via tray; verify within 30s no new thumbnail PUTs happen (check log + S3 access logs) |
| Once-per-drive collision re-check on first v3.1 launch | THUMB-23 | Lifecycle test | Install build with bucket containing valid `.thumbnails/` content; launch; verify `inspectThumbnailPrefix` runs once and persists `enabled=true`; relaunch; verify it does NOT run again |

The full Phase-13 manual verification protocol is owned by Plan 13-11 Task 3
(`checkpoint:human-verify`). See `13-11-PLAN.md` `<how-to-verify>` for the canonical script.

---

## Validation Sign-Off

- [x] All implementation tasks (Task 2 in each plan) have an in-plan Task 1 RED dependency providing the test scaffold (TDD-RED-then-GREEN within-plan pattern)
- [x] Sampling continuity: no 3 consecutive tasks without automated verify (every Task 2 has an `<automated>` command)
- [x] Wave 0 covered via the in-plan TDD pattern (no separate Plan 13-00 needed; documented above)
- [x] No watch-mode flags (xcodebuild / swift test invocations are one-shot)
- [x] Feedback latency < 180s (per-plan filtered runs are 5-30s; full xcodebuild test < 180s)
- [x] `nyquist_compliant: true` set in frontmatter

**Approval:** approved — Phase 13 validation strategy ready for execution.
