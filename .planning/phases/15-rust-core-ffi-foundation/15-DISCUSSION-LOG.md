# Phase 15: Rust Core + FFI Foundation - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-05-27
**Phase:** 15-Rust Core + FFI Foundation
**Areas discussed:** Repo restructure timing, S3 client library, XCFramework delivery, Integration test infra

---

## Repo Restructure Timing

| Option | Description | Selected |
|--------|-------------|----------|
| Phase 15 starts with it | First plan: move all code to apple/, create core/ and windows/. Clean but big diff, breaks branches. | ✓ |
| Core alongside, restructure later | Add core/ next to existing code, defer full restructure. Less disruptive. | |
| Phase 15 ends with it | Build core/ first flat, then restructure as final plan. Proves Rust before restructure. | |

**User's choice:** Phase 15 starts with it
**Notes:** User wants clean layout from the start.

### Follow-up: Xcode Layout

| Option | Description | Selected |
|--------|-------------|----------|
| Full move to apple/ | DS3Drive.xcodeproj and all Apple code moves into apple/. Xcode opens from apple/. | ✓ |
| Xcode project stays at root | Keep .xcodeproj at root with references into apple/ subdirs. | |
| You decide | Let planner pick. | |

**User's choice:** Full move to apple/

### Follow-up: CI Scope

| Option | Description | Selected |
|--------|-------------|----------|
| CI builds both | GitHub Actions builds Rust (cargo test/clippy/fmt) AND Apple (xcodebuild). | ✓ |
| Rust CI only, Apple later | Phase 15 adds Rust CI. Apple CI updated in Phase 16. | |
| You decide | Let planner decide. | |

**User's choice:** CI builds both

### Follow-up: Planning Directory

| Option | Description | Selected |
|--------|-------------|----------|
| Stay at repo root | .planning/ is cross-platform, stays alongside core/, apple/, windows/. | ✓ |
| Move under apple/ | Keep close to the platform we've been working on. | |
| You decide | Let planner pick. | |

**User's choice:** Stay at repo root

### Follow-up: LFS Assets

| Option | Description | Selected |
|--------|-------------|----------|
| Move with apple/ | All Apple assets move into apple/. Windows gets its own assets dir. | ✓ |
| Shared assets/ at root | Extract shared brand assets to root, platform-specific in platform dirs. | |
| You decide | Let planner decide. | |

**User's choice:** Move with apple/

### Follow-up: Branch Management

| Option | Description | Selected |
|--------|-------------|----------|
| Clean slate first | Merge/close all open branches before restructure. | ✓ |
| Restructure, rebase later | Do restructure on main, branches rebase after. | |
| You decide | Let planner determine. | |

**User's choice:** Clean slate first

### Follow-up: Root Files

| Option | Description | Selected |
|--------|-------------|----------|
| Stay at root, update paths | CLAUDE.md, .github/, .gitignore, LICENSE stay at root. Update references. | ✓ |
| You decide | Let planner handle. | |

**User's choice:** Stay at root, update paths

---

## S3 Client Library

| Option | Description | Selected |
|--------|-------------|----------|
| aws-sdk-rust (official) | Full AWS SDK. Feature-rich, larger binary (~10-15MB). | |
| reqwest + aws-sigv4 | Lightweight, more manual, smaller binary (~2-3MB). | |
| You decide based on research | Researcher evaluates and recommends. | ✓ |

**User's choice:** Researcher decides. Development speed matters more than binary size.

### Follow-up: S3 Compatibility

| Option | Description | Selected |
|--------|-------------|----------|
| Fully standard S3 | Cubbit gateway is standard S3-compatible. No custom extensions. | ✓ |
| Some custom behavior | Cubbit-specific headers or behaviors. | |
| Not sure | Researcher should check. | |

**User's choice:** Fully standard S3

### Follow-up: HTTP Client Strategy

| Option | Description | Selected |
|--------|-------------|----------|
| reqwest for everything | ds3-http wraps reqwest for all HTTP. Single stack, shared cookie jar. | ✓ |
| AWS SDK for S3, reqwest for REST | Two HTTP stacks, each optimized for its domain. | |
| You decide | Researcher decides based on S3 client choice. | |

**User's choice:** reqwest for everything

### Follow-up: Soto Compatibility

| Option | Description | Selected |
|--------|-------------|----------|
| Match S3 spec directly | Implement against S3 API spec. Phase 16 handles Swift adapter. | ✓ |
| Mirror Soto signatures | Match Soto's function signatures for easier Phase 16 swap. | |
| You decide | Researcher analyzes Soto usage. | |

**User's choice:** Match S3 spec directly

### Follow-up: Crypto Crate

| Option | Description | Selected |
|--------|-------------|----------|
| ed25519-dalek | Pure Rust, well-audited, named in design spec. | ✓ |
| ring | Also pure Rust, different API. | |
| You decide | Researcher evaluates. | |

**User's choice:** ed25519-dalek

---

## XCFramework Delivery

| Option | Description | Selected |
|--------|-------------|----------|
| Local path reference | XCFramework referenced via local path. Simplest. Requires Rust toolchain. | |
| SPM binary target | Package.swift declares binaryTarget. Integrates with SPM workflow. | |
| Xcode build phase script | Run Script calls cargo build + uniffi-bindgen. Fully automatic. | |
| You decide | Researcher evaluates UniFFI best practices. | ✓ |

**User's choice:** Researcher decides delivery mechanism.

### Follow-up: Dev Workflow

| Option | Description | Selected |
|--------|-------------|----------|
| Rust required locally | Every dev installs Rust. Build from source. No binaries checked in. | ✓ |
| Pre-built downloadable | CI builds XCFramework, publishes as release artifact. | |
| You decide | Researcher recommends. | |

**User's choice:** Rust required locally

### Follow-up: Architecture Build

| Option | Description | Selected |
|--------|-------------|----------|
| One script, all targets | Single build-xcframework.sh cross-compiles all three targets. | ✓ |
| Per-target scripts | Separate builds per target. Developer picks which to build. | |
| You decide | Researcher decides. | |

**User's choice:** One script, all targets

---

## Integration Test Infra

| Option | Description | Selected |
|--------|-------------|----------|
| Existing test bucket | Dedicated test account + bucket already available. | ✓ |
| Need to create one | No test infrastructure yet. | |
| Use my dev account | Personal Cubbit account. | |

**User's choice:** Existing test bucket

### Follow-up: CI Schedule

| Option | Description | Selected |
|--------|-------------|----------|
| Every PR | Integration tests on every PR. Catches regressions immediately. | |
| Nightly only | Integration tests on schedule. PRs only run unit tests. | |
| Manual trigger | Developer triggers via workflow_dispatch. | |
| You decide | Researcher recommends. | ✓ |

**User's choice:** Researcher recommends schedule.

### Follow-up: C# Testing

| Option | Description | Selected |
|--------|-------------|----------|
| CI with .NET runner | Windows runner in CI builds C# app, tests P/Invoke against real S3. | ✓ |
| Manual Windows VM | C# tested manually. CI only verifies cbindgen header generation. | |
| You decide | Researcher evaluates feasibility. | |

**User's choice:** CI with .NET runner

### Follow-up: Credentials

| Option | Description | Selected |
|--------|-------------|----------|
| GitHub Actions secrets | Store as CI secrets. Tests read from env vars. | ✓ |
| Env file (local only) | .env file gitignored. CI skips integration tests. | |
| Both | Secrets for CI, .env for local. | |

**User's choice:** GitHub Actions secrets

---

## Claude's Discretion

- S3 client library choice (aws-sdk-rust vs reqwest+aws-sigv4) — researcher decides, development speed over binary size
- XCFramework delivery mechanism (local path, SPM binary target, or Xcode build phase) — researcher evaluates UniFFI best practices
- Integration test CI schedule (every PR, nightly, or manual trigger) — researcher recommends based on runtime/cost

## Deferred Ideas

None — discussion stayed within phase scope
