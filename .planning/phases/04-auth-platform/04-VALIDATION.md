---
phase: 4
slug: auth-platform
status: draft
nyquist_compliant: true
wave_0_complete: false
created: 2026-03-13
---

# Phase 4 -- Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | XCTest (Swift Package Manager) |
| **Config file** | DS3Lib/Package.swift (testTarget: DS3LibTests) |
| **Quick run command** | `cd DS3Lib && swift test --filter DS3LibTests 2>&1` |
| **Full suite command** | `cd DS3Lib && swift test 2>&1` |
| **Estimated runtime** | ~30 seconds |

---

## Sampling Rate

- **After every task commit:** Run task-specific `swift test --filter` command
- **After every plan wave:** Run `cd DS3Lib && swift test 2>&1` + `xcodebuild clean build analyze -project DS3Drive.xcodeproj -scheme DS3Drive -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`
- **Before `/gsd:verify-work`:** Full suite must be green
- **Max feedback latency:** 60 seconds

---

## Inline TDD Pattern

This phase uses **inline TDD** for tasks marked `tdd="true"`. In this pattern:
- Step 1 of the task creates the test file with failing tests (RED)
- Subsequent steps implement the production code
- The `<automated>` verify command runs **after** both test creation and implementation complete within the same task

This is intentional -- the test file does not need to pre-exist before task execution because the task itself creates it as its first action. The verify command validates the final state (tests created + production code implemented + tests passing).

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Test Type | Automated Command | Pattern | Status |
|---------|------|------|-------------|-----------|-------------------|---------|--------|
| 04-01-01 | 01 | 1 | PLAT-03 | unit (inline TDD) | `cd DS3Lib && swift test --filter DS3LibTests.CubbitAPIURLsTests` | inline TDD | ⬜ pending |
| 04-01-02 | 01 | 1 | PLAT-01, PLAT-02 | unit (inline TDD) | `cd DS3Lib && swift test --filter DS3LibTests.SharedDataTenantTests` | inline TDD | ⬜ pending |
| 04-02-01 | 02 | 2 | AUTH-01 | unit (inline TDD) | `cd DS3Lib && swift test --filter DS3LibTests.AuthRequestTests` | inline TDD | ⬜ pending |
| 04-02-02 | 02 | 2 | AUTH-03 | unit (inline TDD) | `cd DS3Lib && swift test --filter DS3LibTests.TokenRefreshTests` | inline TDD | ⬜ pending |
| 04-03-01 | 03 | 3 | PLAT-01, AUTH-04 | unit (inline TDD) | `cd DS3Lib && swift test --filter DS3LibTests.AccountHelperTests && swift test --filter DS3LibTests.LoginFlowTests` | inline TDD | ⬜ pending |
| 04-03-02 | 03 | 3 | AUTH-02 | build + regression | `xcodebuild build ... && cd DS3Lib && swift test --filter DS3LibTests.AccountHelperTests` | build + test | ⬜ pending |
| 04-03-03 | 03 | 3 | visual | checkpoint | `xcodebuild build ...` | human-verify | ⬜ pending |
| 04-04-01 | 04 | 4 | AUTH-02 | unit (inline TDD) | `cd DS3Lib && swift test --filter DS3LibTests.S3RecoveryTests && swift test --filter DS3LibTests.CoordinatorURLIntegrationTests` | inline TDD | ⬜ pending |
| 04-04-02 | 04 | 4 | AUTH-02, AUTH-03 | build + regression | `xcodebuild build ... && cd DS3Lib && swift test --filter DS3LibTests.S3RecoveryTests` | build + test | ⬜ pending |

*Status: ⬜ pending - ✅ green - ❌ red - ⚠️ flaky*

---

## Test Files Created (Inline TDD)

All test files are created inline during their respective task execution:

- [ ] `DS3Lib/Tests/DS3LibTests/CubbitAPIURLsTests.swift` -- URL derivation from coordinator base (Plan 01, Task 1)
- [ ] `DS3Lib/Tests/DS3LibTests/SharedDataTenantTests.swift` -- Tenant and coordinator URL persistence (Plan 01, Task 2)
- [ ] `DS3Lib/Tests/DS3LibTests/AuthRequestTests.swift` -- tenant_id encoding in request bodies (Plan 02, Task 1)
- [ ] `DS3Lib/Tests/DS3LibTests/TokenRefreshTests.swift` -- Expiry detection logic (Plan 02, Task 2)
- [ ] `DS3Lib/Tests/DS3LibTests/AccountHelperTests.swift` -- Account.primaryEmail behavior (Plan 03, Task 1)
- [ ] `DS3Lib/Tests/DS3LibTests/LoginFlowTests.swift` -- Tenant/coordinator URL data flow through SharedData (Plan 03, Task 1)
- [ ] `DS3Lib/Tests/DS3LibTests/S3RecoveryTests.swift` -- S3 auth error detection (Plan 04, Task 1)
- [ ] `DS3Lib/Tests/DS3LibTests/CoordinatorURLIntegrationTests.swift` -- Coordinator URL -> CubbitAPIURLs construction (Plan 04, Task 1)

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| 2FA flow passes tenant_id through MFA retry | AUTH-04 | Requires live IAM server with 2FA-enabled account | 1. Log in with 2FA-enabled account 2. Verify MFA prompt appears 3. Enter valid code 4. Verify login completes |
| Login UI Advanced section, tray menu | PLAT-01, AUTH-02 | Visual UI verification | Plan 03, Task 3 checkpoint:human-verify |

---

## Sampling Continuity Check

| Window | Tasks | Automated Tests | Compliant |
|--------|-------|-----------------|-----------|
| 04-01-01, 04-01-02, 04-02-01 | 3 | 3 (all inline TDD) | YES |
| 04-01-02, 04-02-01, 04-02-02 | 3 | 3 (all inline TDD) | YES |
| 04-02-01, 04-02-02, 04-03-01 | 3 | 3 (all inline TDD) | YES |
| 04-02-02, 04-03-01, 04-03-02 | 3 | 2 (inline TDD + build+test) | YES |
| 04-03-01, 04-03-02, 04-03-03 | 3 | 2 (inline TDD + build+test) | YES |
| 04-03-02, 04-03-03, 04-04-01 | 3 | 2 (build+test + inline TDD) | YES |
| 04-03-03, 04-04-01, 04-04-02 | 3 | 2 (inline TDD + build+test) | YES |

All 3-task windows have at least 2 automated behavioral verifications.

---

## Validation Sign-Off

- [x] All tasks have `<automated>` verify with task-specific filters
- [x] Sampling continuity: no 3 consecutive tasks without automated verify
- [x] Inline TDD pattern acknowledged -- tests created within task execution
- [x] No watch-mode flags
- [x] Feedback latency < 60s
- [x] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
