---
phase: 16-apple-incremental-swap
plan: 05
subsystem: apple-cleanup-dependencies
tags: [apple, cleanup, soto, cryptokit, dependencies, commoncrypto]

requires:
  - phase: 16-apple-incremental-swap
    plan: 03
    provides: DS3S3Client adapter, DS3S3Error (replaces SotoS3 + AWSErrorType)
  - phase: 16-apple-incremental-swap
    plan: 04
    provides: DS3Authentication + DS3SDK rewritten on Rust core (CryptoKit removed from auth path)
provides:
  - "DS3Lib Package.swift cleaned of Soto: only swift-atomics (production) + swift-nio (test-only) remain alongside the DS3CoreFFI binary target"
  - "SyncAnchorHash backed by CommonCrypto's CC_SHA256 with byte-identical wire-format vs the pre-swap CryptoKit implementation"
  - "10 fixture-locked regression tests pinning the NSFileProviderSyncAnchor format across the swap (T-16-05-01)"
affects:
  - "Phase 16 is now Soto-free at the SPM-manifest level — future plans no longer need to defer dependency removal"
  - "CryptoKit is fully removed from DS3Lib/Sources — auth path (Plan 04) and hashing path (Plan 05) both moved off Apple's high-level crypto API"

tech-stack:
  added:
    - "CommonCrypto (CC_SHA256) — already part of every Apple platform's libsystem, no new external dep"
  patterns:
    - "Pre-swap fixture lock-down: capture hex output from the about-to-be-replaced implementation, add it as an XCTest assertion BEFORE swapping the impl, prove byte-identity after the swap (Phase 16 Plan 05 RED/GREEN cycle)"
    - "Audit-then-decide dependency removal: grep for `import <module>` before deleting from Package.swift; keep the dep with a documented comment if any import survives (swift-nio kept for StreamingIOTests)"

key-files:
  created: []
  modified:
    - "apple/DS3Lib/Package.swift — removed Soto package + product; added explanatory comment for retained swift-nio (test-only); annotated DS3CoreFFI binaryTarget with Plan 05 context"
    - "apple/DS3Lib/Sources/DS3Lib/Enumeration/SyncAnchorHash.swift — swapped `import CryptoKit` → `import CommonCrypto`, added `sha256(_:)` helper, replaced two `SHA256.hash(data:)` call sites (formats unchanged: `v1:` prefix, `\\t`/`\\n` serialization, internal sort)"
    - "apple/DS3Lib/Tests/DS3LibTests/SyncAnchorHashTests.swift — 10 new fixture tests + concurrency reentrancy smoke; renamed `let a/let b` and switched `String(decoding:)` to `String(bytes:encoding:)` to satisfy swiftlint on staged tests"
    - "apple/DS3Lib/Package.resolved — soto, soto-core, async-http-client, swift-log, swift-metrics, jmespath.swift, swift-http-types, swift-nio-extras, swift-nio-http2, swift-nio-ssl, swift-nio-transport-services, swift-algorithms, swift-numerics dropped from the dependency graph (only swift-atomics + swift-nio + swift-collections/swift-system as nio transients remain)"
    - "apple/DS3Drive.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved — workspace-level resolved file regenerated; only swift-atomics remains (DS3Drive scheme doesn't pull NIOCore directly)"

decisions:
  - "D-05-01: Kept swift-nio in Package.swift because the audit found one import (NIOCore.ByteBuffer in StreamingIOTests). The test exercises a streaming-pattern pattern that no longer exists in production code, but per the plan's explicit guidance (`If hits exist → keep swift-nio`) we did not pre-emptively rewrite the test. A future audit can rewrite the test on plain Foundation.Data and drop the dep."
  - "D-05-02: Captured 10 fixture hex values (8 covering the 2-tuple `compute(over:)` API + 2 covering the WorkingSet variant) by running the current CryptoKit impl in a one-off Swift script BEFORE modifying SyncAnchorHash.swift. The fixtures landed in the test file in a separate commit (6d6b607) so the swap commit (60aa472) is provably a behavior-preserving refactor."
  - "D-05-03: SyncAnchorHash uses a single shared `sha256(_:)` helper (file-private free function) rather than duplicating the CC_SHA256 boilerplate in both `compute(over:)` and `computeWorkingSet(over:)`. This keeps the call sites readable and concentrates the unsafe pointer dance in one place."

metrics:
  duration: "~25 minutes from worktree spawn to last commit"
  completed: "2026-05-28T11:47:47Z"
  tasks_completed: 2
  tasks_checkpoint: 1
  files_changed: 5
  lines_changed: "+160 / -347"
  commits: 3

requirements:
  - "APPLE-04: Remove Soto v6 dependency from DS3Lib (deferred from earlier phases)"
---

# Phase 16 Plan 05: End-of-Phase Cleanup — Soto, CryptoKit, swift-nio Audit Summary

End-of-phase atomic removal of the Soto v6 dependency and `import CryptoKit` from DS3Lib. `SyncAnchorHash` swapped from `SHA256.hash(data:)` to `CommonCrypto.CC_SHA256` with byte-identical output locked by 10 pre-swap regression fixtures. Soto-free Package.swift verified by full DS3Lib test suite (560 tests, 0 failures), macOS DS3Drive build, and iOS DS3DriveApp build all green.

## Tasks Completed

### Task 1: Swap SyncAnchorHash from CryptoKit → CommonCrypto (TDD)

**RED (commit 6d6b607):** Added 10 fixture tests to `SyncAnchorHashTests.swift` capturing hex SHA256 output from the current CryptoKit implementation. Fixtures cover:

| Fixture | Input | Expected hex |
|---|---|---|
| empty | `[]` | `v1:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| plan-spec | `[("foo.txt","abc123"),("bar.txt","def456")]` | `v1:a06b1dd592aea7aaf1c89f8fa356bd3a303c09f43dda2d2932a13da7b228b9ca` |
| nil etag | `[("a", nil)]` | `v1:f3a1b852a7774425faa9e4fa1cd8f312f557bcb1a2cd22d256b241a802acba2a` |
| non-empty etag | `[("a", "1")]` | `v1:3db57393fc6220a0a72df6f0a1cc6334f89dba77b18362119ff15ce4568b5762` |
| Unicode | `[("café/ñ.txt","etag-üñ")]` | `v1:5c0165b0f3e9017818722e8c462dee6f4756be87fe0abc2e875757cfe6a7c3d5` |
| 1 KiB key | `[("x"*1024,"et")]` | `v1:5729e052b16952d3be43ad95e6f3ab28eaa041218b82d2ed593be05566a83db1` |
| 3-entry sorted | `[("a","1"),("b","2"),("c","3")]` | `v1:f33d90c11641869a9dedf73d83d7cd5babee8b0a19369912449e4551a918112b` |
| concurrent (32-thread) | plan-spec | same hex on all 32 threads |
| WorkingSet (no stamp) | `WorkingSetEntry(a,1,nil)` | `v1:21d072d4dec3af8937b13ed77a0ea8efecded58635a23208c8e0456aa2926602` |
| WorkingSet (with stamp) | `WorkingSetEntry(a,1, t=1234567890.5)` | `v1:0d004e8fd73fdd8e2ace7471ab15c750720d0d4e6df79d12903b555c12dc6d5f` |

All 10 passed on the unmodified CryptoKit implementation (baseline established).

**GREEN (commit 60aa472):** Replaced `import CryptoKit` with `import CommonCrypto` and added a file-private `sha256(_:)` helper backed by `CC_SHA256`. Both `compute(over:)` and `computeWorkingSet(over:)` call the same helper. The `v1:` prefix, `\t`/`\n` serialization, and internal sort all stayed intact.

```swift
private func sha256(_ data: Data) -> Data {
    var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
    data.withUnsafeBytes { _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &hash) }
    return Data(hash)
}
```

All 10 fixture tests passed post-swap. The remaining 6 behavioural-invariant tests (`testFormatPrefixIsV1`, `testEmptyInputProducesStableAnchor`, `testOrderInsensitive`, `testEtagChangeChangesAnchor`, `testKeyAddOrRemovalChangesAnchor`, `testNilEtagAndEmptyEtagHashIdentically`) also passed. Full DS3Lib suite: **560 tests, 2 skipped, 0 failures**.

### Task 2: Remove Soto + audit swift-nio (commit 6b8c11d)

**Audit findings:**

| Symbol | Production hits | Test hits | Disposition |
|---|---|---|---|
| `import SotoS3` | 0 | 0 | Removed Soto package + product |
| `import SotoCore` | 0 | 0 | (covered above) |
| `import NIOCore` | 0 | 1 (StreamingIOTests.swift L2) | **Keep** swift-nio in Package.swift |
| `import CryptoKit` | 0 (Task 1 removed the last one) | 0 | (final removal landed in this plan) |
| `import Crypto` (Apple's standalone) | 0 | 0 | Never used in DS3Lib |
| `AWSErrorType` / `S3ErrorType` references | comments only (`DS3S3Error.swift`, `FileProviderExtension+Errors.swift`, `DS3S3ErrorTranslationTests.swift`) | comments only | Intentional documentation of the legacy mapping that `DS3S3Error` replaces — kept |

**Package.swift before:**

```swift
dependencies: [
    .package(url: "https://github.com/soto-project/soto", from: "6.8.0"),
    .package(url: "https://github.com/apple/swift-atomics.git", from: "1.2.0"),
    .package(url: "https://github.com/apple/swift-nio.git", from: "2.62.0")
],
// DS3Lib target dependencies:
//   "DS3CoreFFI", .product(name: "SotoS3", package: "soto"), .product(name: "Atomics", package: "swift-atomics")
// DS3LibTests target dependencies:
//   "DS3Lib", "DS3CoreFFI", .product(name: "NIOCore", package: "swift-nio")
```

**Package.swift after:**

```swift
dependencies: [
    .package(url: "https://github.com/apple/swift-atomics.git", from: "1.2.0"),
    // swift-nio retained solely for `NIOCore.ByteBuffer` in
    // `DS3LibTests/StreamingIOTests.swift` (IEXT-03 streaming-pattern
    // smoke test). No production code in DS3Lib imports NIO after the
    // Soto removal in Phase 16 Plan 05.
    .package(url: "https://github.com/apple/swift-nio.git", from: "2.62.0")
],
// DS3Lib target dependencies:
//   "DS3CoreFFI", .product(name: "Atomics", package: "swift-atomics")
// DS3LibTests target dependencies:
//   "DS3Lib", "DS3CoreFFI", .product(name: "NIOCore", package: "swift-nio")
```

**Package.resolved cleanup:** Soto and all of its transitive dependencies drop out of `apple/DS3Lib/Package.resolved`:

- Removed: `soto`, `soto-core`, `async-http-client`, `swift-log`, `swift-metrics`, `jmespath.swift`, `swift-http-types`, `swift-nio-extras`, `swift-nio-http2`, `swift-nio-ssl`, `swift-nio-transport-services`, `swift-algorithms`, `swift-numerics`.
- Remaining: `swift-atomics` (1.3.0), `swift-nio` (2.96.0), `swift-collections` (1.4.0, transient of nio), `swift-system` (transient of nio).

`apple/DS3Drive.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` (workspace-level) collapses to just `swift-atomics` because the DS3Drive scheme does not link the DS3LibTests test bundle.

**Verification (automated):**

| Check | Result |
|---|---|
| `grep -rn 'import SotoS3\|import SotoCore\|import CryptoKit\|import Crypto[^F]' apple/` (excl. .planning/.build/Package.resolved) | 0 hits |
| `grep -c "import CommonCrypto" apple/DS3Lib/Sources/DS3Lib/Enumeration/SyncAnchorHash.swift` | 1 |
| `grep -rn 'import NIOCore' apple/` (excl. .planning/.build) | 1 (StreamingIOTests.swift only — expected) |
| `swift test --skip Integration` (apple/DS3Lib) | 560 tests, 2 skipped, 0 failures |
| `xcodebuild build -scheme DS3Drive -destination platform=macOS` | BUILD SUCCEEDED |
| `xcodebuild build -scheme DS3DriveApp -destination generic/platform=iOS` | BUILD SUCCEEDED |
| `Package.resolved` no longer contains `soto-project/soto` | confirmed |

### Task 3: Checkpoint — Human visual PR review (D-27)

**Status:** Pending human review (not auto-approved; `autonomous: false`).

The orchestrator's prompt instructed this executor to "proceed with all automatable removal work; document any items needing manual PR-review in SUMMARY.md." Task 3 is the visual PR-review gate per D-27 (no automated grep can fully replace reviewer eyes on a dependency-removal PR). The checklist below mirrors the plan's `<how-to-verify>` block — a human reviewer should walk through it before merging.

**Reviewer checklist:**

1. Open the PR diff of `apple/DS3Lib/Package.swift`. Confirm:
   - REMOVED: `.package(url: "https://github.com/soto-project/soto", ...)` line
   - REMOVED: `.product(name: "SotoS3", package: "soto")` from DS3Lib target dependencies
   - UNCHANGED: `.binaryTarget(name: "DS3CoreFFIBinary", ...)` (Plan 01)
   - UNCHANGED: `swift-atomics` declaration
   - KEPT (with explanatory comment): `swift-nio` dependency + `NIOCore` testTarget product
2. Open `apple/DS3Lib/Package.resolved` and confirm no `soto-project/soto` entries remain.
3. Run locally: `grep -rn 'SotoS3\|SotoCore\|AWSErrorType\|S3ErrorType' apple/ | grep -v .planning | grep -v Package.resolved` — must return only docstring/comment references (no `import` lines, no live symbol uses).
4. Run locally: `grep -rn 'import CryptoKit\|import Crypto\b' apple/DS3Lib/Sources/` — must return 0 lines.
5. Confirm `grep -rn 'import CommonCrypto' apple/DS3Lib/Sources/DS3Lib/Enumeration/SyncAnchorHash.swift` returns exactly 1 line.
6. Open `apple/DS3Lib/Tests/DS3LibTests/SyncAnchorHashTests.swift` and confirm captured pre-swap hex values are committed verbatim (not stub placeholders).
7. Run locally: `cd apple/DS3Lib && swift test --skip Integration` — full suite must pass.
8. Optional: Build & launch DS3 Drive on a developer machine, log into Cubbit, set up a drive, verify the existing `NSFileProviderSyncAnchor` in `~/Library/Group Containers/group.X889956QSM.io.cubbit.DS3Drive/drives.json` still parses and the drive's enumerator does not trigger a full re-enumeration. (Confirms anchor byte-equality on a real persisted anchor — the fixture tests already prove this analytically.)

## Deviations from Plan

**1. [Rule 3 — Tooling] Local pre-commit hook required swiftlint config symlinks**

- **Found during:** Task 1 RED commit
- **Issue:** The `pre-commit` git hook expects `.swiftformat` and `.swiftlint.yml` in the repo root, but those configs live under `apple/`. From the worktree root, the hook aborted with "Specified config file does not exist".
- **Fix:** Added two symlinks (`.swiftformat -> apple/.swiftformat`, `.swiftlint.yml -> apple/.swiftlint.yml`) in the worktree root. These are unignored but local-only artifacts (not staged in any commit).
- **Files modified:** worktree-local symlinks only (not committed)
- **Commit:** N/A

**2. [Rule 3 — Tooling] Pre-existing swiftlint violations exposed by staged-files lint**

- **Found during:** Task 1 RED commit
- **Issue:** The hook's swiftlint run flagged 4 violations: 2 short-name (`let a` / `let b` in `testEmptyInputProducesStableAnchor`) and 2 `optional_data_string_conversion` (use `String(bytes:encoding:)` not `String(decoding:as:)`). All four were pre-existing in the unmodified `SyncAnchorHashTests.swift` file and not introduced by Plan 05.
- **Fix:** Renamed `let a` → `let first`, `let b` → `let second`, and replaced both `String(decoding:as:)` call sites with `String(bytes:encoding:)` (with a `?? ""` fallback — anchor bytes are always 7-bit ASCII so the failable initializer is non-nil for valid inputs).
- **Files modified:** `apple/DS3Lib/Tests/DS3LibTests/SyncAnchorHashTests.swift`
- **Commit:** `6d6b607` (rolled into the test commit; documented in the commit message)

**3. [Rule 3 — Tooling] XCFramework cache rebuild**

- **Found during:** First test attempt
- **Issue:** The cached `core/out/DS3CoreFFI.xcframework` in the worktree had a stale `DS3CoreFFIFFI.h` header missing the `ffi_ds3_models_*` symbols that `Sources/DS3CoreFFI/ds3_models.swift` references. Compilation failed with "cannot find 'RustBuffer' in scope". This is a pre-existing worktree-environment issue, not a Plan 05 change.
- **Fix:** Ran `cd core && ./scripts/build-xcframework.sh --debug` in the main repo and `rsync`'d `core/out/` into the worktree. The rebuilt XCFramework correctly packages both `DS3CoreFFIFFI.h` and `ds3_modelsFFI.h`. The build script also overwrote the checked-in `Sources/DS3CoreFFI/*.swift` glue with a freshly-regenerated version; those file diffs were reverted (`git checkout HEAD -- ...`) to keep this plan focused on Soto/CryptoKit removal.
- **Files modified:** none committed (XCFramework is gitignored; glue files were reverted)

## Stub tracking

No stubs introduced. All implementation is complete: SyncAnchorHash uses CC_SHA256 end-to-end, Package.swift declares only the dependencies it needs.

## Threat surface

The plan's `<threat_model>` was applied verbatim:

| Threat ID | Disposition status |
|---|---|
| T-16-05-01 (anchor format drift) | Mitigated — 10 pre-swap fixtures in SyncAnchorHashTests lock the wire format |
| T-16-05-02 (undeclared transitive NIOCore dep) | Mitigated — audit found exactly 1 NIOCore import (StreamingIOTests); swift-nio retained with explanatory comment |
| T-16-05-03 (stale Soto in dead-code paths) | Mitigated — 0 `import SotoS3`/`import SotoCore` hits in apple/; remaining `AWSErrorType` matches are documentation comments referencing the replaced mapping |
| T-16-05-04 (`import Crypto` spoofing) | Mitigated — grep `'import Crypto[^F]'` returned 0; only `import CommonCrypto` and `import Foundation` remain in the touched files |
| T-16-05-SC (package install supply-chain) | N/A — this plan only **removes** packages, no new installs |

No new threat flags discovered.

## Deferred Issues

**StreamingIOTests can probably be rewritten on Foundation.Data alone** to drop the swift-nio dependency entirely. The test currently constructs a `NIOCore.ByteBuffer` only to call `withUnsafeReadableBytes` and verify zero-copy file writes — that pattern is expressible on `Data` with no behavioural loss. The plan explicitly punted this rewrite ("If hits exist → keep swift-nio") so it's tracked here for a future cleanup phase. Approximate cost: ~30 minutes including a fresh `Package.resolved` regeneration.

## Final commits in this plan

| Commit | Type | Description |
|---|---|---|
| `6d6b607` | test | Lock SyncAnchorHash SHA256 wire format with pre-swap fixtures |
| `60aa472` | feat | Swap SyncAnchorHash from CryptoKit to CommonCrypto |
| `6b8c11d` | feat | Remove Soto from DS3Lib Package.swift |

## Self-Check: PASSED

- `apple/DS3Lib/Package.swift`: FOUND, Soto product/dependency lines removed
- `apple/DS3Lib/Sources/DS3Lib/Enumeration/SyncAnchorHash.swift`: FOUND, uses `import CommonCrypto`
- `apple/DS3Lib/Tests/DS3LibTests/SyncAnchorHashTests.swift`: FOUND, 10 fixture tests committed
- Commit `6d6b607`: FOUND in `git log`
- Commit `60aa472`: FOUND in `git log`
- Commit `6b8c11d`: FOUND in `git log`
- `grep -c "import CommonCrypto" apple/DS3Lib/Sources/DS3Lib/Enumeration/SyncAnchorHash.swift`: 1 (expected 1)
- `grep -rn 'import SotoS3\|import SotoCore\|import CryptoKit\|import Crypto[^F]' apple/` (filtered): 0 (expected 0)
- `swift test --skip Integration` (apple/DS3Lib): 560 tests, 0 failures
- `xcodebuild build` macOS + iOS: both BUILD SUCCEEDED
