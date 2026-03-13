---
phase: 5
slug: ux-polish
status: draft
nyquist_compliant: false
wave_0_complete: false
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
| 05-01-xx | 01 | 1 | UX-01 | manual-only | N/A (Finder + File Provider runtime) | N/A | ⬜ pending |
| 05-02-xx | 02 | 2 | UX-02 | manual-only | N/A (running app + menu bar) | N/A | ⬜ pending |
| 05-02-xx | 02 | 2 | UX-03 | unit | `cd DS3Lib && swift test --filter DS3LibTests/testDriveStatsFormatting` | ✅ partial | ⬜ pending |
| 05-02-xx | 02 | 2 | UX-04 | unit | `cd DS3Lib && swift test --filter DS3LibTests/testRecentFilesRingBuffer` | ❌ W0 | ⬜ pending |
| 05-02-xx | 02 | 2 | UX-05 | manual-only | N/A (running app) | N/A | ⬜ pending |
| 05-03-xx | 03 | 3 | UX-06 | manual-only | N/A (UI flow) | N/A | ⬜ pending |
| 05-xx-xx | xx | 1 | UX-07 | unit | `cd DS3Lib && swift test --filter DS3LibTests/testMaxDrives` | ✅ (constant) | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] `DS3Lib/Tests/DS3LibTests/RecentFilesTests.swift` — stubs for UX-04 (recent files ring buffer)
- [ ] `DS3Lib/Tests/DS3LibTests/PauseStateTests.swift` — stubs for UX-05 (pause state persistence)
- [ ] Verify `xcodebuild clean build analyze` passes after all UI changes (CI gate)

*Most UX-phase requirements are visual/interaction and covered by manual testing.*

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

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 15s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
