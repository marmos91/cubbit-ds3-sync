# External Integrations

**Analysis Date:** 2026-03-11

## APIs & External Services

**Cubbit IAM (Identity & Access Management):**
- **Service:** Cubbit identity provider
  - Base URL: `https://api.cubbit.eu/iam/v1`
  - SDK/Client: Custom implementation in `DS3Lib/DS3Authentication.swift`
  - Auth: JWT tokens (Bearer scheme) with 2FA support
  - Endpoints:
    - `POST /auth/signin/challenge` - Retrieve challenge for challenge-response auth
    - `POST /auth/signin` - Sign in with signed challenge + optional 2FA code
    - `POST /auth/refresh/access` - Refresh access tokens
    - `POST /auth/forge/access` - Generate IAM user tokens
    - `GET /accounts/me` - Retrieve current account info

**Cubbit Composer Hub (Project & Drive Management):**
- **Service:** Project and drive enumeration
  - Base URL: `https://api.cubbit.eu/composer-hub/v1`
  - SDK/Client: REST calls in `DS3Lib/DS3SDK.swift`
  - Auth: JWT bearer token (from IAM)
  - Endpoints:
    - `GET /projects` - List projects for authenticated user

**Cubbit KeyVault (Key Management Service):**
- **Service:** S3 API key management
  - Base URL: `https://api.cubbit.eu/keyvault/api/v3`
  - SDK/Client: REST calls in `DS3Lib/DS3SDK.swift`
  - Auth: IAM-forged JWT token scoped to specific IAM user
  - Endpoints:
    - `GET /keys?user_id={userId}` - Retrieve all API keys for IAM user
    - `POST /keys` - Create new S3 API key
    - `DELETE /keys/{apiKey}?user_id={userId}` - Delete specific API key

**Cubbit DS3 (S3-Compatible Storage):**
- **Service:** S3-compatible object storage backend
  - Connection: Standard S3 protocol with custom endpoint
  - Client: `Soto (SotoS3) v6.8.0` - AWS S3 library
  - Auth: S3 API credentials (access key + secret key)
  - Operations:
    - `ListBucket` - Enumerate objects in bucket with prefix/delimiter
    - `GetObject` - Download file content
    - `PutObject` - Upload file content
    - `DeleteObject` - Delete file
    - `CopyObject` - Move/rename file
    - `GetObjectAttributes` - Retrieve metadata (size, modification time, ETag)
    - Multipart upload for files > 5MB (see `DS3Lib/S3Lib.swift`)

## Data Storage

**Databases:**
- Not applicable - no traditional database

**File Storage:**
- Local filesystem only for synced cache
- Primary storage: Cubbit DS3 (S3-compatible storage)

**Caching:**
- **File Provider cache** - NSFileProvider framework manages local file cache
- **SharedData persistence** - JSON files in App Group container:
  - Location: `~/Library/Group Containers/group.io.cubbit.CubbitDS3Sync/`
  - Files stored: Drive configurations, sync anchors, API keys, account session, credentials
  - Implementation: `DS3Lib/Models/SharedData.swift` and extensions

## Authentication & Identity

**Auth Provider:**
- Custom Cubbit IAM service
  - Implementation: `DS3Lib/DS3Authentication.swift`
  - Method: Challenge-response authentication
    - Client generates challenge request
    - Server responds with random challenge
    - Client signs challenge with private key (Curve25519 - CryptoKit)
    - Client sends signed challenge back
    - Server verifies signature, issues JWT tokens
  - Token Types:
    - **Access token** - Short-lived JWT for API calls
    - **Refresh token** - Long-lived token to obtain new access tokens
  - 2FA Support:
    - Optional 2FA code passed in login request if enabled
    - Detection: API returns 400 with "missing two factor code" message
  - Session Management: `DS3Lib/Models/AccountSession.swift`
    - Stores access token, refresh token, expiration time
    - Persisted to App Group container via SharedData

## Monitoring & Observability

**Error Tracking:**
- None detected - errors logged to os.log only

**Logs:**
- **os.log** (Darwin Unified Logging):
  - Subsystems:
    - `com.cubbit.CubbitDS3Sync` - Main app logging
    - `io.cubbit.CubbitDS3Sync.DS3Lib` - Library logging
    - `io.cubbit.CubbitDS3Sync.provider` - File Provider extension logging
  - Categories: DS3SDK, DS3Authentication, FileProviderExtension, S3Lib, etc.
  - View logs: Console.app → System logs → Filter by subsystem

## CI/CD & Deployment

**Hosting:**
- macOS App Store (distribution possible)
- Direct app distribution

**CI Pipeline:**
- **GitHub Actions** (`.github/workflows/build.yml`)
  - Trigger: Push and pull requests to main
  - Job: `xcodebuild clean build analyze`
  - No publish/deploy step in main branch

## Environment Configuration

**Required env vars:**
- None - all configuration stored in Xcode project settings or App Group container
- Credentials stored in App Group container (not env vars) for security

**Secrets location:**
- App Group container: `~/Library/Group Containers/group.io.cubbit.CubbitDS3Sync/`
  - Contains: Account session, refresh tokens, API keys
- Keychain: Passwords and sensitive credentials (if used)
- No `.env` file or external secret management

## Webhooks & Callbacks

**Incoming:**
- None detected

**Outgoing:**
- **DistributedNotificationCenter** (inter-process):
  - Main app ↔ File Provider extension communication
  - Used for: Sync status updates, transfer speeds, drive changes
  - Not external webhooks - internal IPC mechanism

## App Group Container Structure

**Location:** `~/Library/Group Containers/group.io.cubbit.CubbitDS3Sync/`

**Persisted Data (JSON files via SharedData):**
- Account session (token, refresh token, expiration)
- Account information (user profile)
- DS3 drives (configuration per domain identifier)
- Sync anchors (bucket, prefix, project, IAM user per drive)
- API keys (S3 credentials for each drive)

**Access:**
- Shared between main app and File Provider extension
- Allows extension to access credentials and drive configuration without app being active
- Serialized via Codable protocol

## API Design Patterns

**Authentication Flow:**
1. User enters email in login view
2. Request challenge from `/auth/signin/challenge`
3. Client signs challenge with Curve25519 private key
4. POST signed challenge + optional 2FA to `/auth/signin`
5. Receive JWT tokens (access + refresh) + cookies
6. Store in App Group container via SharedData

**Drive Setup Flow:**
1. Retrieve projects via `/projects` endpoint
2. Select project and IAM user
3. Request API keys from `/keys?user_id={userId}` via forged IAM token
4. Reconcile local vs remote API keys (create if needed)
5. Create NSFileProviderDomain with S3 endpoint
6. Store SyncAnchor (bucket, prefix, project, user) to App Group container

**S3 Interaction:**
- All S3 operations via Soto S3 client
- Credentials loaded from App Group container
- File Provider extension enumerates and manages cache
- Multipart uploads for files > 5MB

---

*Integration audit: 2026-03-11*
