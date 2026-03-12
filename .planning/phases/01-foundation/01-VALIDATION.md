---
phase: 1
slug: foundation
status: draft
nyquist_compliant: true
wave_0_complete: true
created: 2026-03-11
---

# Phase 1 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | XCTest (built into Xcode) |
| **Config file** | None — Wave 0 creates test target in DS3Lib Package.swift |
| **Quick run command** | `xcodebuild build -scheme DS3Drive -destination 'platform=macOS'` |
| **Full suite command** | `xcodebuild build -scheme DS3Drive -destination 'platform=macOS'` |
| **Estimated runtime** | ~30 seconds |

---

## Sampling Rate

- **After every task commit:** Run `xcodebuild build -scheme DS3Drive -destination 'platform=macOS'`
- **After every plan wave:** Run full build + manual verification of relevant success criteria
- **Before `/gsd:verify-work`:** Full build must succeed; all 5 success criteria verified
- **Max feedback latency:** 30 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|-----------|-------------------|-------------|--------|
| 01-01-xx | 01 | 1 | FOUN-01 | manual-only | Build succeeds after rename | N/A | ⬜ pending |
| 01-02-xx | 02 | 1 | FOUN-02 | manual-only | Console.app subsystem filter | N/A | ⬜ pending |
| 01-03-xx | 02 | 1 | FOUN-03 | manual-only | Launch extension with missing SharedData | N/A | ⬜ pending |
| 01-04-xx | 03 | 2 | FOUN-04 | manual-only | Launch app + extension, verify records | N/A | ⬜ pending |
| 01-05-xx | 03 | 2 | SYNC-07 | manual-only | Multipart upload to S3, verify ETag logged | N/A | ⬜ pending |
| 01-06-xx | 02 | 1 | SYNC-08 | manual-only | Trigger S3 errors, verify correct NSFileProviderError | N/A | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] `DS3Lib/Tests/DS3LibTests/` — test target stub created in Package.swift
- [ ] Test infrastructure deferred per user decision — no unit tests required in Phase 1

*Note: CONTEXT.md explicitly states "Testing deferred — no unit tests for MetadataStore in Phase 1." Tests are deferred per user decision. Build success is the primary automated verification.*

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| App launches as "DS3 Drive" with correct bundle IDs | FOUN-01 | Requires Xcode + Finder visual check | 1. Build & run 2. Check app name in menu bar 3. Verify bundle ID in Xcode project settings |
| Structured logs in Console.app | FOUN-02 | Requires Console.app filtering | 1. Launch app 2. Open Console.app 3. Filter by subsystem `io.cubbit.DS3Drive` 4. Verify categories (sync, auth, transfer, extension, app, metadata) |
| Extension graceful init with missing data | FOUN-03 | Requires File Provider extension lifecycle | 1. Delete SharedData JSON files 2. Trigger extension load 3. Verify no crash in Console.app 4. Verify error logged |
| SwiftData cross-process access | FOUN-04 | Requires both app and extension running | 1. Launch app, create SyncedItem 2. Verify extension can read it 3. Verify data persists across launches |
| Multipart upload ETag validation | SYNC-07 | Requires live S3 connection | 1. Upload file > 5MB 2. Check logs for ETag validation 3. Verify CompleteMultipartUpload response checked |
| S3 error mapping | SYNC-08 | Requires triggering specific S3 errors | 1. Use invalid credentials 2. Verify .notAuthenticated returned 3. Access non-existent key 4. Verify .noSuchItem returned |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 30s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
