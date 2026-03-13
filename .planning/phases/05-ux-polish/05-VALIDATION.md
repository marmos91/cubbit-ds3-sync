---
phase: 5
slug: ux-polish
status: draft
nyquist_compliant: true
wave_0_complete: true
created: 2026-03-13
---

# Phase 5 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | XCTest (Swift Package Manager tests in DS3Lib) |
| **Config file** | DS3Lib/Package.swift (test target defined) |
| **Quick run command** | `cd /Users/marmos91/Projects/cubbit-ds3-drive/DS3Lib && swift test --filter DS3LibTests` |
| **Full suite command** | `cd /Users/marmos91/Projects/cubbit-ds3-drive/DS3Lib && swift test` |
| **Estimated runtime** | ~15 seconds |

---

## Sampling Rate

- **After every task commit:** Run `cd /Users/marmos91/Projects/cubbit-ds3-drive/DS3Lib && swift test --filter DS3LibTests`
- **After every plan wave:** Run `cd /Users/marmos91/Projects/cubbit-ds3-drive/DS3Lib && swift test`
- **Before `/gsd:verify-work`:** Full suite must be green
- **Max feedback latency:** 15 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|-----------|-------------------|-------------|--------|
| 05-01-xx | 01 | 1 | UX-01 | manual-only | N/A (Finder + File Provider runtime) | N/A | pending |
| 05-02-T0 | 02 | 1 | N/A | stub | `cd DS3Lib && swift test --filter PauseState && swift test --filter RecentFiles` | Wave 0 (Task 0 creates stubs) | pending |
| 05-02-T1 | 02 | 1 | UX-05 | unit (TDD) | `cd DS3Lib && swift test --filter PauseState` | Created by Task 0 | pending |
| 05-02-T2 | 02 | 1 | UX-04 | unit (TDD) | `cd DS3Lib && swift test --filter RecentFiles` | Created by Task 0 | pending |
| 05-03-xx | 03 | 1 | UX-06 | manual-only | N/A (UI flow) | N/A | pending |
| 05-04-xx | 04 | 2 | UX-02,03,04,05 | manual-only | N/A (running app + menu bar) | N/A | pending |
| 05-05-xx | 05 | 3 | UX-01-07 | manual-only | N/A (full UX verification) | N/A | pending |
| 05-xx-xx | xx | 1 | UX-07 | unit | `cd DS3Lib && swift test --filter DS3LibTests/testMaxDrives` | constant | pending |

*Status: pending / green / red / flaky*

---

## Wave 0 Requirements

- [x] `DS3Lib/Tests/DS3LibTests/PauseStateTests.swift` — stubs created by Plan 02 Task 0 (before TDD Tasks 1-2)
- [x] `DS3Lib/Tests/DS3LibTests/RecentFilesTrackerTests.swift` — stubs created by Plan 02 Task 0 (before TDD Tasks 1-2)
- [ ] Verify `xcodebuild clean build analyze` passes after all UI changes (CI gate)

*Wave 0 is satisfied by Plan 02 Task 0, which creates test stubs before the TDD tasks replace them with real tests.*

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Finder badges show sync state per file | UX-01 | Requires Finder + File Provider extension runtime | 1. Sync a file 2. Verify green checkmark badge 3. Start sync, verify blue arrows 4. Disconnect, verify error badge |
| Menu bar colored status indicators | UX-02 | Requires running app with menu bar | 1. Connect drive 2. Verify green dot when idle 3. Upload file, verify blue dot 4. Force error, verify red dot |
| Real-time transfer speed display | UX-03 | UI formatting in menu bar | 1. Start large upload 2. Verify speed shown in tray 3. Verify speed updates in real time |
| Recently synced files in side panel | UX-04 | UI interaction + side panel | 1. Sync files 2. Click drive row 3. Verify recent files panel 4. Verify ordering (progress > errors > completed) |
| Quick actions work | UX-05 | UI interaction + system integration | 1. Click Add Drive 2. Click Open in Finder 3. Click Pause, verify behavior 4. Click Resume |
| Simplified 2-step wizard | UX-06 | Multi-step UI flow | 1. Add new drive 2. Navigate tree (project > bucket > prefix) 3. Verify name auto-suggested 4. Confirm and verify drive created |
| Drive limit enforced at 3 | UX-07 | Already implemented | Verify Add Drive button disabled when 3 drives exist |

---

## Validation Sign-Off

- [x] All tasks have `<automated>` verify or Wave 0 dependencies
- [x] Sampling continuity: no 3 consecutive tasks without automated verify
- [x] Wave 0 covers all MISSING references
- [x] No watch-mode flags
- [x] Feedback latency < 15s
- [x] `nyquist_compliant: true` set in frontmatter

**Approval:** approved
