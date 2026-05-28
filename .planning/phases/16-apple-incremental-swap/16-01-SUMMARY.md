---
phase: 16-apple-incremental-swap
plan: 01
subsystem: infra
tags: [apple, ffi, uniffi, xcode, ci, xcframework, swiftpm, rust]

requires:
  - phase: 15-rust-core-ffi-foundation
    provides: DS3CoreFFI.xcframework with Ds3SessionHandle, UniFFI Swift bindings, ds3-models types
provides:
  - SPM .binaryTarget pulling core/out/DS3CoreFFI.xcframework into DS3Lib
  - Xcode Run Script Phase building the XCFramework on every Debug/Release build
  - CI workflow rustup install + XCFramework prebuild before xcodebuild
  - DS3CoreFFISmokeTests proving the FFI dispatch path round-trips
  - 16-FFI-AUDIT.md verdicts on assumptions A1 (flat_error), A2 (retry), A10 (Sendable)
  - Fixed core/scripts/build-xcframework.sh (was dropping ds3-ffi C surface + Swift bindings)
affects:
  - 16-02-PLAN.md (S3 adapter swap — depends on import DS3CoreFFI compiling)
  - 16-03-PLAN.md (Auth + SDK swap — depends on Ds3SessionHandle availability)
  - 16-04-PLAN.md, 16-05-PLAN.md, 16-06-PLAN.md, 16-07-PLAN.md (all downstream plans)

tech-stack:
  added:
    - "DS3CoreFFI XCFramework consumed via .binaryTarget(path:)"
    - "Swift glue target DS3CoreFFI re-exporting UniFFI bindings"
    - "Xcode Run Script Phase invoking cargo via build-xcframework.sh"
  patterns:
    - "Two-target SPM pattern: binary target (DS3CoreFFIBinary) + Swift glue target (DS3CoreFFI)"
    - "Unified Clang module DS3CoreFFIFFI containing both ds3-ffi and ds3-models C surfaces"
    - "Run Script Phase before Compile Sources on every linker target (D-08)"
    - "Cargo profile follows Xcode $CONFIGURATION (D-10)"

key-files:
  created:
    - ".planning/phases/16-apple-incremental-swap/16-FFI-AUDIT.md"
    - "apple/DS3Lib/Sources/DS3CoreFFI/DS3CoreFFI.swift (UniFFI generated, synced by build-xcframework.sh)"
    - "apple/DS3Lib/Sources/DS3CoreFFI/ds3_models.swift (UniFFI generated, synced by build-xcframework.sh)"
    - "apple/DS3Lib/Tests/DS3LibTests/DS3CoreFFISmokeTests.swift"
  modified:
    - "apple/DS3Lib/Package.swift (binary target + glue target + framework links)"
    - "apple/DS3Drive.xcodeproj/project.pbxproj (3 Run Script Phases registered + wired to targets)"
    - "core/scripts/build-xcframework.sh (step 3 unified modulemap + step 6 sync both Swift files)"
    - ".github/workflows/build.yml (rustup + xcframework prebuild on 3 jobs)"

key-decisions:
  - "Bind binary target as DS3CoreFFIBinary; expose DS3CoreFFI as the Swift glue target (avoids SPM target name collision with the module emitted by the XCFramework's modulemap)"
  - "Unify ds3-ffi + ds3-models C symbols under one module DS3CoreFFIFFI via custom module.modulemap; rewrite generated Swift bindings' canImport guards via sed (build-xcframework.sh)"
  - "Pin DS3CoreFFI glue target to Swift 5 mode; UniFFI auto-gen bindings use shared mutable globals (vtable pointers) that Swift 6 strict concurrency rejects. DS3Lib itself stays in Swift 6 mode."
  - "Link SystemConfiguration, CoreFoundation, Security, CFNetwork on the glue target so consumers (smoke tests, app targets) don't need to repeat these. The Rust transitive deps (hyper-util proxy detection, aws-sdk auth) pull symbols from these system frameworks."

patterns-established:
  - "Two-target SPM XCFramework wrapper: .binaryTarget(name: \"X-Binary\") + .target(name: \"X\", dependencies: [\"X-Binary\"]) — keeps the linker name and the import name decoupled so consumers can `import X` while SPM resolves the binary via X-Binary."
  - "UniFFI multi-scaffold-crate unification: write a single Headers/module.modulemap that exposes every *FFI.h under one Clang module name, then sed-rewrite generated Swift bindings' per-crate canImport/import lines to that unified name. Allows a single .binaryTarget to package N scaffolding crates."
  - "Run Script Phase position: BEFORE Compile Sources on every target that links the framework. Same script body across all three targets (DS3Drive, DS3DriveApp, DS3DriveProvider) — copy-paste-safe."

requirements-completed: [APPLE-01]

duration: ~50min
completed: 2026-05-28
---

# Phase 16 Plan 01: XCFramework Wiring Summary

**SPM .binaryTarget + Xcode Run Script + CI prebuild + smoke test linking `Ds3SessionHandle` via UniFFI through the DS3CoreFFI.xcframework, blocking issues in Phase 15's build script fixed atomically.**

## Performance

- **Duration:** ~50 min
- **Started:** 2026-05-28T10:23Z (XCFramework first manual build)
- **Completed:** 2026-05-28T10:42Z (Task 4 commit)
- **Tasks:** 4 of 5 executed; Task 5 is a CI-verification checkpoint deferred to merge time (see "User Setup Required" below).
- **Files modified:** 5 (1 Swift package, 1 Xcode project, 1 shell script, 1 CI workflow, 1 generated test); 4 created (audit doc, 2 generated bindings, smoke test).

## Accomplishments

- **Smoke test passes:** `swift test --filter DS3CoreFFISmokeTests` — 2/2 tests in 0.003s. `Ds3SessionHandle.self` resolves through the XCFramework, and the `conflictKey` free function round-trips Swift → C ABI → Rust → back.
- **`import DS3CoreFFI` works end-to-end:** the Swift glue target re-exports both ds3-ffi (Ds3SessionHandle) and ds3-models (Account, BucketInfo, free fns) surfaces under one module name. Plans 02-07 unblocked.
- **Build script bugs in Phase 15 fixed (Rule 1 deviations):** the step-3 modulemap loop was dropping one crate's C header; the step-6 Swift-file loop was clobbering DS3CoreFFI.swift with ds3_models.swift. Both fixed atomically with step changes that produce a unified module and sync both Swift bindings into the Apple source tree.
- **CI parity:** macOS app build, DS3Lib unit-test, and iOS app build jobs each install Rust targets, build the XCFramework first, and verify the artifact exists before invoking xcodebuild. Existing `rust-check` job untouched per plan instruction.
- **FFI assumptions verified:** Ds3Error is flat_error (each variant is `(message: String)`); Ds3SessionHandle is already `@unchecked Sendable`; aws-sdk-s3 retries via `behavior_version_latest()` but reqwest layer has no client-side retry. See 16-FFI-AUDIT.md for full verdicts including a Swift type-name reference card (Rust `DS3SessionHandle` → Swift `Ds3SessionHandle`, etc.).

## Task Commits

1. **Task 1: Audit FFI assumptions A1/A2/A10** — `d6a1a40` (docs)
2. **Task 2: Wire XCFramework into Apple build (Package.swift + Run Script Phase + script fixes)** — `fd18c68` (feat)
3. **Task 3: Add smoke tests + framework links** — `d89d76e` (test)
4. **Task 4: Build XCFramework in CI before xcodebuild** — `f56b1e7` (ci)

_Plan metadata commit will be issued by execute-plan.md harness._

## Files Created/Modified

- **Created:**
  - `.planning/phases/16-apple-incremental-swap/16-FFI-AUDIT.md` — verdicts on A1/A2/A10 + R-01/R-02/R-03 + Swift type-name reference table for Plans 02-07
  - `apple/DS3Lib/Sources/DS3CoreFFI/DS3CoreFFI.swift` — UniFFI-generated bindings (ds3-ffi: Ds3SessionHandle, conflictKey, computeDiff, getChallenge), synced from `core/out/` by build-xcframework.sh
  - `apple/DS3Lib/Sources/DS3CoreFFI/ds3_models.swift` — UniFFI-generated bindings (ds3-models: Account, BucketInfo, AccountSession, Token, Ds3Error, ...), synced by build-xcframework.sh
  - `apple/DS3Lib/Tests/DS3LibTests/DS3CoreFFISmokeTests.swift` — 2 tests proving the FFI dispatch path works end-to-end
- **Modified:**
  - `apple/DS3Lib/Package.swift` — added `.binaryTarget(DS3CoreFFIBinary)` + `.target(DS3CoreFFI)` glue target with system framework links; kept Soto/swift-nio for Plan 05 atomic removal
  - `apple/DS3Drive.xcodeproj/project.pbxproj` — added `PBXShellScriptBuildPhase` section with 3 phases (one per target: DS3Drive, DS3DriveApp, DS3DriveProvider), each calling `build-xcframework.sh` with profile mapped from `$CONFIGURATION`
  - `core/scripts/build-xcframework.sh` — step 3 writes unified `DS3CoreFFIFFI` modulemap covering both *FFI.h files; step 6 syncs both Swift binding files into apple/DS3Lib/Sources/DS3CoreFFI/ and sed-rewrites `import ds3_modelsFFI` → `import DS3CoreFFIFFI` (and the surrounding canImport guard)
  - `.github/workflows/build.yml` — added Rust install + rustup target add + XCFramework build + verify steps to 3 jobs (build, test-unit, build-ios) before each one's `xcodebuild` invocation

## Decisions Made

- **Binary target named DS3CoreFFIBinary (not DS3CoreFFI):** the SPM target name "DS3CoreFFI" is used by the Swift glue target so that consumers `import DS3CoreFFI`. A binary target with the same name would collide. Plan PLAN.md's verification grep (`binaryTarget(name: \"DS3CoreFFI\"`) does not literally match; the substance — a binary target wrapping `core/out/DS3CoreFFI.xcframework` — is satisfied. Documented as deviation below.
- **Unified Clang module DS3CoreFFIFFI:** UniFFI emits one modulemap per scaffolding crate (`ds3_modelsFFI`, `DS3CoreFFIFFI`). SPM `.binaryTarget` packages a single modulemap. Solution: write one modulemap that lists BOTH headers under one module name, then sed-rewrite the generated Swift to import that unified name. Avoids a second binary target for ds3-models.
- **Swift 5 mode pinned for the glue target:** UniFFI's generated vtable pointers are shared mutable globals; Swift 6 strict concurrency emits errors. We isolate the noise to one target (DS3CoreFFI) by setting `swiftLanguageMode(.v5)` on it; the rest of DS3Lib continues to enforce Swift 6.
- **System frameworks linked on the glue target:** Rust's hyper-util proxy detection + aws-sdk-s3 auth + system_configuration crate pull symbols from SystemConfiguration, CoreFoundation, Security, CFNetwork. Without these, even `swift test` fails to link. Linked at the glue target so DS3Lib and any downstream consumer inherit them automatically.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Phase 15 build script dropped ds3-ffi C surface from the XCFramework**

- **Found during:** Task 1 (FFI audit; XCFramework manual build for inspection)
- **Issue:** `core/scripts/build-xcframework.sh` step 3 used a `for ... break` loop that copied only the first-found `*FFI.modulemap` into the XCFramework's Headers/, dropping the other crate's C symbols entirely. Result: the previous build's XCFramework exposed only `ds3_modelsFFI` symbols (Account, BucketInfo); `Ds3SessionHandle` and all FFI methods were unreachable.
- **Fix:** Step 3 rewritten to copy ALL `*FFI.h` files and write a synthesized `module.modulemap` declaring a single `DS3CoreFFIFFI` module that includes every header.
- **Files modified:** `core/scripts/build-xcframework.sh`
- **Verification:** `cat core/out/DS3CoreFFI.xcframework/macos-arm64/Headers/module.modulemap` shows the unified module with both `ds3_modelsFFI.h` and `DS3CoreFFIFFI.h` headers. Smoke test `testConflictKeyFreeFunction` calls `conflictKey(...)` (a ds3-ffi free fn) and succeeds — that's only possible if its C symbol is linkable.
- **Committed in:** `fd18c68` (Task 2 commit)

**2. [Rule 1 - Bug] Phase 15 build script overwrote DS3CoreFFI.swift with ds3_models.swift**

- **Found during:** Task 1 (FFI audit; comparing `wc -l` of fresh uniffi-bindgen output vs script's final DS3CoreFFI.swift)
- **Issue:** Step 6's `for swift_file in "${OUT_DIR}"/*.swift; do ... break` loop picked the alphabetically-first file other than `DS3CoreFFI.swift` (= `ds3_models.swift`, 2591 lines) and copied it over `DS3CoreFFI.swift`, clobbering the freshly-generated 1467-line bindings file containing `Ds3SessionHandle` and FFI free functions. Result: `grep "DS3SessionHandle" core/out/DS3CoreFFI.swift` returned 0 hits.
- **Fix:** Step 6 rewritten to sync BOTH `DS3CoreFFI.swift` (preserved) and `ds3_models.swift` into `apple/DS3Lib/Sources/DS3CoreFFI/`, while sed-rewriting `ds3_models.swift`'s `import ds3_modelsFFI` lines (and the surrounding `#if canImport(ds3_modelsFFI)` guards) to the unified module name `DS3CoreFFIFFI` declared by step 3.
- **Files modified:** `core/scripts/build-xcframework.sh`
- **Verification:** Both files now exist at `apple/DS3Lib/Sources/DS3CoreFFI/` with `import DS3CoreFFIFFI` on the import line. `swift test --filter DS3CoreFFISmokeTests` passes: 2/2 tests in 0.003s.
- **Committed in:** `fd18c68` (Task 2 commit)

**3. [Rule 3 - Blocking] Swift bindings fail to link against test target without SystemConfiguration et al.**

- **Found during:** Task 3 (first `swift test` invocation)
- **Issue:** Linker errors with hundreds of `Undefined symbol "_kSCNetworkInterfaceTypeIPSec"`, `"_kSCPropNetProxiesHTTPEnable"`, etc. — the Rust transitive deps (hyper-util proxy matcher, system_configuration crate, aws-lc proxy auth) reference Apple system frameworks not pulled in automatically by SPM binary targets containing static libs.
- **Fix:** Added `linkerSettings: [.linkedFramework("SystemConfiguration"), .linkedFramework("CoreFoundation"), .linkedFramework("Security"), .linkedFramework("CFNetwork")]` to the `DS3CoreFFI` glue target so all downstream consumers inherit the framework links.
- **Files modified:** `apple/DS3Lib/Package.swift`
- **Verification:** `swift test --filter DS3CoreFFISmokeTests` → 2/2 passed.
- **Committed in:** `d89d76e` (Task 3 commit)

**4. [Rule 3 - Blocking] Cannot satisfy plan's literal verification grep `binaryTarget(name: "DS3CoreFFI"`**

- **Found during:** Task 2 (Package.swift edit)
- **Issue:** Plan PLAN.md's automated verification expected the binary target SPM name to be exactly `DS3CoreFFI`. Using that name causes a name collision with the Swift glue target (which must also be named `DS3CoreFFI` so consumers can `import DS3CoreFFI` and see the UniFFI Swift bindings). SPM rejects manifests with two targets sharing a name.
- **Fix:** Renamed the binary target `DS3CoreFFIBinary`; kept `DS3CoreFFI` as the Swift glue target name (matches `import DS3CoreFFI` in the smoke test and downstream plans). Substance — a `.binaryTarget` referencing `core/out/DS3CoreFFI.xcframework` exists — is satisfied. Literal grep does not match; updated to `grep -c 'binaryTarget(name: "DS3CoreFFIBinary"'`.
- **Files modified:** `apple/DS3Lib/Package.swift`
- **Verification:** `xcodebuild -resolvePackageDependencies -project apple/DS3Drive.xcodeproj -scheme DS3Drive` exits 0; `swift build` produces `apple/DS3Lib/.build/.../DS3CoreFFI.swiftmodule`.
- **Committed in:** `fd18c68` (Task 2 commit)

**5. [Rule 3 - Blocking] Pre-commit hook expected swiftlint/swiftformat configs at repo root**

- **Found during:** Task 2 commit attempt
- **Issue:** `.git/hooks/pre-commit` runs `swiftlint --config .swiftlint.yml --strict --quiet` and `swiftformat --config .swiftformat` from the worktree root. Configs live at `apple/.swiftlint.yml` and `apple/.swiftformat`. Hook failed with "Specified config file does not exist" for every commit involving Swift files.
- **Fix:** Created untracked relative symlinks at the worktree root: `.swiftlint.yml -> apple/.swiftlint.yml`, `.swiftformat -> apple/.swiftformat`. Did NOT commit these — they live only in this worktree to unblock the hook. The hook is a pre-existing infrastructure issue (the monorepo move left it pointing at root-level configs that no longer exist); fixing it permanently requires either moving configs to root or making the hook path-aware, both of which are out of scope for Plan 01.
- **Files modified:** none committed (symlinks are worktree-local, untracked)
- **Verification:** All 4 task commits succeeded with hooks running normally.
- **Committed in:** N/A (no committed artifacts).

---

**Total deviations:** 5 auto-fixed (2× Rule 1 Bug fix, 3× Rule 3 Blocking)
**Impact on plan:** Two of the five (R-01 + R-02 of the FFI audit) were Phase 15 carryover bugs that would have blocked every downstream plan. The other three were infrastructure plumbing necessary for the smoke test to link and commit. No scope creep — every fix is foundational to making the build work. **Plans 02-07 can now proceed.**

## Issues Encountered

- **Linker errors on first `swift test`:** addressed in deviation #3 above.
- **Plan verification grep too literal:** the SPM target naming constraint prevents a single SPM target from being both the binary and the Swift module. Resolved by renaming the binary target; updated downstream verification.
- **pbxproj manual editing fragility:** project.pbxproj is a 1600-line plist of UUID cross-references. Adding the Run Script Phases required (a) inserting new objects in `PBXShellScriptBuildPhase` section, (b) generating three unique UUIDs, (c) inserting those UUIDs at the START of three target `buildPhases` arrays. Verified via `xcodebuild -resolvePackageDependencies` post-edit.

## User Setup Required

**Task 5 was a `checkpoint:human-verify` for CI green on a draft PR.** In auto-mode (`workflow._auto_chain_active=true`), the checkpoint is auto-approved per the standard policy. The actual CI verification will happen when this worktree is merged into the phase branch `gsd/phase-16-apple-incremental-swap` and a PR is opened against `main`. At that point a human should:

1. Confirm GitHub Actions `build`, `test-unit`, and `build-ios` jobs run the new "Build DS3CoreFFI XCFramework" steps in order: rustup → script → verify → xcodebuild.
2. Confirm `rust-check` remains green (unchanged from Phase 15).
3. Run a fresh-clone smoke test on a colleague's machine: `git clone`, open `apple/DS3Drive.xcodeproj`, Cmd+B for the DS3Drive scheme. Verify the "Build DS3CoreFFI XCFramework" Run Script Phase appears in the build log.

This deferral is appropriate per plan note: "if a task requires user-only setup ... document the requirement in SUMMARY.md and proceed with what CAN be automated."

**Rust targets required on developer machines (Phase frontmatter `user_setup`):**

```bash
rustup target add aarch64-apple-darwin aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios
```

All four targets are already installed locally; CI installs them via the new `Install Rust targets` steps.

## Next Phase Readiness

- **Plan 02 (S3 adapter) is unblocked.** It needs a `ds3_error_code` UniFFI free function in `core/ds3-ffi/src/uniffi_exports.rs` (per FFI-AUDIT.md A1 verdict) for clean per-adapter translation tables; otherwise it can use case-name pattern matching on `Ds3Error.Missing2Fa(let msg)` etc. Either approach works.
- **Plan 03 (Auth + SDK) needs Ds3SessionHandle (verified `@unchecked Sendable`)** plus a new `current_session()` FFI fn for post-login persistence (per RESEARCH.md). That FFI fn is a Plan 02 or Plan 03 addition.
- **Open issues for follow-up:**
  - The DS3CoreFFI scheme might surface in Xcode but isn't currently tied to test action. Future devs running `xcodebuild test -scheme DS3Lib` (as the plan's literal verification asked) will fail; `swift test --package-path apple/DS3Lib` is the working path. Update plan templates if used elsewhere.
  - Pre-commit hook config-path issue (#5) should be fixed permanently — either move `.swiftlint.yml` / `.swiftformat` to repo root or rewrite the hook to `cd apple/` first.
  - Generated bindings (`apple/DS3Lib/Sources/DS3CoreFFI/*.swift`) are committed to make fresh clones work without running the build script first. They will be regenerated on every Xcode build and `git diff` may appear on routine builds (signature-only formatting drift from SwiftFormat). Acceptable for now; Plan 06 may revisit.

## Self-Check: PASSED

- `.planning/phases/16-apple-incremental-swap/16-FFI-AUDIT.md` — FOUND
- `apple/DS3Lib/Sources/DS3CoreFFI/DS3CoreFFI.swift` — FOUND
- `apple/DS3Lib/Sources/DS3CoreFFI/ds3_models.swift` — FOUND
- `apple/DS3Lib/Tests/DS3LibTests/DS3CoreFFISmokeTests.swift` — FOUND
- Commit `d6a1a40` — FOUND
- Commit `fd18c68` — FOUND
- Commit `d89d76e` — FOUND
- Commit `f56b1e7` — FOUND

---

*Phase: 16-apple-incremental-swap*
*Completed: 2026-05-28*
