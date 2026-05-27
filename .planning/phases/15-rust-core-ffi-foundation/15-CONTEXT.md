# Phase 15: Rust Core + FFI Foundation - Context

**Gathered:** 2026-05-27
**Status:** Ready for planning

<domain>
## Phase Boundary

Build a Cargo workspace with 6 crates (ds3-models, ds3-http, ds3-auth, ds3-s3, ds3-sync, ds3-ffi) that proves FFI to both Swift (UniFFI XCFramework) and C# (csbindgen P/Invoke). All FFI patterns established, integration tests passing against real Cubbit S3. No app-level code changes — this phase produces the Rust core library only.

The phase begins with a mono-repo restructure: existing code moves to `apple/`, Rust workspace lives in `core/`, empty `windows/` scaffolded.

</domain>

<decisions>
## Implementation Decisions

### Repo Restructure
- **D-01:** Phase 15 starts with the mono-repo restructure — move all existing code to `apple/`, create `core/` and `windows/` directories. Every subsequent plan builds in the new layout.
- **D-02:** Xcode project (DS3Drive.xcodeproj) moves fully into `apple/`. Xcode opens from the `apple/` directory.
- **D-03:** `.planning/` stays at repo root — it's cross-platform project management, not Apple-specific.
- **D-04:** Git LFS assets move with `apple/` — platform-specific assets live in their platform directories.
- **D-05:** Clean slate first — merge or close all open branches/PRs before the restructure commit.
- **D-06:** Root-level files (CLAUDE.md, .github/, .gitignore, LICENSE) stay at repo root. Update path references where needed.

### CI Pipeline
- **D-07:** CI builds both Rust core (cargo test, cargo clippy, cargo fmt) AND Apple (xcodebuild) from Phase 15 onward. GitHub Actions workflow updated after restructure.
- **D-08:** C# integration test runs in CI on a GitHub Actions Windows runner — builds C# console app, verifies P/Invoke against real Cubbit S3.

### S3 Client & HTTP
- **D-09:** reqwest for all non-S3 HTTP calls (auth, projects, keyvault APIs) — single HTTP stack via ds3-http crate with shared cookie jar.
- **D-10:** Cubbit S3 is fully standard S3 — no custom extensions or non-standard headers.
- **D-11:** Implement against the S3 API spec directly — don't mirror Soto's internal shapes. Phase 16 handles the Swift adapter layer.

### Crypto
- **D-12:** ed25519-dalek for Curve25519 auth crypto (challenge-response signing). Pure Rust, no OpenSSL dependency.

### XCFramework Delivery
- **D-13:** Rust toolchain required locally for all Apple developers — no pre-built XCFramework artifacts.
- **D-14:** One build script produces all three architecture targets (arm64-darwin, arm64-ios, x86_64-ios-simulator) bundled into a single XCFramework.

### Integration Tests
- **D-15:** Existing dedicated test bucket available for integration tests. Credentials provided by developer.
- **D-16:** Test credentials stored as GitHub Actions secrets. Tests read from environment variables.

### Claude's Discretion
- **S3 client library choice:** Researcher decides between aws-sdk-rust and reqwest+aws-sigv4 based on development speed (primary) and binary size (secondary). Cubbit S3 is fully standard, so both are viable.
- **XCFramework delivery mechanism:** Researcher decides between local path reference, SPM binary target, or Xcode build phase script based on UniFFI best practices.
- **Integration test CI schedule:** Researcher recommends whether integration tests run on every PR, nightly, or manual trigger based on expected test runtime and CI cost.

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Architecture & Design
- `docs/superpowers/specs/2026-05-26-cross-platform-rewrite-design.md` — Master design spec for the cross-platform rewrite. Contains crate structure, FFI boundary (~35 functions), session handle pattern, cfapi mapping, phase breakdown. PRIMARY reference.
- `.planning/REQUIREMENTS.md` §CORE-01 through §CORE-10 — Phase 15 requirements with success criteria
- `.planning/ROADMAP.md` §Phase 15 — Phase goal, dependencies, success criteria

### Existing Code (for porting reference)
- `DS3Lib/DS3Authentication.swift` — Current auth implementation (challenge-response, JWT, 2FA, token refresh). Port target for ds3-auth.
- `DS3Lib/DS3SDK.swift` — Current API client (projects, API keys, IAM token forging). Port target for ds3-http.
- `Provider/S3Lib.swift` — Current S3 operations (list, upload, download, delete, multipart). Port target for ds3-s3.
- `DS3Lib/Models/` — Current domain models (DS3Drive, SyncAnchor, Project, IAMUser, DS3ApiKey). Port target for ds3-models.

### Integration Points
- `.planning/codebase/INTEGRATIONS.md` — API endpoints, auth flow, credential storage patterns
- `.planning/codebase/ARCHITECTURE.md` — Current app architecture, data flows, key abstractions

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `DS3Authentication.swift` challenge-response flow: direct porting reference for ds3-auth crate
- `DS3SDK.swift` REST client: porting reference for ds3-http non-S3 endpoints
- `S3Lib.swift` S3 operations: porting reference for ds3-s3 crate (list, upload, download, multipart)
- `SharedData` JSON serialization: model schemas for ds3-models crate compatibility

### Established Patterns
- Session handle pattern: existing `DS3Authentication` manages session lifecycle — Rust `DS3Session` opaque handle mirrors this
- Error mapping: FileProvider requires `NSFileProviderErrorDomain`/`NSCocoaErrorDomain` only — Rust errors must map to numeric codes (design spec)
- Cookie-based auth: Cubbit IAM uses session cookies alongside JWT — ds3-http must preserve cookie jar across calls
- Multipart upload: existing implementation uses 5MB threshold with ETag validation — Rust must match

### Integration Points
- UniFFI XCFramework consumed by DS3Lib (Phase 16 swap point)
- csbindgen C header + DLL consumed by Windows DS3Drive.Core project (Phase 17)
- GitHub Actions CI — existing `build.yml` needs Rust + .NET steps added

</code_context>

<specifics>
## Specific Ideas

No specific requirements — open to standard approaches. Design spec provides comprehensive guidance.

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope

</deferred>

---

*Phase: 15-Rust Core + FFI Foundation*
*Context gathered: 2026-05-27*
