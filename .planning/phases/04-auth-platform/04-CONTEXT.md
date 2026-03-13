# Phase 4: Auth & Platform - Context

**Gathered:** 2026-03-13
**Status:** Ready for planning

<domain>
## Phase Boundary

Update authentication to current IAM v1 APIs with tenant support, auto-manage API keys transparently, make all API endpoints configurable via coordinator URL, and add resilient token refresh. Users can log in with tenant-aware credentials, API keys are managed under the hood, and all endpoints derive from a single configurable coordinator base URL. The tray menu gains connection info display, user email, and sign out. Conflict resolution UI and Finder sync badges are out of scope (Phase 5).

</domain>

<decisions>
## Implementation Decisions

### Tenant Login Experience
- Login screen extended (not redesigned) with an "Advanced" inline DisclosureGroup toggle below the password field
- "Advanced" section reveals two fields: tenant name and coordinator URL
- Tenant field is free text, no pre-validation -- server returns error on invalid tenant
- No default tenant pre-filled -- field starts empty; most consumers don't need it
- Last-used tenant remembered in UserDefaults across logout/re-login
- S3 endpoint discovered from `Account.endpointGateway` (already implemented) -- no Composer Hub call needed for endpoint discovery
- Tenant name stored in SharedData alongside account/session for extension access
- Exact API field name for tenant (tenant_id vs tenant_name) to be researched from composer-cli
- Challenge endpoint tenant_id inclusion: Claude's discretion based on composer-cli reference
- 2FA screen (MFAView) unchanged -- works as-is

### Coordinator URL Configuration
- Coordinator URL field in login "Advanced" section, pre-filled with current default (`https://api.eu00wi.cubbit.services`)
- Simple base URL swap: replace hardcoded base URL, all API paths stay the same ({coordinatorURL}/iam/v1/..., /composer-hub/v1/..., /keyvault/api/v3/...)
- Refactor URLs.swift from static enum to instance-based class that takes coordinator URL in initializer
- DS3Authentication and DS3SDK accept URLs instance via initializer injection (not global state)
- Both main app and extension construct their own URLs instance from SharedData
- Coordinator URL stored in SharedData for extension access
- Changing coordinator URL requires re-login (prevents split-state)
- No pre-validation of coordinator URL -- login attempt is the validation
- Console URL retrieved from Composer Hub tenant info (research phase to verify endpoint from composer-cli)
- Logout preserves both tenant and coordinator URL settings (only clears auth tokens/account/drives)

### Token Refresh Resilience
- Proactive refresh: 5 minutes before token expiry, background timer checks and refreshes ahead of time
- Extension refreshes independently -- reads refresh token from SharedData, calls /iam/v1/auth/refresh/access, persists new tokens back
- File lock (NSFileCoordinator or POSIX) on SharedData token files to prevent race conditions between app and extension
- On refresh failure: drives enter error state, macOS notification "DS3 Drive session expired -- sign in to resume syncing", clicking opens login screen
- Extension notifies main app of auth failure via DistributedNotificationCenter (reuses existing IPC pattern)

### API Key Management
- Reactive handling only -- API keys don't expire on timer, detected via S3 403 Forbidden
- Self-healing: extension detects 403, uses stored auth token to recreate API key via loadOrCreateDS3APIKeys, retries S3 operation
- If self-healing fails, drive enters error state
- Silent operation -- no user notification for successful key recreation, OSLog only

### API Spec Verification
- Primary reference: composer-cli GitHub repo (github.com/cubbit/composer-cli)
- Secondary: live API testing with test accounts on 2 tenants (NGC and neonswarm)
- Research phase maps full Composer Hub API surface (not just existing endpoints)
- No backward compatibility -- target current API spec only, clean break
- Test credentials to be provided before research phase (not stored in repo)

### Error/Status Messaging
- Specific error messages per failure type:
  - Wrong credentials: "Invalid email or password"
  - Invalid tenant: "Tenant not found"
  - Network error: "Cannot connect to coordinator"
  - 2FA error: "Invalid verification code"
  - Session expired: "DS3 Drive session expired -- sign in to resume syncing"
- API key self-healing: silent with OSLog, no user-facing notification unless it fails

### Tray Menu Updates
- Expandable "Connection Info" disclosure section at bottom of tray menu (before Quit)
- Shows all four fields: coordinator URL, S3 endpoint, tenant name, console URL
- Fields are click-to-copy (copies value to clipboard with brief "Copied" confirmation)
- Logged-in user email displayed: "Signed in as user@email.com"
- "Sign Out" action in tray menu -- does full cleanup (tokens, drives, File Provider domains, API keys)
- Sign out preserves tenant and coordinator URL settings in UserDefaults

### Claude's Discretion
- Challenge endpoint tenant_id inclusion (verify from composer-cli)
- File lock implementation choice (NSFileCoordinator vs POSIX)
- Proactive refresh timer implementation (Timer, DispatchSource, or async Task)
- Exact DisclosureGroup styling and animation
- Connection Info label formatting in tray menu
- Error message wording refinements
- Composer Hub endpoint for console URL discovery

</decisions>

<specifics>
## Specific Ideas

- "Advanced" toggle in login mirrors enterprise app patterns -- clean for consumers, available for power users
- Coordinator URL pre-filled so it "just works" for default users but is editable for self-hosted setups
- Connection Info in tray menu serves as a debug/verification tool -- "so we can verify everything is working"
- Sign Out does full cleanup (not just auth clear) -- clean slate on re-login
- Console URL should come from Composer Hub tenant info, not be hardcoded or derived from coordinator URL

</specifics>

<code_context>
## Existing Code Insights

### Reusable Assets
- `DS3Authentication` (DS3Lib): Full challenge-response flow with Curve25519 -- needs tenant_id addition to requests
- `DS3SDK` (DS3Lib): API key reconciliation with deterministic naming -- needs URLs injection
- `CubbitAPIURLs` (DS3Lib/Constants/URLs.swift): Hardcoded URL enum -- refactor to instance-based class
- `SharedData` (DS3Lib/SharedData/): App Group persistence for account, session, API keys, drives -- extend for tenant and coordinator URL
- `NotificationManager` (DS3DriveProvider): DistributedNotificationCenter wrapper -- extend for auth failure IPC
- `LoginView` / `MFAView` (DS3Drive/Views/Login/): Working login UI -- extend with Advanced section
- `ConflictNotificationHandler` (DS3Drive): UNUserNotificationCenter pattern -- reuse for auth notifications

### Established Patterns
- `@Observable` for view model state management
- Guard-let chain init in extension methods
- Structured OSLog with subsystem/category
- DistributedNotificationCenter for extension-to-app IPC
- UNUserNotificationCenter for macOS notifications with actionable categories
- `try?` for SharedData operations to avoid blocking
- `withRetries()` for operation retry with backoff

### Integration Points
- `DS3Authentication.getChallenge()` / `.getAccountSession()`: Add tenant_id to request bodies
- `CubbitAPIURLs`: Replace with instance-based URLs, inject into DS3Authentication and DS3SDK
- `SharedData`: Add tenant name and coordinator URL persistence
- `FileProviderExtension.init()`: Read coordinator URL from SharedData, construct URLs instance
- `LoginViewModel`: Add tenant/coordinator URL fields, persist to UserDefaults and SharedData
- `TrayMenuView` (or equivalent): Add Connection Info section, user email, Sign Out action
- Token refresh: Add proactive timer in both app and extension processes

</code_context>

<deferred>
## Deferred Ideas

- Conflict resolution UI (keep/discard/merge) -- Phase 5
- Finder sync badges -- Phase 5
- Menu bar sync status per drive -- Phase 5
- Drive setup wizard redesign with tenant-aware project/bucket selection -- Phase 5 (UX-06)

</deferred>

---

*Phase: 04-auth-platform*
*Context gathered: 2026-03-13*
