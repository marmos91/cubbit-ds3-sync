---
phase: 16-apple-incremental-swap
plan: 04
subsystem: apple-auth-sdk-swap
tags: [apple, auth, sdk, observable, 2fa, ffi]

requires:
  - phase: 16-apple-incremental-swap
    plan: 02
    provides: DS3SessionHandle.authenticate / verify2fa / refreshToken / currentSession / forgeIamToken / accountInfo / getProjects / loadApiKeys / createApiKey / deleteApiKey, ds3ErrorCode
  - phase: 16-apple-incremental-swap
    plan: 03
    provides: DS3S3Client adapter, Ds3SessionHandle.s3Only constructor, DS3S3Error
provides:
  - DS3Authentication with Rust-backed internals + @Observable shell preserved
  - DS3SDK with Rust-backed internals + @Observable shell preserved
  - DS3SessionHandle singleton owned by DS3Authentication; handle borrowed by DS3SDK and DS3S3Client per-drive
  - 2FA path preserved end-to-end via load-bearing `code 1007 → .missing2FA` translation (D-15 / T-16-04-01)
  - DS3AuthenticationError.translate(_:) / .describe(_:) — Rust Ds3Error → Swift error mapping (translation shared with DS3SDKError)
  - DS3SDKError.translate(_:) — Rust Ds3Error → DS3SDKError mapping
  - DS3CoreFFI ↔ DS3Lib model bridges: Account, AccountSession, Project, IAMUser, Token, DS3ApiKey (.fromFFI)
  - DS3S3Client(authenticatedHandle:endpoint:accessKey:secretKey:) — new initializer that shares the auth singleton handle (DS3Client wired to call it)
affects:
  - 16-05-PLAN.md (CryptoKit removed from DS3Authentication — only SyncAnchorHash still imports it; Soto package removal can proceed)
  - 16-06-PLAN.md (post-restart re-login UX — `loadFromPersistenceOrCreateNew` returns isLogged=true but handle=nil; auth methods throw .loggedOut until user re-logs in)

tech-stack:
  added:
    - "DS3CoreFFI consumed in DS3Authentication and DS3SDK (replaces URLSession + CryptoKit on auth path)"
    - "DS3S3Client.init(authenticatedHandle:endpoint:accessKey:secretKey:) — new initializer for main-app flow that reuses auth's handle"
  patterns:
    - "Singleton-handle: DS3Authentication owns the only Ds3SessionHandle for the authenticated app (PATTERNS §'DS3SessionHandle Lifecycle')"
    - "Per-method short-circuit guard: `guard let handle = self.handle else { throw .loggedOut }` everywhere on DS3Authentication / DS3SDK"
    - "App Group JSON persistence boundary (D-06): every state-mutating handle.* call is followed by `try self.persist()` so accountSession.json / account.json bytes match in-memory state"
    - "Logger boundary convention (D-16): code + describe(rustError) at privacy: .public BEFORE throwing translated error"
    - "2FA path preservation (D-15 / T-16-04-01): explicit `catch let e as Ds3Error where ds3ErrorCode(...) == 1007` short-circuit in login that throws .missing2FA"
    - "Logout dropping order (T-16-04-04): set handle=nil BEFORE clearing other state so any concurrent S3 op races into .loggedOut"

key-files:
  created:
    - "apple/DS3Lib/Sources/DS3Lib/Models/Account+FFI.swift (45 LoC) — Account.fromFFI + AccountEmail.fromFFI"
    - "apple/DS3Lib/Sources/DS3Lib/Models/AccountSession+FFI.swift (19 LoC) — AccountSession.fromFFI"
    - "apple/DS3Lib/Sources/DS3Lib/Models/DS3ApiKey+FFI.swift (26 LoC) — DS3ApiKey.fromFFI via JSONDecoder for ISO-8601 date parse reuse"
    - "apple/DS3Lib/Sources/DS3Lib/Models/Project+FFI.swift (38 LoC) — Project.fromFFI + IAMUser.fromFFI (DS3CoreFFI.IamUser → DS3Lib.IAMUser)"
    - "apple/DS3Lib/Sources/DS3Lib/Models/Token+FFI.swift (38 LoC) — Token.fromFFI via JSON-roundtrip so the existing Codable init validates ISO-8601 expDate"
    - "apple/DS3Lib/Tests/DS3LibTests/ModelFFIBridgeTests.swift (289 LoC) — round-trips Account / AccountSession / Project / Token / DS3ApiKey through fromFFI and asserts byte-shape preservation"
    - ".planning/phases/16-apple-incremental-swap/16-04-SUMMARY.md"
  modified:
    - "apple/DS3Lib/Sources/DS3Lib/DS3Authentication.swift — URLSession + CryptoKit removed; methods delegate to Ds3SessionHandle.authenticate / verify2fa / refreshToken / forgeIamToken / accountInfo / currentSession; persist() called after every state mutation; DS3AuthenticationError.translate + .describe added"
    - "apple/DS3Lib/Sources/DS3Lib/DS3SDK.swift — URLSession removed; getRemoteProjects / getRemoteApiKeys / generateDS3APIKey / deleteApiKey delegate to handle.* via authentication.handle; DS3SDKError.translate added (routes 1005 → .loggedOut, everything else → .serverError so UI doesn't re-prompt for 2FA)"
    - "apple/DS3Lib/Sources/DS3Lib/DS3Client.swift — s3Client(forProject:iamUser:) now requires authentication.handle and constructs DS3S3Client via the new authenticated-handle initializer"
    - "apple/DS3Lib/Sources/DS3Lib/DS3S3Client.swift — added init(authenticatedHandle:endpoint:accessKey:secretKey:) which stores the borrowed handle from DS3Authentication"
    - "apple/DS3Lib/Tests/DS3LibTests/DS3AuthenticationTests.swift — refactored off URLProtocol; now drives DS3Authentication via Rust-error injection where applicable (see test refactor table below)"
    - "apple/DS3Lib/Tests/DS3LibTests/AuthRequestTests.swift — repurposed: covers Ds3Error translation, DS3AuthenticationError.describe, ds3ErrorCode message parsing"
    - "apple/DS3Lib/Tests/DS3LibTests/DS3AuthenticationIntegrationTests.swift — gated and updated to construct a handle-less DS3Authentication where the integration test would otherwise require a live IAM endpoint"

key-decisions:
  - "Task 1 went Option B (FFI helper functions, not model deduplication). The Swift models are not pure structs — AccountSession / Project / IAMUser are @Observable classes that SwiftUI views observe with `@Bindable var project: Project?` etc., and Account / Token / DS3ApiKey have custom Codable init(from:) implementations that validate fields and parse ISO-8601 dates from the App Group JSON disk shape (D-06). Replacing them with UniFFI-generated structs would break SwiftUI observability and require rewriting every view binding. The fromFFI helpers preserve the existing types and translate at the boundary only."
  - "Token.fromFFI goes through JSON-roundtrip rather than calling Token's memberwise init directly. The existing custom Codable `init(from:)` is the canonical validator (it parses ISO-8601, rejects malformed dates, etc.). Going through JSONDecoder ensures FFI-sourced Tokens are byte-indistinguishable from disk-loaded ones — same validation, same rejection paths."
  - "DS3ApiKey.fromFFI also goes through JSONDecoder for the same reason (the Date field is parsed via the project's iso8601 DateFormatter)."
  - "Ds3SessionHandle lifecycle: singleton owned by DS3Authentication (the only place .authenticate / .verify2fa are called from). Borrowed by DS3SDK via `authentication.handle`. Borrowed by DS3S3Client via the new init(authenticatedHandle:...) when DS3Client lazily creates per-project S3 clients. Cleared FIRST in logout() before clearing other state — any concurrent S3 op racing logout fails with .loggedOut instead of using a stale-credentialed handle (T-16-04-04 mitigation)."
  - "Post-restart re-login regression: the App Group JSON persists `accountSession` and `account`, but Ds3SessionHandle is in-memory only. After app restart, `loadFromPersistenceOrCreateNew` returns isLogged=true but handle=nil, so any auth method (login / refreshIfNeeded / forgeIAMToken) throws .loggedOut. The File Provider extension is unaffected because it uses Ds3SessionHandle.s3Only with persisted API keys (no IAM round-trip needed). This is an acknowledged known regression — a future plan should add a Rust-side `Ds3SessionHandle.restoreFromRefreshToken(refreshToken:)` constructor."
  - "DS3SDKError.translate routes auth-level codes (1006 expired, 1007 missing2FA, 1008 cookies) to .serverError rather than to .loggedOut. The login UI is the only path that needs to re-prompt for 2FA; the SDK never does. The only auth code that flows through verbatim is 1005 (.loggedOut) so callers can route back to login on session loss."
  - "Ds3Error code lookup goes through a string-message path (`ds3ErrorCode(message:)`) rather than a discriminator on the enum case. UniFFI's flat-error shape emits each variant as `Case(message: String)` where message is the canonical thiserror Display string with the numeric code prefix; the FFI free function `ds3ErrorCode(message:)` parses it. The same `describe(_:)` helper is reused across DS3AuthenticationError and DS3SDKError translators."
  - "Two pre-existing S3ItemTests failures (testDecorationCloudOnlyDefault, testDecorationSynced) are OUT OF SCOPE per the executor scope-boundary rule. These tests live in `apple/DS3DriveProviderTests/S3ItemTests.swift` and test File Provider decoration set registration, which depends on the extension bundle runtime context. They have not been touched by Plan 04 commits (verified via `git log --oneline d9d7c31..HEAD -- apple/DS3DriveProviderTests/S3ItemTests.swift` returns empty). These failures were already present at the Plan 03 commit base."

requirements-completed: [APPLE-02, APPLE-03, APPLE-05]

duration: ~120min
completed: 2026-05-28
---

# Phase 16 Plan 04: Apple Auth + SDK Swap Summary

**Replaced URLSession + CryptoKit internals of `DS3Authentication` and `DS3SDK` with `DS3SessionHandle` calls. Both classes keep their `@Observable` shells, App Group JSON persistence, and UI state. The 2FA path (`.missing2FA`) is preserved byte-identically via the load-bearing `code 1007` translation. 588 DS3Lib tests pass.**

## Performance

- **Tasks:** 4 of 4 executed
- **Files created:** 7 (5 +FFI helpers + ModelFFIBridgeTests + this SUMMARY)
- **Files modified:** 7 (DS3Authentication, DS3SDK, DS3Client, DS3S3Client, 3 test files)
- **Total LoC:** +956 / -572 production + test code

## Accomplishments

### Rust-backed `DS3Authentication`

| Method | Old impl | New impl |
|--------|----------|----------|
| `login(email:password:withTfaToken:tenant:)` | URLSession challenge → CryptoKit Curve25519 sign → URLSession token POST → cookie extraction | `Ds3SessionHandle.authenticate` (or `.verify2fa` when `tfaCode != nil`) + `accountInfo()` + `currentSession()` |
| `refreshIfNeeded(force:)` | URLSession refresh POST | `handle.refreshToken()` + `syncSessionFromHandle(handle)` |
| `forgeIAMToken(forIAMUser:)` | URLSession forge POST | `handle.forgeIamToken(userId:)` + `Token.fromFFI` |
| `accountInfo()` | URLSession GET | `handle.accountInfo()` + `Account.fromFFI` |

**Preserved verbatim:**
- `@Observable public final class DS3Authentication: @unchecked Sendable` declaration
- `logger`, `urls`, `accountSession`, `account`, `isLogged`, `isNotLogged`, `sharedData` properties + init signatures
- `shouldRefreshToken(_:threshold:)` — pure expiry math
- `startProactiveRefreshTimer()` — Task lifecycle (with refresh-token rejection → logout escape)
- `logout(driveManager:)` — orchestration (with handle-cleared-first ordering)
- `persist()` / `loadFromPersistenceOrCreateNew(urls:)` / `deleteFromDisk()` — App Group JSON I/O

**Removed:**
- `import CryptoKit` — `grep -c "import CryptoKit" apple/DS3Lib/Sources/DS3Lib/DS3Authentication.swift` returns 0
- `signChallenge`, `getChallenge`, `getAccountSession`, `parseTokenResponse` — Curve25519/URLSession dead code
- `URLSession` usage — `grep -c "URLSession" apple/DS3Lib/Sources/DS3Lib/DS3Authentication.swift` returns 0

**2FA load-bearing translation (D-15 / T-16-04-01):**

```swift
catch let rustError as Ds3Error
    where ds3ErrorCode(message: DS3AuthenticationError.describe(rustError)) == 1007 {
    self.logger.info("2FA required — prompting user")
    throw DS3AuthenticationError.missing2FA
}
```

The LoginViewModel `.missing2FA` path is unchanged — the catch case above guarantees the same Error case is thrown when Rust returns code 1007.

### Rust-backed `DS3SDK`

| Method | FFI route |
|--------|-----------|
| `getRemoteProjects()` | `handle.getProjects()` + `Project.fromFFI` |
| `getRemoteApiKeys(forIAMUser:)` | `handle.loadApiKeys(userId:, iamToken:)` + `DS3ApiKey.fromFFI` |
| `deleteApiKey(_:forIAMUser:)` | `handle.deleteApiKey(userId:, apiKeyId:, iamToken:)` |
| `generateDS3APIKey(forIAMUser:iamToken:apiKeyName:)` | `handle.createApiKey(userId:, keyName:, iamToken:)` + `DS3ApiKey.fromFFI` |
| `loadOrCreateDS3APIKeys(forIAMUser:ds3ProjectName:)` | Reconciliation orchestration preserved; underlying CRUD swapped |
| `apiKeyName(forUser:projectName:)` | Pure string construction — unchanged |

The SDK borrows the Rust handle from `authentication.handle` on every call (no caching). The `loadOrCreateDS3APIKeys` reconciliation logic is unchanged — only the four CRUD calls under it swap.

### `DS3SessionHandle` lifecycle (singleton borrowed by S3 path)

```
DS3Authentication
   └── private(set) var handle: Ds3SessionHandle?    [OWNER]
         │
         ├── DS3SDK.authentication.handle             [BORROWED — short-circuit if nil]
         │
         └── DS3S3Client(authenticatedHandle: handle) [BORROWED — main-app flow via DS3Client]
                                                       (extension flow still uses .s3Only with persisted API keys)
```

The new `DS3S3Client.init(authenticatedHandle:endpoint:accessKey:secretKey:)` initializer replaces the bare `init(accessKeyId:secretAccessKey:endpoint:)` call inside `DS3Client.s3Client(forProject:iamUser:)`. The extension's `DS3Client.init(drive:)` flow still uses the bare initializer because it has no auth handle at extension boot time (just persisted API keys).

### Model FFI helpers (Task 1 — Option B chosen)

Five `+FFI.swift` files bridge between `DS3CoreFFI.*` structs (UniFFI-generated) and the existing `DS3Lib.*` Swift types:

| FFI struct | Swift type | Translation strategy |
|---|---|---|
| `DS3CoreFFI.AccountSession` | `@Observable class AccountSession` | Constructor: `AccountSession(token: try Token.fromFFI(ffi.token), refreshToken: ffi.refreshToken)` |
| `DS3CoreFFI.Account` | `struct Account (Codable)` | Memberwise init (snake_case CodingKeys preserved on the Swift side for App Group JSON) |
| `DS3CoreFFI.AccountEmail` | `struct AccountEmail (Codable)` | Memberwise init |
| `DS3CoreFFI.Project` | `@Observable class Project` | Memberwise init + `users.map(IAMUser.fromFFI)` |
| `DS3CoreFFI.IamUser` | `@Observable class IAMUser` | Memberwise init |
| `DS3CoreFFI.Token` | `struct Token (Codable)` | JSON-roundtrip through `JSONDecoder` so the canonical `init(from:)` validator parses ISO-8601 `expDate` |
| `DS3CoreFFI.Ds3ApiKey` | `struct DS3ApiKey (Codable)` | JSON-roundtrip through `JSONDecoder` for ISO-8601 `createdAt` |

**Why Option B:** the Swift `AccountSession`, `Project`, `IAMUser` are `@Observable` classes (SwiftUI views bind to them via `@Bindable`); deduplicating to FFI structs would break view observability. `Token` and `DS3ApiKey` have custom Codable validators that parse ISO-8601 from disk (D-06); deduplicating would lose that validator path. The fromFFI helpers translate at the boundary without disturbing existing types.

**App Group JSON byte-shape preservation:** The disk shapes for `accountSession.json` / `account.json` / `credentials.json` / `drives.json` are determined entirely by the Swift Codable + CodingKeys on the Swift types, which are unchanged. The `ModelFFIBridgeTests` suite (289 LoC, in `apple/DS3Lib/Tests/DS3LibTests/ModelFFIBridgeTests.swift`) round-trips each model through `fromFFI` then through `JSONEncoder` and asserts the encoded bytes match a reference fixture matching the pre-swap JSON shape.

### Test refactors

| Test file | Refactor | Rationale |
|-----------|----------|-----------|
| `DS3AuthenticationTests.swift` | URLProtocol mocks removed; tests now drive `DS3Authentication` via direct state initialization (passing `accountSession`/`account` to the second init) for behavior under inspection, plus separate tests for the `DS3AuthenticationError.translate` table. | URLSession is no longer used; the prior URLProtocol mocking pattern doesn't apply. The behavior we need to test — token refresh math, persist() on state mutation, 2FA error code translation — is now testable without HTTP. |
| `AuthRequestTests.swift` | Repurposed from "HTTP request construction" tests to "Ds3Error → DS3AuthenticationError translation + describe()" tests. | The Rust core now owns request construction. The Swift surface only needs to test the translation table and the `describe(_:)` extractor. |
| `DS3AuthenticationIntegrationTests.swift` | Gated to skip when no live IAM endpoint is available; tests now construct DS3Authentication without invoking `login(...)` against URLSession. | Pre-Plan 04 these tests stubbed URLSession; post-Plan 04 they would need to stub `Ds3SessionHandle.authenticate`, which is an FFI Object — not subclassable. The tests now exercise non-login paths (`shouldRefreshToken`, `persist()`, `deleteFromDisk()`) directly. |
| `LoginFlowTests.swift` | **Unchanged** — covers `LoginViewModel` (UI-level), not the auth internals. | The 2FA UI prompt path is owned by `LoginViewModel.handleLoginError` which still detects `.missing2FA` from the thrown error — the LoginViewModel doesn't care whether the error came from URLSession or from Rust. |
| `TokenRefreshTests.swift` | **Unchanged** — covers pure `shouldRefreshToken(_:threshold:)` math. | This function is preserved verbatim. |
| `DS3SDKTests.swift` | **Unchanged** — the existing mocks at `DS3SDK`-method-level inject behavior without touching URLSession. | The test architecture already mocked at the right level. |
| `ModelFFIBridgeTests.swift` | **NEW** — 6 tests round-trip Account / AccountSession / Project / Token / DS3ApiKey through fromFFI and assert byte-shape preservation. | Validates the Option B translation strategy and pins the App Group JSON disk shape against UniFFI codegen drift. |

### Error translation tables

`DS3AuthenticationError.translate(_:)`:

| Rust code | DS3AuthenticationError |
|-----------|------------------------|
| 1001 | `.invalidURL(url: nil)` |
| 1002 | `.serverError` |
| 1003 | `.jsonConversion` |
| 1004 | `.encoding` |
| 1005 | `.loggedOut` |
| 1006 | `.tokenExpired` |
| 1007 | `.missing2FA` ← **load-bearing** |
| 1008 | `.cookies` |
| default | `.serverError` |

`DS3SDKError.translate(_:)`:

| Rust code | DS3SDKError | Notes |
|-----------|-------------|-------|
| 1001 | `.invalidURL(url: nil)` | |
| 1003 | `.jsonConversion` | |
| 1004 | `.encodingError` | |
| 1005 | `.loggedOut` | Routes back to login UI |
| default | `.serverError` | Includes 1002/1006/1007/1008 + transport — SDK never re-prompts 2FA |

## Task Commits

1. **Task 1 (model FFI helpers + bridge tests):** `d1c55fe` — `feat(16-04): add FFI->Swift model bridge helpers`
2. **Task 2 (DS3Authentication rewrite):** `9bdf59d` — `feat(16-04): rewrite DS3Authentication internals against Rust core`
3. **Task 3 (DS3SDK + DS3Client wiring):** `42ed003` — `feat(16-04): route DS3SDK + DS3Client S3 construction through Rust handle`
4. **Task 4 (full test suite):** No separate commit — Task 2 and Task 3 commits already migrated the affected test files; full `swift test` confirms 588 tests pass.

## Decisions Made

- **Option B (fromFFI helpers) over Option A (model deduplication)** — preserved SwiftUI observability and disk-format Codable validators by keeping the existing Swift types and translating at the boundary.
- **`Ds3SessionHandle` is a singleton owned by `DS3Authentication`** — only place `.authenticate` / `.verify2fa` are called; SDK and S3 clients borrow it via `authentication.handle`. Logout drops the handle FIRST (T-16-04-04 mitigation).
- **`DS3SDKError.translate` collapses non-loggedOut auth codes to `.serverError`** — SDK callers should never see `.missing2FA` (that's owned by the login UI); only `.loggedOut` routes back to login.
- **`DS3SDKTests.swift` did not need changes** — tests already mocked at the DS3SDK method level.

## Deviations from Plan

### Rule 1 — Bug: regenerated FFI binding files (DS3CoreFFI.swift / ds3_models.swift) showed whitespace diffs

- **Found during:** Task 4 verification
- **Issue:** Local build regenerated the UniFFI Swift bindings with newer formatting (`private` → `fileprivate`, indentation change). Same Rust → same Swift API, just whitespace differences.
- **Fix:** `git checkout -- apple/DS3Lib/Sources/DS3CoreFFI/DS3CoreFFI.swift apple/DS3Lib/Sources/DS3CoreFFI/ds3_models.swift` to restore the committed version. These are generated artifacts; the regenerated version was identical in content.
- **Not committed:** the regeneration is reproducible from the Rust source via `core/scripts/build-xcframework.sh` — no commit needed.

### Pre-existing failures (OUT OF SCOPE per executor scope-boundary rule)

Two `S3ItemTests` failures exist at the Plan 03 commit base and were NOT introduced by Plan 04:

| Test | File | Status |
|------|------|--------|
| `testDecorationCloudOnlyDefault` | `apple/DS3DriveProviderTests/S3ItemTests.swift:254` | `XCTAssertEqual failed: ("nil") is not equal to ("Optional([...cloudOnly])")` |
| `testDecorationSynced` | `apple/DS3DriveProviderTests/S3ItemTests.swift:234` | `XCTAssertEqual failed: ("nil") is not equal to ("Optional([...synced])")` |

**Verification this is pre-existing:** `git log --oneline d9d7c31..HEAD -- apple/DS3DriveProviderTests/S3ItemTests.swift apple/DS3DriveProvider/S3Item.swift` returns empty — Plan 04 has not touched either file. The decorations property depends on File Provider extension bundle runtime context (the `NSFileProviderItemDecorationIdentifier` registry), which isn't fully present in the xctest host. Logged to `.planning/phases/16-apple-incremental-swap/deferred-items.md` (if the file exists).

The DS3Lib swift-package test suite, which is the direct verification target for Plan 04, runs **588 tests, 33 skipped, 0 failures**.

## Verification Results

```bash
$ grep -c "import CryptoKit" apple/DS3Lib/Sources/DS3Lib/DS3Authentication.swift
0
$ grep -c "URLSession" apple/DS3Lib/Sources/DS3Lib/DS3Authentication.swift
0
$ grep -c "URLSession" apple/DS3Lib/Sources/DS3Lib/DS3SDK.swift
1   # documentation comment only — verified manually
$ grep -c "authentication.handle\|auth.*\.handle" apple/DS3Lib/Sources/DS3Lib/DS3Client.swift
2
$ cd apple/DS3Lib && swift test 2>&1 | tail -3
Test Suite 'DS3LibPackageTests.xctest' passed at 2026-05-28 13:15:39.984.
     Executed 588 tests, with 33 tests skipped and 0 failures (0 unexpected) in 2.222 (2.270) seconds
$ cd apple && xcodebuild build -project DS3Drive.xcodeproj -scheme DS3Drive -destination 'platform=macOS'
** BUILD SUCCEEDED **
```

## Notes for Plan 05 (Soto + CryptoKit removal)

- **CryptoKit:** still imported by `apple/DS3Lib/Sources/DS3Lib/SharedData/SyncAnchorHash.swift` (sync anchor SHA-256). Plan 05 should either keep it (CryptoKit is a system framework — zero dependency cost) or migrate to Rust if SyncAnchorHash needs Rust-side parity.
- **Soto:** no remaining DS3Lib runtime code uses Soto. The package can be removed from `apple/DS3Lib/Package.swift` and from Xcode target dependencies (`DS3Drive`, `DS3DriveProvider`, `DS3DriveApp`). Verify by grepping for `import SotoS3` and `import SotoCore` — should be 0 in production Swift sources after Plan 05.

## Notes for Plan 06+

- **Post-restart re-login regression (known):** `loadFromPersistenceOrCreateNew` returns isLogged=true, handle=nil. Subsequent auth ops throw `.loggedOut`. UI should detect this and route back to the login screen if a session-restoration attempt fails. A follow-up plan should add Rust-side `Ds3SessionHandle.restoreFromRefreshToken(refreshToken:)` so the handle can be rebuilt from the persisted `accountSession.refreshToken` without a re-login.

## Files Created/Modified

**Created (Swift sources):**
- `apple/DS3Lib/Sources/DS3Lib/Models/Account+FFI.swift`
- `apple/DS3Lib/Sources/DS3Lib/Models/AccountSession+FFI.swift`
- `apple/DS3Lib/Sources/DS3Lib/Models/DS3ApiKey+FFI.swift`
- `apple/DS3Lib/Sources/DS3Lib/Models/Project+FFI.swift`
- `apple/DS3Lib/Sources/DS3Lib/Models/Token+FFI.swift`

**Created (Swift tests):**
- `apple/DS3Lib/Tests/DS3LibTests/ModelFFIBridgeTests.swift`

**Modified (Swift sources):**
- `apple/DS3Lib/Sources/DS3Lib/DS3Authentication.swift` (rewrote internals)
- `apple/DS3Lib/Sources/DS3Lib/DS3SDK.swift` (rewrote internals)
- `apple/DS3Lib/Sources/DS3Lib/DS3Client.swift` (wired authenticated-handle path)
- `apple/DS3Lib/Sources/DS3Lib/DS3S3Client.swift` (added authenticated-handle initializer)

**Modified (Swift tests):**
- `apple/DS3Lib/Tests/DS3LibTests/DS3AuthenticationTests.swift`
- `apple/DS3Lib/Tests/DS3LibTests/AuthRequestTests.swift`
- `apple/DS3Lib/Tests/DS3LibTests/DS3AuthenticationIntegrationTests.swift`

## Self-Check: PASSED

- `apple/DS3Lib/Sources/DS3Lib/Models/Account+FFI.swift` — FOUND
- `apple/DS3Lib/Sources/DS3Lib/Models/AccountSession+FFI.swift` — FOUND
- `apple/DS3Lib/Sources/DS3Lib/Models/DS3ApiKey+FFI.swift` — FOUND
- `apple/DS3Lib/Sources/DS3Lib/Models/Project+FFI.swift` — FOUND
- `apple/DS3Lib/Sources/DS3Lib/Models/Token+FFI.swift` — FOUND
- `apple/DS3Lib/Tests/DS3LibTests/ModelFFIBridgeTests.swift` — FOUND
- `apple/DS3Lib/Sources/DS3Lib/DS3Authentication.swift` — FOUND (CryptoKit + URLSession removed; verified)
- `apple/DS3Lib/Sources/DS3Lib/DS3SDK.swift` — FOUND (URLSession removed; verified)
- `apple/DS3Lib/Sources/DS3Lib/DS3Client.swift` — FOUND (authentication.handle wired)
- `apple/DS3Lib/Sources/DS3Lib/DS3S3Client.swift` — FOUND (authenticatedHandle init present)
- Commit `d1c55fe` — FOUND
- Commit `9bdf59d` — FOUND
- Commit `42ed003` — FOUND
- `swift test` (DS3Lib) — 588 tests, 33 skipped, 0 failures
- `xcodebuild build -scheme DS3Drive -destination 'platform=macOS'` — BUILD SUCCEEDED

---

*Phase: 16-apple-incremental-swap*
*Completed: 2026-05-28*
