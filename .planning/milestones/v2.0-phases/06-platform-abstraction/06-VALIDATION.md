---
phase: 6
slug: platform-abstraction
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-03-17
---

# Phase 6 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | XCTest (built-in) + Swift Testing (swift-tools-version: 6.0) |
| **Config file** | `DS3Lib/Package.swift` (testTarget defined) |
| **Quick run command** | `swift test --package-path DS3Lib` |
| **Full suite command** | `swift test --package-path DS3Lib` |
| **Estimated runtime** | ~30 seconds |

---

## Sampling Rate

- **After every task commit:** Run `swift test --package-path DS3Lib`
- **After every plan wave:** Run `swift test --package-path DS3Lib` + macOS Xcode build
- **Before `/gsd:verify-work`:** Full suite must be green + iOS simulator build green + manual smoke test
- **Max feedback latency:** 30 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|-----------|-------------------|-------------|--------|
| 06-01-01 | 01 | 1 | ABST-01 | unit | `swift test --package-path DS3Lib --filter IPCServiceTests` | ❌ W0 | ⬜ pending |
| 06-01-02 | 01 | 1 | ABST-01 | unit | `swift test --package-path DS3Lib --filter DarwinNotificationTests` | ❌ W0 | ⬜ pending |
| 06-01-03 | 01 | 1 | ABST-01 | unit | `swift test --package-path DS3Lib --filter IPCFilePayloadTests` | ❌ W0 | ⬜ pending |
| 06-02-01 | 02 | 1 | ABST-02 | unit | `swift test --package-path DS3Lib --filter SystemServiceTests` | ❌ W0 | ⬜ pending |
| 06-03-01 | 03 | 1 | ABST-03 | unit | `swift test --package-path DS3Lib --filter LifecycleServiceTests` | ❌ W0 | ⬜ pending |
| 06-04-01 | 04 | 2 | ABST-04 | smoke | `xcodebuild build -scheme DS3Lib -destination 'platform=iOS Simulator,name=iPhone 16'` | N/A (CI) | ⬜ pending |
| 06-04-02 | 04 | 2 | ABST-04 | regression | `swift test --package-path DS3Lib` | ✅ (136 tests) | ⬜ pending |
| 06-05-01 | ALL | - | ALL | manual | Smoke test checklist: login, create drive, sync files, tray menu, pause/resume | Manual | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] `DS3Lib/Tests/DS3LibTests/IPCServiceTests.swift` — stubs for ABST-01 (mock + macOS impl)
- [ ] `DS3Lib/Tests/DS3LibTests/DarwinNotificationTests.swift` — stubs for ABST-01 (Darwin notification round-trip)
- [ ] `DS3Lib/Tests/DS3LibTests/SystemServiceTests.swift` — stubs for ABST-02
- [ ] `DS3Lib/Tests/DS3LibTests/LifecycleServiceTests.swift` — stubs for ABST-03
- [ ] iOS simulator build verification in CI — covers ABST-04

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| macOS app functions identically after all changes | ALL (regression) | Full app lifecycle involves Finder integration, menu bar, file sync | 1. Login with valid credentials 2. Create a new drive 3. Sync files up/down 4. Verify tray menu shows correct status 5. Pause/resume sync 6. Delete drive |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 30s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
