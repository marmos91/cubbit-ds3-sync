---
phase: 15
slug: rust-core-ffi-foundation
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-05-27
---

# Phase 15 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | cargo test (Rust) + swift test (UniFFI harness) + dotnet test (C# P/Invoke) |
| **Config file** | `core/Cargo.toml` (workspace root) |
| **Quick run command** | `cd core && cargo test --workspace` |
| **Full suite command** | `cd core && cargo test --workspace && cargo clippy --workspace -- -D warnings` |
| **Estimated runtime** | ~30 seconds (unit), ~120 seconds (integration with S3) |

---

## Sampling Rate

- **After every task commit:** Run `cd core && cargo test --workspace`
- **After every plan wave:** Run `cd core && cargo test --workspace && cargo clippy --workspace -- -D warnings`
- **Before `/gsd:verify-work`:** Full suite must be green
- **Max feedback latency:** 30 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Threat Ref | Secure Behavior | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|------------|-----------------|-----------|-------------------|-------------|--------|
| 15-01-01 | 01 | 1 | CORE-01 | — | N/A | structural | `test -d apple/ && test -d core/ && test -d windows/` | ❌ W0 | ⬜ pending |
| 15-02-01 | 02 | 1 | CORE-02 | — | N/A | unit | `cd core && cargo test -p ds3-models` | ❌ W0 | ⬜ pending |
| 15-03-01 | 03 | 2 | CORE-03, CORE-04 | T-15-01 | Credentials never logged, JWT stored in memory only | unit+integ | `cd core && cargo test -p ds3-auth` | ❌ W0 | ⬜ pending |
| 15-04-01 | 04 | 2 | CORE-05 | — | N/A | unit+integ | `cd core && cargo test -p ds3-s3` | ❌ W0 | ⬜ pending |
| 15-05-01 | 05 | 3 | CORE-06 | — | N/A | unit | `cd core && cargo test -p ds3-sync` | ❌ W0 | ⬜ pending |
| 15-06-01 | 06 | 3 | CORE-07, CORE-08 | T-15-02 | Panics caught at FFI boundary, no UB from invalid handles | unit+integ | `cd core && cargo test -p ds3-ffi` | ❌ W0 | ⬜ pending |
| 15-07-01 | 07 | 4 | CORE-09, CORE-10 | — | N/A | integ | `swift test` + `dotnet test` | ❌ W0 | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] `core/Cargo.toml` — workspace manifest with all 6 crates
- [ ] `core/ds3-models/src/lib.rs` — model stubs
- [ ] `core/ds3-ffi/tests/` — FFI safety test stubs

*Existing infrastructure covers remaining framework needs (cargo test built-in).*

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| XCFramework integrates in Xcode | CORE-07 | Requires Xcode GUI to verify linking | Build Swift test harness in Xcode, verify it links and runs |
| C# P/Invoke on Windows | CORE-08 | Requires Windows environment | Run dotnet test on Windows runner or VM |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 30s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
