---
phase: 15-rust-core-ffi-foundation
plan: 03
subsystem: auth-http
tags: [rust, auth, http, crypto, ed25519, reqwest, cookie-jar]
dependency_graph:
  requires: [15-02]
  provides: [ds3-http, ds3-auth, SharedHttpClient, CubbitAPIURLs, DS3Session]
  affects: [ds3-ffi, ds3-s3]
tech_stack:
  added: [urlencoding]
  patterns: [cookie-jar-auth, ed25519-challenge-response, rw-lock-interior-mutability]
key_files:
  created:
    - core/ds3-http/src/client.rs
    - core/ds3-http/src/urls.rs
    - core/ds3-http/src/projects.rs
    - core/ds3-http/src/keys.rs
    - core/ds3-http/tests/http_tests.rs
    - core/ds3-auth/src/crypto.rs
    - core/ds3-auth/src/challenge.rs
    - core/ds3-auth/src/login.rs
    - core/ds3-auth/src/refresh.rs
    - core/ds3-auth/src/session.rs
    - core/ds3-auth/tests/auth_tests.rs
  modified:
    - core/ds3-http/src/lib.rs
    - core/ds3-http/Cargo.toml
    - core/ds3-auth/src/lib.rs
    - core/ds3-auth/Cargo.toml
    - core/Cargo.toml
decisions:
  - "Used urlencoding crate for API key ID encoding in DELETE path"
  - "Extracted _refresh cookie manually from Set-Cookie headers (reqwest cookie jar is opaque)"
  - "Token expiry uses Unix timestamp (exp field) comparison via chrono::Utc::now()"
metrics:
  duration: 10m
  completed: 2026-05-27
  tasks_completed: 2
  tasks_total: 2
  tests_written: 20
  tests_passing: 20
---

# Phase 15 Plan 03: Auth + HTTP Crates Summary

Shared HTTP client with cookie jar, full Cubbit auth flow (SHA256+ed25519 challenge-response), token refresh, IAM forging, project listing, and API key CRUD

## Task Results

| Task | Name | Commit | Key Files |
|------|------|--------|-----------|
| 1 (RED) | ds3-http failing tests | 9303f9d | tests/http_tests.rs |
| 1 (GREEN) | ds3-http implementation | be3f78c | client.rs, urls.rs, projects.rs, keys.rs |
| 2 (RED) | ds3-auth failing tests | b8c7c6e | tests/auth_tests.rs |
| 2 (GREEN) | ds3-auth implementation | 84de269 | crypto.rs, challenge.rs, login.rs, refresh.rs, session.rs |

## What Was Built

### ds3-http crate
- **SharedHttpClient** wraps `reqwest::Client` with `cookie_store(true)` and default `Content-Type: application/json` header. Provides `get_json`, `post_json`, and `delete` helpers that validate HTTP status codes and deserialize JSON responses.
- **CubbitAPIURLs** generates all API endpoint URLs from a coordinator base URL (default: `https://api.eu00wi.cubbit.services`). Strips trailing slashes. Methods for challenge, signin, token refresh, forge JWT, accounts/me, projects, tenants, and keys endpoints.
- **get_projects** fetches projects via Composer Hub API with Bearer auth.
- **API key CRUD**: `load_api_keys`, `create_api_key`, `delete_api_key` (with URL-encoded key ID in path). `api_key_name` generates deterministic names matching the Swift pattern `ds3_drive({username}_{normalized_project}_{uuid})`.

### ds3-auth crate
- **sign_challenge** (crypto.rs): SHA-256(password + salt) -> 32-byte seed -> Ed25519 SigningKey -> sign challenge bytes -> base64 encode 64-byte signature. Produces byte-identical output to Swift's `signChallenge` using `Curve25519.Signing.PrivateKey(rawRepresentation:)` (D-12).
- **get_challenge** (challenge.rs): POST to IAM challenge endpoint with email and optional tenant_id.
- **post_signin** (login.rs): POST signin with signed challenge. Detects 2FA requirement (HTTP 401 + "missing two factor code" -> `DS3Error::Missing2FA`). Extracts `_refresh` cookie from Set-Cookie headers.
- **refresh_token** / **forge_iam_token** (refresh.rs): GET with `Cookie: _refresh={token}` header. Parses Token from JSON body and new refresh cookie from headers.
- **DS3Session** (session.rs): Opaque session handle with `RwLock<AccountSession>` for interior mutability. `authenticate()` orchestrates full flow (get_challenge -> sign_challenge -> post_signin -> get_account_info). `refresh_if_needed()` checks token.exp against UTC now. `forge_iam_token()` refreshes first then forges.
- **is_token_expired**: Compares token's Unix timestamp `exp` field against `chrono::Utc::now().timestamp()`.

## Verification Results

- `cargo test -p ds3-http`: 13 passed, 0 failed
- `cargo test -p ds3-auth`: 7 passed, 0 failed
- `cargo clippy -p ds3-http -p ds3-auth -- -D warnings`: clean, 0 warnings
- `cargo check --workspace`: clean, all crates compile
- Tracing `#[instrument(skip(...))]` verified on all functions handling credentials

## TDD Gate Compliance

- RED gate: `test(15-03)` commits at 9303f9d (http) and b8c7c6e (auth)
- GREEN gate: `feat(15-03)` commits at be3f78c (http) and 84de269 (auth)
- All tests failed in RED phase, all passed in GREEN phase

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Added urlencoding workspace dependency**
- **Found during:** Task 1 (keys.rs DELETE endpoint)
- **Issue:** API key IDs must be URL-encoded in the DELETE path (matching Swift's `addingPercentEncoding`), but no URL encoding utility was available
- **Fix:** Added `urlencoding = "2"` to workspace dependencies and ds3-http Cargo.toml
- **Files modified:** core/Cargo.toml, core/ds3-http/Cargo.toml

**2. [Rule 3 - Blocking] Manual _refresh cookie extraction**
- **Found during:** Task 2 (login.rs, refresh.rs)
- **Issue:** reqwest's built-in cookie jar is opaque -- cannot read stored cookies. The AccountSession struct requires the refresh_token value explicitly.
- **Fix:** Implemented `extract_refresh_cookie()` helper that parses `Set-Cookie` response headers for the `_refresh` cookie value. Used in both login and refresh response parsing.
- **Files modified:** core/ds3-auth/src/login.rs, core/ds3-auth/src/refresh.rs

## Threat Model Compliance

| Threat ID | Status | Evidence |
|-----------|--------|----------|
| T-15-04 | Mitigated | `#[instrument(skip(password, signed_challenge, token, bearer_token, iam_token, session, body))]` on all auth/http functions |
| T-15-05 | Mitigated | `DS3Error::ServerError` Display shows status code only; body stored in field for debug |
| T-15-06 | Mitigated | `CubbitAPIURLs::DEFAULT_COORDINATOR_URL` starts with `https://`; no `danger_accept_invalid_certs` calls |
| T-15-07 | Mitigated | Token expiry checked via `exp` field before use in `refresh_if_needed` |
| T-15-08 | Mitigated | `SigningKey::from_bytes` accepts any 32 bytes (infallible); `sign` is also infallible. Empty password test passes. |
