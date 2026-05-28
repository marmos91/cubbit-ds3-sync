# Phase 16: Apple Incremental Swap - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-05-28
**Phase:** 16-apple-incremental-swap
**Areas discussed:** Swap order, Auth adapter, XCFramework wiring, Error mapping, Testing strategy, Soto/CryptoKit removal timing, Migration validation, CI gates

---

## Swap Order

| Option | Description | Selected |
|--------|-------------|----------|
| S3 first, then Auth+SDK | DS3S3ClientProtocol clean boundary; lowest risk | ✓ |
| All at once | Single plan; bigger blast radius | |
| One at a time (3 steps) | S3 → Auth → SDK; max safety, max overhead | |

**User's choice:** S3 first, then Auth+SDK
**Notes:** —

### Sub-question: Adapter permanence

| Option | Description | Selected |
|--------|-------------|----------|
| Keep adapter forever | DS3S3ClientProtocol stays as public S3 API | ✓ |
| Adapter now, direct later | Phase 18 could revisit | |
| Direct from start | FileProvider uses DS3SessionHandle directly | |

**User's choice:** "What is the best architecture/design-wise?" — agent recommended Keep adapter forever (protocol is test seam, FileProvider is high-risk code, consistency with auth, no real benefit to direct access). User locked.

---

## Auth Adapter Pattern

| Option | Description | Selected |
|--------|-------------|----------|
| Keep shell, delegate internals | DS3Authentication keeps @Observable + persistence + UI state; delegates crypto/HTTP to DS3SessionHandle | ✓ |
| Thin wrapper around handle | Token storage moves to Rust; cleaner but invasive | |
| New class, migrate call sites | RustDS3Authentication parallel; biggest blast radius | |

**User's choice:** "Help me choose here. Remember: (a) same pattern for Windows/Android, (b) Apple enforces own APIs — don't move state that should be managed by Swift to Rust."
**Notes:** Agent recommended Option A. Pattern locks the cross-platform shape: platform owns Observable state primitive + native secure storage; Rust owns crypto + HTTP only. Cross-platform mapping (Apple @Observable + App Group, Windows ObservableObject + DPAPI, Android StateFlow + EncryptedSharedPreferences) captured as binding constraint. User followed up: "We should follow the same pattern on windows and android. Let's remember that."

---

## XCFramework Wiring

### Sub-question: How to wire XCFramework

| Option | Description | Selected |
|--------|-------------|----------|
| Local .binaryTarget(path:) | DS3Lib references local path | (subsumed by Run Script choice) |
| Xcode pre-build script phase | Run Script before Compile Sources | ✓ |
| SPM .binaryTarget(url:checksum:) | Hosted zip with checksum | |

**User's choice:** Xcode pre-build script phase.

### Sub-question: Pre-build behavior

| Option | Description | Selected |
|--------|-------------|----------|
| Smart skip on no-change | Check mtime/hash | |
| Always invoke cargo | Cargo's own incremental handles speed | ✓ |
| Manual rebuild only | Developer remembers | |

**User's choice:** Always invoke cargo.

### Sub-question: Debug vs Release

| Option | Description | Selected |
|--------|-------------|----------|
| Match Xcode config | Debug→--debug, Release→--release | ✓ |
| Always release | Optimized always | |
| Always debug except CI | Local debug, CI release | |

**User's choice:** Match Xcode config.

### Sub-question: Where attaches

| Option | Description | Selected |
|--------|-------------|----------|
| Xcode project Run Script phase | Standard Xcode pattern | ✓ (clarified) |
| SPM plugin | BuildToolPlugin invokes cargo | |
| Both: SPM resolves, Xcode rebuilds | "Belt + suspenders" | (initially picked but clarified) |

**User's choice:** "It seems to me that 3 is the best here. Can you confirm? What are best practices here?"
**Notes:** Agent clarified that Option 3 was misleading — SPM `.binaryTarget(path:)` is mandatory regardless (it's the linker contract); script just ensures the artifact at that path is fresh. So Option 3 is essentially Option 1 with the SPM line spelled out. Confirmed Option 1 with explicit SPM declaration as the canonical UniFFI pattern (Mozilla / Glean / Firefox AS). User locked.

---

## Error Mapping

### Sub-question: Rust DS3Error surface in Swift

| Option | Description | Selected |
|--------|-------------|----------|
| Map to existing Swift enums | Adapter throws DS3AuthenticationError / DS3SDKError / new DS3S3Error | ✓ |
| Pass DS3Error through directly | Call sites catch DS3Error; big churn | |
| Hybrid — unified for new, keep old | Three error families | |

**User's choice:** Map to existing Swift enums.

### Sub-question: Where translation lives

| Option | Description | Selected |
|--------|-------------|----------|
| Per-adapter translation | Each adapter owns its translation | ✓ |
| Single translation helper | DS3Error+Mapping.swift extension | |
| Throws + bubble (NSError code match) | Pattern-match on NSError.code | |

**User's choice:** Per-adapter translation.

### Sub-question: Soto re-exports

| Option | Description | Selected |
|--------|-------------|----------|
| Replace with DS3S3Error | Delete typealias, define new enum, fix call sites at compile time | ✓ |
| Keep typealias, point to new type | Hide migration behind alias | |
| Audit + decide per-site | Most fine-grained | |

**User's choice:** Replace with DS3S3Error.

### Sub-question: Progress callback failures

| Option | Description | Selected |
|--------|-------------|----------|
| Best-effort — swallow + log | Transfer continues; progress UX-only | ✓ |
| Abort transfer on callback failure | Defensive, new failure mode | |
| Callback gets no error channel | Fire-and-forget Void | |

**User's choice:** Best-effort — swallow + log.

### Sub-question: Retry policy

| Option | Description | Selected |
|--------|-------------|----------|
| Rust owns retries | ds3-http/ds3-s3 handle retries; cross-platform win | ✓ |
| Swift owns retries (current pattern) | Adapter wraps in retry-with-backoff | |
| Layered: Rust transport, Swift business | Rust 5xx, Swift auth-expired | |

**User's choice:** Rust owns retries.
**Notes:** Researcher must verify Phase 15 implementation actually has retry logic; if missing, add to Phase 16 Rust-side scope.

### Sub-question: Panic recovery

| Option | Description | Selected |
|--------|-------------|----------|
| Map panic → DS3Error.internal | Caught, graceful failure | ✓ |
| Hard crash — panic = bug | abort() | |
| Map panic → NSError diagnostic code | Bubble as DS3Error.unknown | |

**User's choice:** Map panic → DS3Error.internal
**Notes:** User asked "can the app still progress? How does it recover?" Agent explained: tokio runtime persists, DS3SessionHandle state survives panics in S3 calls (auth tokens unaffected), only in-flight transfer state is lost, orphaned multiparts recoverable via list_multipart_uploads + multipart_abort, user retries.

### Sub-question: FileProvider error visibility

| Option | Description | Selected |
|--------|-------------|----------|
| Provider extension owns it (Phase 16) | Existing catch blocks updated to catch DS3S3Error | ✓ |
| Defer to Phase 18 (POL-02) | Phase 16 stop-gap | |
| Adapter throws NSError directly | Adapter writes NSFileProviderErrorDomain | |

**User's choice:** Provider extension owns it (Phase 16).

### Sub-question: FFI boundary logging

| Option | Description | Selected |
|--------|-------------|----------|
| Yes — always log at FFI boundary | OSLog full DS3Error before throwing translated enum | ✓ |
| No — Swift catch sites log | Each catch site decides | |

**User's choice:** Yes — always log at FFI boundary.

### Sub-question: 2FA error path

| Option | Description | Selected |
|--------|-------------|----------|
| Map TfaRequired → DS3AuthenticationError.missing2FA | Existing LoginViewModel path preserved | ✓ |
| New error case — update LoginViewModel | Cleaner name | |

**User's choice:** Map TfaRequired → DS3AuthenticationError.missing2FA.

### Sub-question: Cancellation

| Option | Description | Selected |
|--------|-------------|----------|
| Out of scope Phase 16 — accept best-effort | block_on doesn't propagate Task.cancel() | |
| Add cancellation token to FFI | Extend ds3-ffi with CancellationHandle | ✓ |
| Researcher decides | Audit first | |

**User's choice:** Add cancellation token to FFI.
**Notes:** Expands Phase 15's FFI surface. Researcher should verify scope vs phase budget; multipart-only cancellation acceptable minimum, non-multipart deferrable to Phase 18.

---

## Testing Strategy

| Option | Description | Selected |
|--------|-------------|----------|
| Keep mocks via protocol, add integration tests | Mocks unchanged + new XCFramework integration tests | ✓ |
| Replace mocks with Rust-backed fake | In-memory Rust impl | |
| Mocks only — trust Phase 15 integration tests | Lowest confidence | |

**User's choice:** Keep mocks via protocol, add integration tests.

---

## Soto / CryptoKit Removal Timing

| Option | Description | Selected |
|--------|-------------|----------|
| Remove at end of swap | Final commit removes deps | |
| Remove as each component swaps | Per-commit removal | |
| Researcher decides | Depends on actual scattering | ✓ |

**User's choice:** Researcher decides.

---

## Migration Validation (APPLE-06)

| Option | Description | Selected |
|--------|-------------|----------|
| Snapshot tests + manual smoke | Codable + Rust serde decode equality + 1 manual upgrade | |
| Rust Codable parity in CI | CI step compares serde decode vs Swift Codable | ✓ |
| Manual upgrade smoke only | No automation | |

**User's choice:** Rust Codable parity in CI.

---

## CI Gates

| Option | Description | Selected |
|--------|-------------|----------|
| Symbol grep + dep tree check | Belt + suspenders | |
| Dep tree check only | Just SPM check | |
| Visual review in PR | Reviewer eyeballs | ✓ |

**User's choice:** Visual review in PR.

---

## Claude's Discretion

- S3 client library choice — already decided in Phase 15 (researcher's call)
- Soto/CryptoKit removal timing — explicitly deferred to researcher
- Integration test CI schedule — researcher decides based on test runtime + Cubbit S3 cost
- Auth/SDK swap sub-ordering within Auth+SDK plan — researcher decides
- `DS3SessionHandle` lifecycle in Swift (singleton / per-drive / per-call) — researcher decides

## Deferred Ideas

- NSFileProviderError mapping redesign → Phase 18 (POL-02)
- Cross-FFI structured logging (`tracing` → `os_log` bridge) → Phase 18 (POL-01)
- Non-multipart cancellation → Phase 18 if FFI expansion exceeds Phase 16 budget
- Automated Soto-symbol grep CI gate → Reconsider in Phase 18 if regressions appear
