# Phase 4: Auth & Platform - Research

**Researched:** 2026-03-13
**Domain:** IAM v1 authentication, multitenancy, configurable API URLs, token refresh, API key management
**Confidence:** HIGH (codebase analysis) / MEDIUM (API spec from composer-cli)

## Summary

Phase 4 transforms the existing authentication and API infrastructure from hardcoded, single-tenant defaults into a configurable, tenant-aware system. The codebase already has a working challenge-response auth flow (`DS3Authentication`), API key management (`DS3SDK`), and inter-process SharedData persistence. The primary work is: (1) refactoring `CubbitAPIURLs` from a static enum to an instance-based class accepting a coordinator base URL, (2) adding `tenant_id` to challenge/signin request bodies, (3) adding proactive token refresh with file-locked SharedData, (4) extending the login UI with an "Advanced" disclosure section, and (5) adding Connection Info and Sign Out to the tray menu.

The existing code is well-structured with clear separation: `DS3Authentication` handles auth, `DS3SDK` handles API keys and projects, `SharedData` handles App Group persistence, and `NotificationManager` handles IPC. All use `CubbitAPIURLs` static properties for URL construction. The refactoring is mechanical but touches every API call site in `DS3Authentication`, `DS3SDK`, and `FileProviderExtension`.

**Primary recommendation:** Work bottom-up: first refactor URLs to instance-based, then inject into DS3Authentication/DS3SDK, then add tenant support, then token refresh, then UI changes. Each layer builds on the previous.

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
- Login screen extended (not redesigned) with an "Advanced" inline DisclosureGroup toggle below the password field
- "Advanced" section reveals two fields: tenant name and coordinator URL
- Tenant field is free text, no pre-validation -- server returns error on invalid tenant
- No default tenant pre-filled -- field starts empty; most consumers don't need it
- Last-used tenant remembered in UserDefaults across logout/re-login
- S3 endpoint discovered from `Account.endpointGateway` (already implemented) -- no Composer Hub call needed for endpoint discovery
- Tenant name stored in SharedData alongside account/session for extension access
- Coordinator URL field in login "Advanced" section, pre-filled with current default (`https://api.eu00wi.cubbit.services`)
- Simple base URL swap: replace hardcoded base URL, all API paths stay the same
- Refactor URLs.swift from static enum to instance-based class that takes coordinator URL in initializer
- DS3Authentication and DS3SDK accept URLs instance via initializer injection (not global state)
- Both main app and extension construct their own URLs instance from SharedData
- Coordinator URL stored in SharedData for extension access
- Changing coordinator URL requires re-login (prevents split-state)
- No pre-validation of coordinator URL -- login attempt is the validation
- Console URL retrieved from Composer Hub tenant info (research phase to verify endpoint)
- Logout preserves both tenant and coordinator URL settings (only clears auth tokens/account/drives)
- Proactive refresh: 5 minutes before token expiry, background timer checks and refreshes ahead of time
- Extension refreshes independently -- reads refresh token from SharedData, calls /iam/v1/auth/refresh/access, persists new tokens back
- File lock (NSFileCoordinator or POSIX) on SharedData token files to prevent race conditions between app and extension
- On refresh failure: drives enter error state, macOS notification "DS3 Drive session expired -- sign in to resume syncing"
- Extension notifies main app of auth failure via DistributedNotificationCenter
- Reactive API key handling -- detected via S3 403 Forbidden
- Self-healing: extension detects 403, uses stored auth token to recreate API key via loadOrCreateDS3APIKeys, retries S3 operation
- Specific error messages per failure type (Wrong credentials, Invalid tenant, Network error, 2FA error, Session expired)
- Expandable "Connection Info" disclosure section in tray menu with coordinator URL, S3 endpoint, tenant name, console URL
- Fields are click-to-copy with brief "Copied" confirmation
- Logged-in user email displayed: "Signed in as user@email.com"
- "Sign Out" action in tray menu -- full cleanup (tokens, drives, File Provider domains, API keys)
- Sign out preserves tenant and coordinator URL settings in UserDefaults
- Primary reference: composer-cli GitHub repo for API spec verification
- No backward compatibility -- target current API spec only

### Claude's Discretion
- Challenge endpoint tenant_id inclusion (verify from composer-cli)
- File lock implementation choice (NSFileCoordinator vs POSIX)
- Proactive refresh timer implementation (Timer, DispatchSource, or async Task)
- Exact DisclosureGroup styling and animation
- Connection Info label formatting in tray menu
- Error message wording refinements
- Composer Hub endpoint for console URL discovery

### Deferred Ideas (OUT OF SCOPE)
- Conflict resolution UI (keep/discard/merge) -- Phase 5
- Finder sync badges -- Phase 5
- Menu bar sync status per drive -- Phase 5
- Drive setup wizard redesign with tenant-aware project/bucket selection -- Phase 5 (UX-06)
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|-----------------|
| AUTH-01 | Login flow uses IAM v1 challenge-response with tenant_id field | URLs refactoring + tenant_id in DS3ChallengeRequest/DS3LoginRequest bodies; existing challenge-response flow in DS3Authentication is already correct, just needs tenant_id field added |
| AUTH-02 | API keys auto-created and managed under the hood during drive setup | Existing `loadOrCreateDS3APIKeys` already works; needs URLs injection and 403 self-healing in extension |
| AUTH-03 | Token refresh handles expiration gracefully without disrupting active sync | Proactive timer (5min before expiry) + NSFileCoordinator for SharedData file locking + DistributedNotificationCenter for auth failure IPC |
| AUTH-04 | 2FA support maintained from existing implementation | MFAView and 2FA flow are already working; just need to pass tenant_id through the login chain |
| PLAT-01 | Multitenancy -- tenant field in login screen, S3 endpoint auto-discovered | DisclosureGroup "Advanced" section in LoginView; Account.endpointGateway already provides S3 endpoint; tenant persisted in SharedData + UserDefaults |
| PLAT-02 | Configurable coordinator URL | URLs.swift refactored to instance-based CubbitAPIURLs class with coordinator URL initializer; injected into DS3Authentication and DS3SDK |
| PLAT-03 | All API endpoints updated to current IAM/Composer Hub/Keyvault specs | API paths confirmed consistent: /iam/v1/, /composer-hub/v1/, /keyvault/api/v3/; just need instance-based URL construction |
| PLAT-04 | API URLs no longer hardcoded -- derived from coordinator base URL | CubbitAPIURLs refactored from static enum to class with computed URL properties derived from coordinator base |
</phase_requirements>

## Standard Stack

### Core (Existing - No New Dependencies)

| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| Foundation/URLSession | macOS 15+ | HTTP networking for IAM/Composer Hub/Keyvault APIs | Already in use, no reason to change |
| CryptoKit | macOS 15+ | Curve25519 challenge signing | Already in use for challenge-response auth |
| SwiftUI | macOS 15+ | Login UI, tray menu, DisclosureGroup | Already in use for all views |
| NSFileCoordinator | macOS 15+ | File locking for SharedData token files | Apple's recommended API for cross-process file coordination |
| UNUserNotificationCenter | macOS 15+ | Auth expiration notifications | Already used for conflict notifications (ConflictNotificationHandler) |
| DistributedNotificationCenter | macOS 15+ | Extension-to-app IPC for auth failure | Already used for drive status and conflict notifications |
| UserDefaults | macOS 15+ | Tenant and coordinator URL persistence across re-login | Already used for tutorial/loginItem settings |
| Soto v6 (SotoS3) | 6.8+ | S3 operations (unchanged) | Already in DS3Lib/Package.swift |

### No New Dependencies Required

This phase uses only existing frameworks and patterns. No new SPM packages needed.

## Architecture Patterns

### Recommended Refactoring Structure

```
DS3Lib/Sources/DS3Lib/
  Constants/
    URLs.swift                      # REFACTOR: static enum -> instance-based class
    DefaultSettings.swift           # EXTEND: add UserDefaults keys for tenant/coordinator
  DS3Authentication.swift           # MODIFY: accept CubbitAPIURLs instance, add tenant_id to requests
  DS3SDK.swift                      # MODIFY: accept CubbitAPIURLs instance
  SharedData/
    SharedData.swift                # EXTEND: add tenant name + coordinator URL persistence
    SharedData+account.swift        # MODIFY: add NSFileCoordinator for token file writes
    SharedData+accountSession.swift # MODIFY: add NSFileCoordinator for token file writes

DS3Drive/
  Views/Login/
    Views/LoginView.swift           # MODIFY: add DisclosureGroup "Advanced" section
    ViewModels/LoginViewModel.swift # MODIFY: accept tenant/coordinator, pass to auth
  Views/Tray/Views/
    TrayMenuView.swift              # MODIFY: add Connection Info, user email, Sign Out
  DS3DriveApp.swift                 # MODIFY: construct CubbitAPIURLs, add auth refresh timer

DS3DriveProvider/
  FileProviderExtension.swift       # MODIFY: construct CubbitAPIURLs from SharedData, add 403 handling
```

### Pattern 1: Instance-Based URL Construction

**What:** Replace the static `CubbitAPIURLs` enum with an instance-based class that derives all URLs from a coordinator base URL.
**When to use:** Every API call in DS3Authentication, DS3SDK, and any future API client.

```swift
// Current: Static enum (hardcoded)
public enum CubbitAPIURLs {
    public static let baseURL = "https://api.eu00wi.cubbit.services"
    public enum IAM {
        public static let baseURL = "\(CubbitAPIURLs.baseURL)/iam/v1"
    }
}

// New: Instance-based class
public final class CubbitAPIURLs: Sendable {
    public let coordinatorURL: String

    public init(coordinatorURL: String = "https://api.eu00wi.cubbit.services") {
        // Strip trailing slash for consistency
        self.coordinatorURL = coordinatorURL.hasSuffix("/")
            ? String(coordinatorURL.dropLast())
            : coordinatorURL
    }

    // IAM service
    public var iamBaseURL: String { "\(coordinatorURL)/iam/v1" }
    public var authBaseURL: String { "\(iamBaseURL)/auth" }
    public var signinURL: String { "\(authBaseURL)/signin" }
    public var challengeURL: String { "\(signinURL)/challenge" }
    public var tokenRefreshURL: String { "\(authBaseURL)/refresh/access" }
    public var forgeAccessJWTURL: String { "\(authBaseURL)/forge/access" }
    public var accountsMeURL: String { "\(iamBaseURL)/accounts/me" }

    // Composer Hub
    public var composerHubBaseURL: String { "\(coordinatorURL)/composer-hub/v1" }
    public var projectsURL: String { "\(composerHubBaseURL)/projects" }
    public var tenantsURL: String { "\(composerHubBaseURL)/tenants" }
    public func tenantURL(tenantId: String) -> String { "\(coordinatorURL)/v1/tenants/\(tenantId)" }

    // Keyvault
    public var keyvaultBaseURL: String { "\(coordinatorURL)/keyvault/api/v3" }
    public var keysURL: String { "\(keyvaultBaseURL)/keys" }
}
```

### Pattern 2: Dependency Injection for URLs

**What:** DS3Authentication and DS3SDK accept a CubbitAPIURLs instance in their initializers instead of referencing static properties.
**When to use:** All API client classes.

```swift
// DS3Authentication with injected URLs
@Observable public final class DS3Authentication: @unchecked Sendable {
    private let urls: CubbitAPIURLs

    public init(urls: CubbitAPIURLs = CubbitAPIURLs()) {
        self.urls = urls
        self.accountSession = nil
        self.isLogged = false
    }

    public init(urls: CubbitAPIURLs, accountSession: AccountSession, account: Account, isLogged: Bool) {
        self.urls = urls
        self.accountSession = accountSession
        self.account = account
        self.isLogged = isLogged
    }
}

// DS3SDK with injected URLs
@Observable public final class DS3SDK: @unchecked Sendable {
    private var authentication: DS3Authentication
    private let urls: CubbitAPIURLs

    public init(withAuthentication authentication: DS3Authentication, urls: CubbitAPIURLs = CubbitAPIURLs()) {
        self.authentication = authentication
        self.urls = urls
    }
}
```

### Pattern 3: Tenant-Aware Request Bodies

**What:** Add optional `tenant_id` field to challenge and signin request structures.
**When to use:** Login flow only.

```swift
// Challenge request with optional tenant_id
struct DS3ChallengeRequest: Codable {
    var email: String
    var tenantId: String?

    enum CodingKeys: String, CodingKey {
        case email
        case tenantId = "tenant_id"
    }
}

// Login request with optional tenant_id
struct DS3LoginRequest: Codable {
    var email: String
    var signedChallenge: String
    var tfaCode: String?
    var tenantId: String?

    enum CodingKeys: String, CodingKey {
        case email
        case signedChallenge
        case tfaCode = "tfa_code"
        case tenantId = "tenant_id"
    }
}
```

### Pattern 4: NSFileCoordinator for SharedData Token Files

**What:** Wrap SharedData read/write operations for token files with NSFileCoordinator to prevent race conditions between app and extension processes.
**When to use:** persistAccountSession, loadAccountSessionFromPersistence, and equivalent Account operations.

```swift
// File-coordinated write
public func persistAccountSession(accountSession: AccountSession) throws {
    guard let containerURL = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: DefaultSettings.appGroup
    ) else { throw SharedDataError.cannotAccessAppGroup }

    let sessionURL = containerURL.appendingPathComponent(DefaultSettings.FileNames.accountSessionFileName)
    let coordinator = NSFileCoordinator()
    var coordinatorError: NSError?

    coordinator.coordinate(writingItemAt: sessionURL, options: .forReplacing, error: &coordinatorError) { url in
        do {
            let data = try JSONEncoder().encode(accountSession)
            try data.write(to: url)
        } catch {
            // Log but don't throw from coordination block
        }
    }

    if let error = coordinatorError { throw error }
}

// File-coordinated read
public func loadAccountSessionFromPersistence() throws -> AccountSession {
    guard let containerURL = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: DefaultSettings.appGroup
    ) else { throw SharedDataError.cannotAccessAppGroup }

    let sessionURL = containerURL.appendingPathComponent(DefaultSettings.FileNames.accountSessionFileName)
    let coordinator = NSFileCoordinator()
    var coordinatorError: NSError?
    var result: AccountSession?

    coordinator.coordinate(readingItemAt: sessionURL, options: [], error: &coordinatorError) { url in
        result = try? JSONDecoder().decode(AccountSession.self, from: Data(contentsOf: url))
    }

    if let error = coordinatorError { throw error }
    guard let session = result else { throw SharedDataError.conversionError }
    return session
}
```

### Pattern 5: Proactive Token Refresh Timer

**What:** Background async Task that checks token expiry and refreshes proactively.
**When to use:** Main app (DS3DriveApp) and extension (FileProviderExtension) independently.

```swift
// Proactive refresh: check every 60 seconds, refresh if within 5 minutes of expiry
func startProactiveRefreshTimer() {
    Task {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(60))

            guard let session = self.accountSession, self.isLogged else { continue }

            let timeToExpiry = session.token.expDate.timeIntervalSinceNow
            if timeToExpiry < 300 { // 5 minutes = 300 seconds
                do {
                    try await self.refreshIfNeeded(force: true)
                } catch {
                    // Token refresh failed -- notify app
                    logger.error("Proactive token refresh failed: \(error)")
                }
            }
        }
    }
}
```

### Pattern 6: Auth Failure IPC via DistributedNotificationCenter

**What:** Extension notifies main app when auth fails (reuses existing IPC pattern).
**When to use:** When token refresh fails in the extension process.

```swift
// In DefaultSettings.Notifications:
public static let authFailure = "io.cubbit.DS3Drive.notifications.authFailure"

// Extension sends:
DistributedNotificationCenter.default().postNotificationName(
    NSNotification.Name(DefaultSettings.Notifications.authFailure),
    object: domain.identifier.rawValue,
    userInfo: ["reason": "tokenRefreshFailed"],
    deliverImmediately: true
)
```

### Anti-Patterns to Avoid

- **Global mutable state for URLs:** Do NOT make CubbitAPIURLs a global singleton. Use dependency injection via initializers.
- **Synchronous file I/O on main thread:** SharedData operations with NSFileCoordinator can block. Use `try?` for non-critical reads and dispatch to background when possible.
- **Polling for token refresh in tight loops:** The 60-second check interval is sufficient; shorter intervals waste battery and CPU.
- **Throwing custom errors from extension to File Provider system:** Only NSFileProviderError and NSCocoaError domains are supported (per MEMORY.md).

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Cross-process file locking | POSIX flock() / fcntl() | NSFileCoordinator | Apple's official API, handles edge cases (process crash, timeout), works with App Group containers. Safe since iOS 8.2/macOS equivalents |
| Token expiry scheduling | DispatchSource timer or raw DispatchQueue | async Task + Task.sleep(for:) | Modern Swift concurrency, automatically handles cancellation, no retain cycles |
| JSON file coordination | Manual lock files | NSFileCoordinator | Atomic read/write coordination built into the framework |
| IPC between app and extension | Custom XPC service | DistributedNotificationCenter | Already established pattern in codebase, lightweight, fire-and-forget |
| macOS user notifications | Custom alert windows | UNUserNotificationCenter | Already established pattern (ConflictNotificationHandler), proper notification center integration |

**Key insight:** The codebase already has working IPC (DistributedNotificationCenter), notification (UNUserNotificationCenter), and persistence (SharedData/App Group) patterns. Phase 4 extends these patterns rather than introducing new infrastructure.

## Common Pitfalls

### Pitfall 1: NSFileCoordinator Deadlocks Between Processes

**What goes wrong:** If both app and extension try to write to the same SharedData file simultaneously with NSFileCoordinator, one blocks until the other completes. If the blocked process is the File Provider extension, macOS may kill it for timeout.
**Why it happens:** Token refresh in both processes writes to the same accountSession.json file.
**How to avoid:** Keep coordination blocks short (encode/write only, no network calls inside). Use `options: .forReplacing` for writes. Consider read-only coordination for the extension (let the app be the primary writer when possible).
**Warning signs:** Extension process killed by watchdog, "Extension took too long" in system logs.

### Pitfall 2: Race Between Login and Extension Token Refresh

**What goes wrong:** User logs in while extension is refreshing an expired token. The extension overwrites the new session with a stale refresh result.
**Why it happens:** Login creates a brand new AccountSession, but the extension's in-flight refresh uses the old refresh token.
**How to avoid:** Login should invalidate the old session atomically. Extension should re-read SharedData after any refresh to verify the session is still valid. Changing coordinator URL requires re-login (per locked decision), which includes removing all File Provider domains first.
**Warning signs:** "Token expired" errors immediately after login.

### Pitfall 3: UserDefaults vs SharedData Scope Confusion

**What goes wrong:** Tenant/coordinator URL stored in UserDefaults (main app only) but needed by extension which reads SharedData (App Group).
**Why it happens:** UserDefaults default suite is per-process, not shared via App Group.
**How to avoid:** Store tenant name and coordinator URL in BOTH UserDefaults (for pre-login remember-last-used) AND SharedData (for extension access post-login). Or use the App Group suite UserDefaults: `UserDefaults(suiteName: DefaultSettings.appGroup)`.
**Warning signs:** Extension uses wrong coordinator URL, can't reach API.

### Pitfall 4: Encoder Key Strategy Mismatch for tenant_id

**What goes wrong:** DS3LoginRequest uses `encoder.keyEncodingStrategy = .convertToSnakeCase`, so explicit CodingKey `tenant_id` gets double-converted to `tenant_id` (which is actually correct in this case, since it's already snake_case). But DS3ChallengeRequest does NOT use this strategy.
**Why it happens:** Inconsistent encoder configuration between getChallenge and getAccountSession methods.
**How to avoid:** Use explicit CodingKeys for all request structs. Don't rely on automatic snake_case conversion. Verify the JSON wire format with debug logging.
**Warning signs:** 400 Bad Request from IAM API, "unknown field" errors.

### Pitfall 5: Console URL Hardcoded Instead of Discovered

**What goes wrong:** TrayMenuView and "Open web console" action still use `ConsoleURLs.baseURL` ("https://console.cubbit.eu"), which won't work for self-hosted or different-tenant deployments.
**Why it happens:** ConsoleURLs is a separate static enum not covered by the CubbitAPIURLs refactoring.
**How to avoid:** Retrieve console_url from tenant settings via Composer Hub API (GET /v1/tenants/{tenantId}), store in SharedData alongside other connection info. Fall back to constructed URL if not available.
**Warning signs:** "Open web console" opens wrong console for non-default tenants.

### Pitfall 6: Forgetting to Pass tenant_id After 2FA Redirect

**What goes wrong:** User enters tenant on login screen, gets 2FA prompt, submits 2FA code -- but the second login() call doesn't include the tenant_id.
**Why it happens:** MFAView calls `loginViewModel.login(withAuthentication:email:password:withTfaToken:)` but doesn't pass the tenant.
**How to avoid:** Thread the tenant through the MFA flow. LoginViewModel should store the tenant, and the MFA retry should include it. Or pass tenant alongside email/password to MFAView.
**Warning signs:** 2FA login succeeds but user is on wrong tenant, or fails with authentication error.

## Code Examples

### Login Flow with Tenant Support

```swift
// LoginView with Advanced section
struct LoginView: View {
    @State var email: String = ""
    @State var password: String = ""
    @State var tenant: String = UserDefaults.standard.string(forKey: "lastTenant") ?? ""
    @State var coordinatorURL: String = UserDefaults.standard.string(
        forKey: "lastCoordinatorURL"
    ) ?? "https://api.eu00wi.cubbit.services"
    @State var showAdvanced: Bool = false

    var body: some View {
        VStack {
            // ... existing email/password fields ...

            DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                IconTextField(
                    iconName: .someIcon,
                    placeholder: "Tenant name",
                    text: $tenant
                )
                IconTextField(
                    iconName: .someIcon,
                    placeholder: "Coordinator URL",
                    text: $coordinatorURL
                )
            }

            Button("Log in") { login() }
        }
    }

    func login() {
        // Remember last-used values
        UserDefaults.standard.set(tenant, forKey: "lastTenant")
        UserDefaults.standard.set(coordinatorURL, forKey: "lastCoordinatorURL")

        let urls = CubbitAPIURLs(coordinatorURL: coordinatorURL)
        Task {
            try await loginViewModel.login(
                withAuthentication: ds3Authentication,
                urls: urls,
                email: email,
                password: password,
                tenant: tenant.isEmpty ? nil : tenant
            )
        }
    }
}
```

### Extension Init with Dynamic URLs

```swift
// FileProviderExtension.init with dynamic URL construction
required init(domain: NSFileProviderDomain) {
    // ... existing setup ...

    do {
        let sharedData = SharedData.default()

        // Load coordinator URL from SharedData
        let coordinatorURL = try? sharedData.loadCoordinatorURLFromPersistence()
        let urls = CubbitAPIURLs(coordinatorURL: coordinatorURL ?? "https://api.eu00wi.cubbit.services")

        // ... existing drive/account/apiKeys loading ...

        // Construct auth for potential token refresh
        self.authentication = DS3Authentication(
            urls: urls,
            accountSession: accountSession,
            account: account,
            isLogged: true
        )

        // Start proactive token refresh
        self.startProactiveRefreshTimer()
    } catch {
        // ... existing error handling ...
    }
}
```

### SharedData Extensions for Tenant/Coordinator

```swift
extension SharedData {
    private static let tenantFileName = "tenant.json"
    private static let coordinatorURLFileName = "coordinatorURL.txt"

    public func persistTenantName(_ tenant: String) throws {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: DefaultSettings.appGroup
        ) else { throw SharedDataError.cannotAccessAppGroup }

        let url = containerURL.appendingPathComponent(Self.tenantFileName)
        try tenant.data(using: .utf8)?.write(to: url)
    }

    public func loadTenantNameFromPersistence() throws -> String {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: DefaultSettings.appGroup
        ) else { throw SharedDataError.cannotAccessAppGroup }

        let url = containerURL.appendingPathComponent(Self.tenantFileName)
        return try String(contentsOf: url, encoding: .utf8)
    }

    public func persistCoordinatorURL(_ coordinatorURL: String) throws {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: DefaultSettings.appGroup
        ) else { throw SharedDataError.cannotAccessAppGroup }

        let url = containerURL.appendingPathComponent(Self.coordinatorURLFileName)
        try coordinatorURL.data(using: .utf8)?.write(to: url)
    }

    public func loadCoordinatorURLFromPersistence() throws -> String {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: DefaultSettings.appGroup
        ) else { throw SharedDataError.cannotAccessAppGroup }

        let url = containerURL.appendingPathComponent(Self.coordinatorURLFileName)
        return try String(contentsOf: url, encoding: .utf8)
    }
}
```

### 403 Self-Healing in Extension

```swift
// In FileProviderExtension, wrap S3 operations with 403 detection
private func withAPIKeyRecovery<T>(
    drive: DS3Drive,
    operation: @escaping () async throws -> T
) async throws -> T {
    do {
        return try await operation()
    } catch let error as S3ErrorType where error.errorCode == "AccessDenied" || error.errorCode == "InvalidAccessKeyId" {
        logger.warning("S3 403 detected, attempting API key self-healing")

        guard let auth = self.authentication else {
            throw NSFileProviderError(.notAuthenticated) as NSError
        }

        let sdk = DS3SDK(withAuthentication: auth, urls: self.urls)
        let newKey = try await sdk.loadOrCreateDS3APIKeys(
            forIAMUser: drive.syncAnchor.IAMUser,
            ds3ProjectName: drive.syncAnchor.project.name
        )

        // Recreate S3 client with new credentials
        self.reinitializeS3Client(with: newKey)
        logger.info("API key self-healing successful, retrying operation")

        return try await operation()
    }
}
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Static URL enum | Instance-based URL class | This phase | Enables configurable coordinator URL |
| No tenant in auth requests | tenant_id field in challenge/signin | This phase | Enables multitenancy |
| Reactive token refresh only | Proactive 5-min-ahead timer | This phase | Prevents sync interruption |
| Uncoordinated SharedData writes | NSFileCoordinator on token files | This phase | Prevents app/extension race conditions |
| No auth failure recovery | 403 self-healing with API key recreation | This phase | Transparent resilience |

**Not changing (already correct):**
- Challenge-response flow with Curve25519 (DS3Authentication) -- working correctly
- API key deterministic naming pattern (DS3SDK.apiKeyName) -- no changes needed
- SharedData App Group persistence model -- extending, not replacing
- DistributedNotificationCenter IPC pattern -- extending, not replacing
- MFAView 2FA flow -- works as-is, just needs tenant threading

## Open Questions

1. **Challenge endpoint tenant_id inclusion**
   - What we know: The existing DS3ChallengeRequest only sends `email`. The Account model returns `tenant_id`. The composer-cli uses a device-flow auth (not challenge-response), so we can't verify from there.
   - What's unclear: Whether the IAM v1 challenge endpoint requires/accepts `tenant_id` in the request body, or whether it's only needed for the signin endpoint.
   - Recommendation: Add `tenant_id` as optional to both challenge and signin requests. The server will ignore unknown fields if not needed, and including it in both ensures correctness regardless. This is Claude's discretion per CONTEXT.md. **Recommend including in both** for safety.

2. **Composer Hub endpoint for console URL**
   - What we know: From composer-cli response models, `TenantSettings` has `console_url` (optional string) and `gateway_url` (optional string). The tenant API endpoint is GET `/v1/tenants/{tenantId}`.
   - What's unclear: Whether the `/v1/tenants/{tenantId}` endpoint is accessible with a regular user token (vs operator API key). The composer-cli uses API key auth, not user JWT.
   - Recommendation: Try GET `/v1/tenants/{tenantId}` with the user's access token first. If it fails with 403, fall back to constructing console URL as `https://console.{tenantName}.cubbit.eu`. Store whatever we get in SharedData for the tray menu Connection Info.

3. **Token expiry format in JWT**
   - What we know: Token.exp is Int64 (Unix timestamp), Token.expDate is parsed from ISO 8601 string. Both come from IAM response.
   - What's unclear: Whether the server includes `exp_date` in the refresh response identical to the login response.
   - Recommendation: Maintain both fields as-is. The Token.init(from:) already handles ISO 8601 parsing.

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | XCTest (Swift Package Manager) |
| Config file | DS3Lib/Package.swift (testTarget: DS3LibTests) |
| Quick run command | `cd DS3Lib && swift test --filter DS3LibTests 2>&1` |
| Full suite command | `cd DS3Lib && swift test 2>&1` |

### Phase Requirements to Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| AUTH-01 | CubbitAPIURLs instance derives all paths from coordinator base URL | unit | `cd DS3Lib && swift test --filter DS3LibTests.CubbitAPIURLsTests -x` | Wave 0 |
| AUTH-01 | DS3ChallengeRequest/DS3LoginRequest encode tenant_id correctly | unit | `cd DS3Lib && swift test --filter DS3LibTests.AuthRequestTests -x` | Wave 0 |
| AUTH-02 | API key self-healing detects 403 and recreates key | unit | `cd DS3Lib && swift test --filter DS3LibTests.APIKeySelfHealingTests -x` | Wave 0 |
| AUTH-03 | Proactive refresh detects near-expiry token | unit | `cd DS3Lib && swift test --filter DS3LibTests.TokenRefreshTests -x` | Wave 0 |
| AUTH-04 | 2FA flow passes tenant_id through MFA retry | manual-only | Manual: requires live IAM server with 2FA-enabled account | N/A |
| PLAT-01 | SharedData persists/loads tenant name | unit | `cd DS3Lib && swift test --filter DS3LibTests.SharedDataTenantTests -x` | Wave 0 |
| PLAT-02 | SharedData persists/loads coordinator URL | unit | `cd DS3Lib && swift test --filter DS3LibTests.SharedDataCoordinatorTests -x` | Wave 0 |
| PLAT-03 | URL paths match expected IAM/ComposerHub/Keyvault patterns | unit | `cd DS3Lib && swift test --filter DS3LibTests.CubbitAPIURLsTests -x` | Wave 0 |
| PLAT-04 | CubbitAPIURLs with custom base produces correct derived URLs | unit | `cd DS3Lib && swift test --filter DS3LibTests.CubbitAPIURLsTests -x` | Wave 0 |

### Sampling Rate
- **Per task commit:** `cd DS3Lib && swift test --filter DS3LibTests -x`
- **Per wave merge:** `cd DS3Lib && swift test 2>&1` + `xcodebuild clean build analyze -project DS3Drive.xcodeproj -scheme DS3Drive -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`
- **Phase gate:** Full suite green before `/gsd:verify-work`

### Wave 0 Gaps
- [ ] `DS3Lib/Tests/DS3LibTests/CubbitAPIURLsTests.swift` -- covers PLAT-02, PLAT-03, PLAT-04 (URL derivation from coordinator base)
- [ ] `DS3Lib/Tests/DS3LibTests/AuthRequestTests.swift` -- covers AUTH-01 (tenant_id encoding in request bodies)
- [ ] `DS3Lib/Tests/DS3LibTests/SharedDataTenantTests.swift` -- covers PLAT-01, PLAT-02 (tenant and coordinator URL persistence)
- [ ] `DS3Lib/Tests/DS3LibTests/TokenRefreshTests.swift` -- covers AUTH-03 (expiry detection logic)

## Sources

### Primary (HIGH confidence)
- Codebase analysis: DS3Authentication.swift, DS3SDK.swift, URLs.swift, SharedData/*.swift, FileProviderExtension.swift, LoginView.swift, TrayMenuView.swift, ConflictNotificationHandler.swift, NotificationsManager.swift
- DS3Lib/Package.swift -- dependency versions and build configuration
- CLAUDE.md -- project architecture and patterns

### Secondary (MEDIUM confidence)
- [composer-cli response.go](https://github.com/cubbit/composer-cli/blob/master/src/api/response.go) -- Account.endpoint_gateway, TenantSettings.console_url, TenantSettings.gateway_url field definitions
- [composer-cli tenant.go](https://github.com/cubbit/composer-cli/blob/master/src/api/tenant.go) -- GET /v1/tenants/{tenantId} endpoint for tenant info/settings
- [composer-cli project.go](https://github.com/cubbit/composer-cli/blob/master/src/api/project.go) -- Projects scoped under /v1/tenants/{tenantId}/projects
- [composer-cli url_builder.go](https://github.com/cubbit/composer-cli/blob/master/src/api/url_builder.go) -- Fluent URL builder pattern (base URL + path segments)
- [composer-cli configuration.go](https://github.com/cubbit/composer-cli/blob/master/src/configuration/configuration.go) -- IamURL = apiServerUrl + BaseIamURI, ChURL = apiServerUrl + BaseChURI
- [File Coordination Fixed (Atomic Birdhouse)](https://www.atomicbird.com/blog/file-coordination-fix/) -- NSFileCoordinator is safe between app and extension since iOS 8.2

### Tertiary (LOW confidence)
- [Cubbit Tenant Configuration Docs](https://docs.cubbit.io/composer/tenants/configuration) -- OAuth/console URL patterns per tenant, but no IAM API details
- [Cubbit Tenants Quickstart](https://docs.cubbit.io/composer/tenants/quickstart) -- General tenant concept, no API specs

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH - existing dependencies, no new packages needed
- Architecture (URL refactoring): HIGH - mechanical refactoring with clear existing patterns
- Architecture (token refresh): MEDIUM - proactive timer approach is standard, but NSFileCoordinator cross-process behavior needs runtime verification
- API spec (tenant_id in challenge): MEDIUM - Account model has tenant_id, but composer-cli uses device flow not challenge-response, so exact challenge API payload not verified from external source
- Pitfalls: HIGH - based on direct codebase analysis and established macOS extension development patterns

**Research date:** 2026-03-13
**Valid until:** 2026-04-13 (stable APIs, no fast-moving dependencies)
