---
phase: 3
slug: conflict-resolution
status: draft
nyquist_compliant: true
wave_0_complete: true
created: 2026-03-12
---

# Phase 3 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | XCTest + SwiftData (Swift 6.0) |
| **Config file** | DS3Lib/Package.swift (testTarget: DS3LibTests) |
| **Quick run command** | `swift test --package-path DS3Lib` |
| **Full suite command** | `swift test --package-path DS3Lib` |
| **Estimated runtime** | ~30 seconds |

---

## Sampling Rate

- **After every task commit:** Run `swift test --package-path DS3Lib`
- **After every plan wave:** Run `swift test --package-path DS3Lib`
- **Before `/gsd:verify-work`:** Full suite must be green
- **Max feedback latency:** 30 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Test Type | Automated Command | TDD Exception | Status |
|---------|------|------|-------------|-----------|-------------------|---------------|--------|
| 03-01-01 | 01 | 1 | SYNC-02, SYNC-03 | unit | `swift test --package-path DS3Lib --filter ConflictNamingTests` | TDD plan (creates tests in RED step) | pending |
| 03-01-02 | 01 | 1 | SYNC-02, SYNC-03 | unit | `swift test --package-path DS3Lib --filter ETagUtilsTests` | TDD plan (creates tests in RED step) | pending |
| 03-02-01 | 02 | 2 | SYNC-02, SYNC-03 | build | `xcodebuild clean build -scheme DS3Drive -destination "platform=macOS" CODE_SIGNING_ALLOWED=NO` | N/A (build verification) | pending |
| 03-02-02 | 02 | 2 | SYNC-02, SYNC-03 | build | `xcodebuild clean build -scheme DS3Drive -destination "platform=macOS" CODE_SIGNING_ALLOWED=NO` | N/A (build verification) | pending |
| 03-03-01 | 03 | 3 | SYNC-02, SYNC-03 | build | `xcodebuild clean build -scheme DS3Drive -destination "platform=macOS" CODE_SIGNING_ALLOWED=NO` | N/A (build verification) | pending |
| 03-03-02 | 03 | 3 | SYNC-02, SYNC-03 | unit | `swift test --package-path DS3Lib --filter ConflictDetectionTests` | TDD task (tdd="true", creates tests in RED step) | pending |

*Status: pending · green · red · flaky*

---

## Wave 0 — TDD Exception

Wave 0 pre-stubbed test files are **not required** for this phase. All test files are created during TDD execution:

- `ConflictNamingTests.swift` — Created by Plan 03-01 (type: tdd) during RED step
- `ETagUtilsTests.swift` — Created by Plan 03-01 (type: tdd) during RED step
- `ConflictDetectionTests.swift` — Created by Plan 03-03 Task 2 (tdd="true") during RED step

**Rationale:** TDD plans and TDD tasks create test files as their first action (write failing tests, then implement). The test files are the output of task execution, not a prerequisite. Wave 0 stubs would be redundant -- the TDD RED step IS the stub creation.

No additional framework installation needed -- XCTest already configured.

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Conflict copy appears in Finder alongside original | SYNC-03 | Requires real File Provider + Finder integration | 1. Edit a file from two Macs. 2. Verify conflict copy appears in same folder with correct naming pattern. |
| Clicking notification reveals conflict copy in Finder | SYNC-03 | Requires macOS notification system + Finder | 1. Trigger conflict. 2. Click notification. 3. Verify Finder opens to conflict copy location. |
| File Provider re-fetches remote version after conflict | SYNC-02 | Requires real File Provider enumeration cycle | 1. Trigger conflict. 2. Verify original filename shows remote version. |

---

## Validation Sign-Off

- [x] All tasks have `<automated>` verify or TDD exception documented
- [x] Sampling continuity: no 3 consecutive tasks without automated verify
- [x] Wave 0 not needed -- TDD plans/tasks create tests during execution
- [x] No watch-mode flags
- [x] Feedback latency < 30s
- [x] `nyquist_compliant: true` set in frontmatter

**Approval:** approved (TDD exception documented)
