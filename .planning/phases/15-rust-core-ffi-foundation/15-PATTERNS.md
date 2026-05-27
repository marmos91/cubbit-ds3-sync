# Phase 15: Rust Core + FFI Foundation - Pattern Map

**Mapped:** 2026-05-27
**Files analyzed:** 38 new files (across 6 crates + scripts + CI + harnesses + mono-repo restructure)
**Analogs found:** 28 / 38 (10 files are new infrastructure with no Swift analog)

## File Classification

| New/Modified File | Role | Data Flow | Closest Analog | Match Quality |
|-------------------|------|-----------|----------------|---------------|
| `core/Cargo.toml` | config | -- | `DS3Lib/Package.swift` | role-match |
| `core/ds3-models/src/lib.rs` | model | -- | `DS3Lib/Sources/DS3Lib/Models/` (directory) | exact |
| `core/ds3-models/src/account.rs` | model | -- | `DS3Lib/.../Models/Account.swift` | exact |
| `core/ds3-models/src/auth.rs` | model | -- | `DS3Lib/.../Models/Challenge.swift` + `Token.swift` + `AccountSession.swift` | exact |
| `core/ds3-models/src/drive.rs` | model | -- | `DS3Lib/.../Models/DS3Drive.swift` + `SyncAnchor.swift` + `Bucket.swift` | exact |
| `core/ds3-models/src/project.rs` | model | -- | `DS3Lib/.../Models/Project.swift` + `IAMUser.swift` | exact |
| `core/ds3-models/src/api_key.rs` | model | -- | `DS3Lib/.../Models/DS3APIKey.swift` | exact |
| `core/ds3-models/src/s3.rs` | model | -- | `DS3Lib/.../DS3S3Client.swift` (lines 17-170) | exact |
| `core/ds3-models/src/sync.rs` | model | -- | `DS3Lib/.../Enumeration/EnumerationDiff.swift` + `Models/ConflictInfo.swift` | exact |
| `core/ds3-models/src/error.rs` | model | -- | `DS3Lib/.../DS3Authentication.swift` (lines 6-54) + `DS3S3Client.swift` (lines 115-122) | role-match |
| `core/ds3-http/src/lib.rs` | service | request-response | `DS3Lib/.../DS3SDK.swift` | role-match |
| `core/ds3-http/src/client.rs` | service | request-response | `DS3Lib/.../DS3Authentication.swift` (URLSession usage) | role-match |
| `core/ds3-http/src/urls.rs` | utility | -- | `DS3Lib/.../Constants/URLs.swift` | exact |
| `core/ds3-http/src/projects.rs` | service | request-response | `DS3Lib/.../DS3SDK.swift` (lines 63-91) | exact |
| `core/ds3-http/src/keys.rs` | service | request-response | `DS3Lib/.../DS3SDK.swift` (lines 98-244) | exact |
| `core/ds3-auth/src/lib.rs` | service | request-response | `DS3Lib/.../DS3Authentication.swift` | exact |
| `core/ds3-auth/src/session.rs` | service | request-response | `DS3Lib/.../DS3Authentication.swift` (lines 105-144) | exact |
| `core/ds3-auth/src/challenge.rs` | service | request-response | `DS3Lib/.../DS3Authentication.swift` (lines 331-393) | exact |
| `core/ds3-auth/src/login.rs` | service | request-response | `DS3Lib/.../DS3Authentication.swift` (lines 262-289) | exact |
| `core/ds3-auth/src/refresh.rs` | service | request-response | `DS3Lib/.../DS3Authentication.swift` (lines 228-258, 152-186) | exact |
| `core/ds3-auth/src/crypto.rs` | utility | transform | `DS3Lib/.../DS3Authentication.swift` (lines 371-393) | exact |
| `core/ds3-s3/src/client.rs` | service | CRUD | `DS3Lib/.../DS3S3Client.swift` (lines 176-218) | exact |
| `core/ds3-s3/src/list.rs` | service | CRUD | `DS3Lib/.../DS3S3Client.swift` (lines 240-301) | exact |
| `core/ds3-s3/src/transfer.rs` | service | streaming | `DS3Lib/.../DS3S3Client+Transfers.swift` (lines 17-182) | exact |
| `core/ds3-s3/src/multipart.rs` | service | streaming | `DS3Lib/.../DS3S3Client+Transfers.swift` (lines 186-473) | exact |
| `core/ds3-s3/src/crud.rs` | service | CRUD | `DS3Lib/.../DS3S3Client.swift` (lines 306-342) | exact |
| `core/ds3-s3/src/markers.rs` | service | CRUD | `DS3DriveProvider/S3LibFolderMarker.swift` + `DS3Lib/.../Utils/S3PathUtils.swift` (lines 160-184) | exact |
| `core/ds3-sync/src/diff.rs` | utility | transform | `DS3Lib/.../Enumeration/EnumerationDiff.swift` | exact |
| `core/ds3-sync/src/conflict.rs` | utility | transform | `DS3Lib/.../Utils/ConflictNaming.swift` | exact |
| `core/ds3-sync/src/tree.rs` | model | -- | `DS3Lib/.../Enumeration/EnumerationDiff.swift` (lines 7-24) | role-match |
| `core/ds3-ffi/src/lib.rs` | config | -- | (none) | no-analog |
| `core/ds3-ffi/src/uniffi_exports.rs` | service | request-response | (none -- new FFI boundary) | no-analog |
| `core/ds3-ffi/src/c_exports.rs` | service | request-response | (none -- new FFI boundary) | no-analog |
| `core/ds3-ffi/src/handles.rs` | utility | -- | (none -- new FFI pattern) | no-analog |
| `core/ds3-ffi/src/progress.rs` | utility | event-driven | `DS3Lib/.../DS3S3Client.swift` (lines 88-113) | partial |
| `core/ds3-ffi/src/panic_guard.rs` | utility | -- | (none -- Rust-specific) | no-analog |
| `core/ds3-ffi/build.rs` | config | -- | (none -- csbindgen) | no-analog |
| `core/scripts/build-xcframework.sh` | config | -- | (none -- new build script) | no-analog |
| `.github/workflows/build.yml` (modified) | config | -- | `.github/workflows/build.yml` (existing) | exact |

## Pattern Assignments

### `core/ds3-models/src/account.rs` (model)

**Analog:** `DS3Lib/Sources/DS3Lib/Models/Account.swift`

**Struct shape with snake_case JSON mapping** (lines 1-122):
```swift
public struct Account: Codable, Sendable {
    public var id: String
    public var firstName: String
    public var lastName: String
    public var isInternal: Bool
    public var isBanned: Bool
    public var createdAt: String
    public var deletedAt: String?
    public var bannedAt: String?
    public var maxAllowedProjects: Int32
    public var emails: [AccountEmail]
    public var isTwoFactorEnabled: Bool
    public var tenantId: String
    public var endpointGateway: String
    public var authProvider: String

    private enum CodingKeys: String, CodingKey {
        case id
        case firstName = "first_name"
        case lastName = "last_name"
        case isInternal = "internal"
        case isBanned = "banned"
        case createdAt = "created_at"
        case deletedAt = "deleted_at"
        case bannedAt = "banned_at"
        case maxAllowedProjects = "max_allowed_projects"
        case emails
        case isTwoFactorEnabled = "two_factor_enabled"
        case tenantId = "tenant_id"
        case endpointGateway = "endpoint_gateway"
        case authProvider = "auth_provider"
    }
}
```

**Rust port pattern:** Use `#[derive(Serialize, Deserialize, Clone, Debug)]` with `#[serde(rename_all = "snake_case")]` and per-field `#[serde(rename = "...")]` for non-standard mappings like `"internal"`, `"banned"`. Use `Option<String>` for Swift `String?`.

---

### `core/ds3-models/src/auth.rs` (model)

**Analog:** `DS3Lib/Sources/DS3Lib/Models/Challenge.swift` + `Token.swift` + `AccountSession.swift`

**Challenge model** (`Challenge.swift` lines 1-10):
```swift
public struct Challenge: Codable, Sendable {
    public var challenge: String
    public var salt: String
}
```

**Token model** (`Token.swift` lines 4-48):
```swift
public struct Token: Codable, Sendable {
    public var token: String
    public var exp: Int64
    public var expDate: Date

    private enum CodingKeys: String, CodingKey {
        case token, exp
        case expDate = "exp_date"
    }
}
```

**AccountSession model** (`AccountSession.swift` lines 5-66):
```swift
public final class AccountSession: Codable, @unchecked Sendable {
    private var _token: Token
    public var token: Token { _token }
    private var _refreshToken: String
    public var refreshToken: String { _refreshToken }

    private enum CodingKeys: String, CodingKey {
        case _token = "token"
        case _refreshToken = "refreshToken"
    }
}
```

**Rust port pattern:** Token's `exp_date` is ISO 8601 string in JSON but `Date` in Swift. In Rust, use `chrono::DateTime<Utc>` with custom serde deserializer, or store as string and parse lazily. AccountSession in Rust is a simple struct (no class mutation needed -- Rust uses interior mutability via `RwLock` in the session handle).

---

### `core/ds3-models/src/drive.rs` (model)

**Analog:** `DS3Lib/Sources/DS3Lib/Models/DS3Drive.swift` + `SyncAnchor.swift` + `Bucket.swift`

**DS3Drive** (`DS3Drive.swift` lines 46-104):
```swift
public final class DS3Drive: Codable, Identifiable, Hashable, @unchecked Sendable {
    public let id: UUID
    public let syncAnchor: SyncAnchor
    public var name: String
}
```

**SyncAnchor** (`SyncAnchor.swift` lines 7-26):
```swift
public struct SyncAnchor: Codable, Sendable {
    public var project: Project
    public var IAMUser: IAMUser
    public var bucket: Bucket
    public var prefix: String?
}
```

**Bucket** (`Bucket.swift` lines 4-16):
```swift
public struct Bucket: Codable, Hashable, Identifiable, Sendable {
    public var id: String { name }
    public var name: String
}
```

**Rust port pattern:** DS3Drive uses `uuid::Uuid` for `id`. SyncAnchor embeds Project, IAMUser, Bucket inline. Bucket is just a name wrapper.

---

### `core/ds3-models/src/project.rs` (model)

**Analog:** `DS3Lib/Sources/DS3Lib/Models/Project.swift` + `IAMUser.swift`

**Project JSON keys** (`Project.swift` lines 63-74):
```swift
private enum CodingKeys: String, CodingKey {
    case id = "project_id"
    case name = "project_name"
    case description = "project_description"
    case email = "project_email"
    case createdAt = "project_created_at"
    case bannedAt = "project_banned_at"
    case imageUrl = "project_image_url"
    case tenantId = "project_tenant_id"
    case rootAccountEmail = "root_account_email"
    case users
}
```

**IAMUser JSON keys** (`IAMUser.swift` lines 15-19):
```swift
private enum CodingKeys: String, CodingKey {
    case id = "user_id"
    case username = "user_name"
    case isRoot = "is_root"
}
```

**Rust port pattern:** These use `project_`-prefixed JSON keys, requiring per-field `#[serde(rename = "project_id")]` etc. Not compatible with a blanket `rename_all`.

---

### `core/ds3-models/src/api_key.rs` (model)

**Analog:** `DS3Lib/Sources/DS3Lib/Models/DS3APIKey.swift`

**DS3ApiKey** (`DS3APIKey.swift` lines 4-64):
```swift
public struct DS3ApiKey: Codable, Equatable, Sendable {
    public var name: String
    public var apiKey: String
    public var secretKey: String?
    public var createdAt: Date

    private enum CodingKeys: String, CodingKey {
        case name
        case apiKey = "api_key"
        case secretKey = "secret_key"
        case createdAt = "created_at"
    }
}
```

**Rust port pattern:** `created_at` is ISO 8601 string in JSON. `secretKey` is only present when creating (server returns it once). Use `Option<String>`.

---

### `core/ds3-models/src/s3.rs` (model)

**Analog:** `DS3Lib/Sources/DS3Lib/DS3S3Client.swift` (lines 17-170)

**S3ListingResult** (lines 17-34):
```swift
public struct S3ListingResult: Sendable {
    public let objects: [S3ObjectSummary]
    public let commonPrefixes: [String]
    public let nextContinuationToken: String?
    public let isTruncated: Bool
}
```

**S3ObjectSummary** (lines 37-49):
```swift
public struct S3ObjectSummary: Sendable {
    public let key: String
    public let etag: String?
    public let lastModified: Date?
    public let size: Int64
}
```

**S3ObjectMetadata** (lines 52-71):
```swift
public struct S3ObjectMetadata: Sendable {
    public let etag: String?
    public let contentType: String?
    public let lastModified: Date?
    public let versionId: String?
    public let contentLength: Int64
    public let metadata: [String: String]?
}
```

**TransferProgress** (lines 89-113):
```swift
public struct TransferProgress: Sendable {
    public let bytesTransferred: Int64
    public let totalBytes: Int64?
    public let duration: TimeInterval
    public let direction: TransferDirection
    public let filename: String?
}
```

**MultipartUploadContext / PartDescriptor / CompletedPartResult** (lines 126-170):
```swift
public struct MultipartUploadContext: Sendable {
    public let bucket: String
    public let key: String
    public let uploadId: String
    public let totalSize: Int64
}

public struct PartDescriptor: Sendable {
    public let partNumber: Int
    public let offset: Int
    public let length: Int
}

public struct CompletedPartResult: Sendable {
    public let partNumber: Int
    public let etag: String
}
```

**Rust port pattern:** These are plain data structs. In Rust, derive `Clone, Debug, Serialize, Deserialize`. These types are NOT serialized from JSON API responses -- they are constructed from aws-sdk-s3 response types. Only need serde if crossing FFI boundary (UniFFI `#[derive(uniffi::Record)]`).

---

### `core/ds3-models/src/error.rs` (model)

**Analog:** `DS3Lib/Sources/DS3Lib/DS3Authentication.swift` (lines 6-54) + `DS3S3Client.swift` (lines 115-122)

**Auth errors** (`DS3Authentication.swift` lines 6-54):
```swift
public enum DS3AuthenticationError: Error, LocalizedError {
    case invalidURL(url: String? = nil)
    case timeConversion
    case cookies
    case encoding
    case serverError
    case jsonConversion
    case loggedOut
    case alreadyLoggedIn
    case alreadyLoggedOut
    case tokenExpired
    case missing2FA
}
```

**S3 client errors** (`DS3S3Client.swift` lines 115-122):
```swift
public enum DS3ClientError: Error, Sendable {
    case missingUploadId
    case emptyFileData
    case missingETag
    case parseError
    case unableToOpenFile
    case thumbnailTooLarge(size: Int, limit: Int)
}
```

**Rust port pattern:** Use `#[derive(thiserror::Error, Debug)]` with numeric error codes for FFI. Group into a single `DS3Error` enum with variants from both auth and S3 domains. UniFFI requires `#[derive(uniffi::Error)]`.

---

### `core/ds3-http/src/urls.rs` (utility)

**Analog:** `DS3Lib/Sources/DS3Lib/Constants/URLs.swift` (lines 1-78)

**Full CubbitAPIURLs class** (lines 5-78):
```swift
public final class CubbitAPIURLs: Sendable {
    public static let defaultCoordinatorURL = "https://api.eu00wi.cubbit.services"
    public let coordinatorURL: String

    public init(coordinatorURL: String = CubbitAPIURLs.defaultCoordinatorURL) {
        var url = coordinatorURL
        while url.hasSuffix("/") { url = String(url.dropLast()) }
        self.coordinatorURL = url
    }

    public var iamBaseURL: String { "\(coordinatorURL)/iam/v1" }
    public var authBaseURL: String { "\(iamBaseURL)/auth" }
    public var signinURL: String { "\(authBaseURL)/signin" }
    public var challengeURL: String { "\(signinURL)/challenge" }
    public var tokenRefreshURL: String { "\(authBaseURL)/refresh/access" }
    public var forgeAccessJWTURL: String { "\(authBaseURL)/forge/access" }
    public var accountsMeURL: String { "\(iamBaseURL)/accounts/me" }

    public var composerHubBaseURL: String { "\(coordinatorURL)/composer-hub/v1" }
    public var projectsURL: String { "\(composerHubBaseURL)/projects" }
    public var tenantsURL: String { "\(composerHubBaseURL)/tenants" }

    public var keyvaultBaseURL: String { "\(coordinatorURL)/keyvault/api/v3" }
    public var keysURL: String { "\(keyvaultBaseURL)/keys" }
}
```

**Rust port pattern:** Use a struct `CubbitAPIURLs` with methods returning `String`. Strip trailing slashes in constructor. All URL construction is string concatenation, no library needed.

---

### `core/ds3-http/src/client.rs` (service, request-response)

**Analog:** `DS3Lib/Sources/DS3Lib/DS3Authentication.swift` (HTTP pattern) + `DS3SDK.swift` (validate pattern)

**HTTP request pattern** (`DS3Authentication.swift` lines 240-258):
```swift
guard let url = URL(string: self.urls.tokenRefreshURL) else { throw DS3AuthenticationError.invalidURL() }

var request = URLRequest(url: url)
request.allHTTPHeaderFields = [
    "Content-Type": "application/json",
    "Cookie": "_refresh=\(session.refreshToken)"
]
request.httpShouldHandleCookies = true
request.httpMethod = "GET"

let (responseData, response) = try await URLSession.shared.data(for: request)
```

**Response validation** (`DS3SDK.swift` lines 45-57):
```swift
private func validateResponse(
    _ response: URLResponse,
    data: Data,
    expectedStatus: Set<Int>,
    error: Error
) throws {
    let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
    guard expectedStatus.contains(statusCode) else {
        let body = String(data: data, encoding: .utf8) ?? "<non-UTF8>"
        logger.error("An error occurred. Status code is \(statusCode) Response is: \(body)")
        throw error
    }
}
```

**Rust port pattern:** `SharedHttpClient` wraps `reqwest::Client` with `cookie_store(true)`. Owns the cookie jar for the `_refresh` token lifecycle. Provide `get_json`, `post_json` helpers that validate status codes and deserialize with serde.

---

### `core/ds3-http/src/projects.rs` (service, request-response)

**Analog:** `DS3Lib/Sources/DS3Lib/DS3SDK.swift` (lines 63-91)

**get_projects** (`DS3SDK.swift` lines 63-91):
```swift
public func getRemoteProjects() async throws -> [Project] {
    try await self.authentication.refreshIfNeeded()

    guard let url = URL(string: self.urls.projectsURL) else { ... }
    guard let session = self.authentication.accountSession else { throw DS3AuthenticationError.loggedOut }

    var request = URLRequest(url: url)
    request.allHTTPHeaderFields = [
        "Content-Type": "application/json",
        "Authorization": "Bearer \(session.token.token)"
    ]
    request.httpMethod = "GET"

    let (responseData, response) = try await URLSession.shared.data(for: request)
    try validateResponse(response, data: responseData, expectedStatus: [200], error: DS3AuthenticationError.serverError)
    guard let projects = try? JSONDecoder().decode([Project].self, from: responseData) else { ... }
    return projects
}
```

**Rust port pattern:** Takes `&SharedHttpClient` and token. Returns `Vec<Project>`. Uses reqwest `.get(url).bearer_auth(token).send().await?.json::<Vec<Project>>().await?`.

---

### `core/ds3-http/src/keys.rs` (service, request-response)

**Analog:** `DS3Lib/Sources/DS3Lib/DS3SDK.swift` (lines 98-244)

**API key management** (`DS3SDK.swift` lines 98-231):
```swift
// Get remote API keys (GET with IAM token)
public func getRemoteApiKeys(forIAMUser user: IAMUser) async throws -> [DS3ApiKey] { ... }

// Delete API key (DELETE with IAM token, URL-encoded key in path)
public func deleteApiKey(_ apiKey: DS3ApiKey, forIAMUser user: IAMUser) async throws { ... }

// Generate new API key (POST, returns new key with secret)
public func generateDS3APIKey(forIAMUser user: IAMUser, iamToken: Token, apiKeyName: String) async throws -> DS3ApiKey { ... }

// Deterministic key name
public static func apiKeyName(forUser user: IAMUser, projectName: String) -> String {
    "\(DefaultSettings.apiKeyNamePrefix)(\(user.username)_\(projectName.lowercased().replacingOccurrences(of: " ", with: "_"))_\(DefaultSettings.appUUID))"
}
```

**Rust port pattern:** Three async functions + a pure `api_key_name()` helper. The `loadOrCreateDS3APIKeys` reconciliation logic stays in the Rust layer. URL-encodes the API key in the path for DELETE.

---

### `core/ds3-auth/src/crypto.rs` (utility, transform)

**Analog:** `DS3Lib/Sources/DS3Lib/DS3Authentication.swift` (lines 371-393)

**signChallenge** (`DS3Authentication.swift` lines 371-393):
```swift
public func signChallenge(challenge: Challenge, password: String) throws -> String {
    guard let passwordBuffer = password.data(using: .utf8) else { throw DS3AuthenticationError.encoding }
    guard let saltBuffer = challenge.salt.data(using: .utf8) else { throw DS3AuthenticationError.encoding }

    let buffer = passwordBuffer + saltBuffer

    var sha = SHA256()
    sha.update(data: buffer)
    let seed = sha.finalize()

    let keychain = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)

    guard let challengeData = challenge.challenge.data(using: .utf8) else {
        throw DS3AuthenticationError.encoding
    }
    let signedChallenge = try keychain.signature(for: challengeData)

    return signedChallenge.base64EncodedString()
}
```

**Rust port (exact mapping):**
- `SHA256()` -> `sha2::Sha256::new()`
- `sha.update(data: buffer)` -> `hasher.update(password.as_bytes()); hasher.update(salt.as_bytes())`
- `sha.finalize()` -> `hasher.finalize()` (returns `[u8; 32]`)
- `Curve25519.Signing.PrivateKey(rawRepresentation: seed)` -> `ed25519_dalek::SigningKey::from_bytes(&seed)`
- `keychain.signature(for: challengeData)` -> `signing_key.sign(challenge.as_bytes())`
- `.base64EncodedString()` -> `base64::engine::general_purpose::STANDARD.encode(signature.to_bytes())`

---

### `core/ds3-auth/src/challenge.rs` (service, request-response)

**Analog:** `DS3Lib/Sources/DS3Lib/DS3Authentication.swift` (lines 331-364)

**getChallenge** (`DS3Authentication.swift` lines 331-364):
```swift
public func getChallenge(email: String, tenant: String? = nil) async throws -> Challenge {
    guard let url = URL(string: self.urls.challengeURL) else { ... }

    let challengeRequestBody = DS3ChallengeRequest(email: email, tenantId: tenant)

    let encoder = JSONEncoder()
    guard let data = try? encoder.encode(challengeRequestBody) else { throw DS3AuthenticationError.jsonConversion }

    var request = URLRequest(url: url)
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpMethod = "POST"
    request.httpBody = data

    let (responseData, response) = try await URLSession.shared.data(for: request)

    guard (response as? HTTPURLResponse)?.statusCode == 200 else { ... }
    guard let challenge = try? JSONDecoder().decode(Challenge.self, from: responseData) else { ... }

    return challenge
}
```

**Request body** (`DS3Authentication.swift` lines 61-72):
```swift
struct DS3ChallengeRequest: Codable {
    var email: String
    var tenantId: String?

    enum CodingKeys: String, CodingKey {
        case email
        case tenantId = "tenant_id"
    }
}
```

**Rust port pattern:** POST to `urls.challenge_url()` with JSON body `{"email": "...", "tenant_id": "..."}`. Deserialize response as `Challenge { challenge: String, salt: String }`.

---

### `core/ds3-auth/src/login.rs` (service, request-response)

**Analog:** `DS3Lib/Sources/DS3Lib/DS3Authentication.swift` (lines 262-289, 400-451)

**Login flow** (`DS3Authentication.swift` lines 262-289):
```swift
public func login(email: String, password: String, withTfaToken tfaCode: String? = nil, tenant: String? = nil) async throws {
    let challenge = try await self.getChallenge(email: email, tenant: tenant)
    let signedChallenge = try self.signChallenge(challenge: challenge, password: password)
    let accountSession = try await self.getAccountSession(
        email: email, signedChallengeBase64: signedChallenge, withTfaToken: tfaCode, tenant: tenant
    )
    self.accountSession = accountSession
    self.isLogged = true
    self.account = try await self.accountInfo()
}
```

**Login request body** (`DS3Authentication.swift` lines 75-95):
```swift
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

**2FA detection** (`DS3Authentication.swift` lines 438-441):
```swift
if let mfaResponse = try? JSONDecoder().decode(DS3Missing2FAResponse.self, from: responseData),
   mfaResponse.message == APIError.Missing2FA {
    throw DS3AuthenticationError.missing2FA
}
```

**Cookie extraction** (`DS3Authentication.swift` lines 457-479):
```swift
let cookies = HTTPCookie.cookies(withResponseHeaderFields: fields, for: url)
guard let refreshToken = cookies.first(where: { $0.name == "_refresh" })?.value else {
    throw DS3AuthenticationError.cookies
}
```

**Rust port pattern:** In Rust, the `_refresh` cookie is handled automatically by `reqwest`'s cookie jar (`cookie_store(true)`). However, for the response parsing, the access token comes in the JSON body. The orchestration is: `get_challenge` -> `sign_challenge` -> `post_signin` -> `get_account_info`. The `DS3Session` struct is returned holding the `SharedHttpClient` (with cookie jar), `AccountSession`, and `Account`.

---

### `core/ds3-auth/src/refresh.rs` (service, request-response)

**Analog:** `DS3Lib/Sources/DS3Lib/DS3Authentication.swift` (lines 228-258, 152-186)

**refreshIfNeeded** (`DS3Authentication.swift` lines 228-258):
```swift
public func refreshIfNeeded(force: Bool = false) async throws {
    guard self.isLogged, let session = self.accountSession else { throw DS3AuthenticationError.loggedOut }
    guard force || Date() > session.token.expDate else { return }

    guard let url = URL(string: self.urls.tokenRefreshURL) else { ... }

    var request = URLRequest(url: url)
    request.allHTTPHeaderFields = [
        "Content-Type": "application/json",
        "Cookie": "_refresh=\(session.refreshToken)"
    ]
    request.httpMethod = "GET"

    let (responseData, response) = try await URLSession.shared.data(for: request)
    let (token, refreshToken) = try self.parseTokenResponse(data: responseData, response: response, url: url)
    session.refreshTokens(token: token, refreshToken: refreshToken)
}
```

**forgeIAMToken** (`DS3Authentication.swift` lines 152-186):
```swift
public func forgeIAMToken(forIAMUser user: IAMUser) async throws -> Token {
    try await self.refreshIfNeeded()
    guard self.isLogged, let session = self.accountSession else { ... }

    guard let url = URL(string: "\(self.urls.forgeAccessJWTURL)?user_id=\(user.id)") else { ... }

    var request = URLRequest(url: url)
    request.allHTTPHeaderFields = [
        "Content-Type": "application/json",
        "Cookie": "_refresh=\(session.refreshToken)"
    ]
    request.httpMethod = "GET"

    let (responseData, response) = try await URLSession.shared.data(for: request)
    let (token, newRefreshToken) = try self.parseTokenResponse(data: responseData, response: response, url: url)
    session.refreshRefreshToken(refreshToken: newRefreshToken)
    return token
}
```

**Rust port pattern:** Both refresh and forge use `_refresh` cookie (handled by reqwest jar). Token expiry check uses `chrono::Utc::now()` vs stored `exp_date`. `DS3Session` must use `RwLock<AccountSession>` for interior mutability since refresh modifies the session from within.

---

### `core/ds3-s3/src/client.rs` (service, CRUD)

**Analog:** `DS3Lib/Sources/DS3Lib/DS3S3Client.swift` (lines 176-218)

**S3 client construction** (`DS3S3Client.swift` lines 176-218):
```swift
public final class DS3S3Client: Sendable {
    let s3: S3

    public init(
        accessKeyId: String,
        secretAccessKey: String,
        endpoint: String?,
        timeout: Int64 = DefaultSettings.S3.timeoutInSeconds
    ) {
        let client = AWSClient(
            credentialProvider: .static(
                accessKeyId: accessKeyId,
                secretAccessKey: secretAccessKey
            ),
            httpClientProvider: .createNew
        )
        self.awsClient = client
        self.s3 = S3(client: client, endpoint: endpoint, timeout: .seconds(timeout))
    }
}
```

**Rust port pattern:** Use `aws_sdk_s3::Client` with custom config: `endpoint_url(endpoint)`, `credentials_provider(static_creds)`, `force_path_style(true)`, `region("us-east-1")`. The `DS3S3Client` struct owns the `aws_sdk_s3::Client`.

---

### `core/ds3-s3/src/list.rs` (service, CRUD)

**Analog:** `DS3Lib/Sources/DS3Lib/DS3S3Client.swift` (lines 240-301)

**listObjects** (`DS3S3Client.swift` lines 240-286):
```swift
public func listObjects(
    bucket: String, prefix: String? = nil, delimiter: String? = nil,
    maxKeys: Int? = nil, continuationToken: String? = nil,
    encodingType: S3.EncodingType? = .url
) async throws -> S3ListingResult {
    let request = S3.ListObjectsV2Request(
        bucket: bucket, continuationToken: continuationToken,
        delimiter: delimiter, encodingType: encodingType,
        maxKeys: maxKeys, prefix: prefix
    )
    let response = try await s3.listObjectsV2(request)

    let decode: (String) -> String? = encodingType == .url
        ? { try? Self.decodeS3Key($0) }
        : { $0 }

    let objects = (response.contents ?? []).compactMap { object -> S3ObjectSummary? in
        guard let rawKey = object.key, let key = decode(rawKey) else { return nil }
        return S3ObjectSummary(
            key: key, etag: ETagUtils.normalize(object.eTag),
            lastModified: object.lastModified, size: object.size ?? 0
        )
    }
    // ... build and return S3ListingResult
}
```

**listBuckets** (`DS3S3Client.swift` lines 222-227):
```swift
public func listBuckets() async throws -> [(name: String, creationDate: Date?)] {
    let response = try await s3.listBuckets()
    return (response.buckets ?? []).map { bucket in
        (name: bucket.name ?? "<No name>", creationDate: bucket.creationDate)
    }
}
```

**S3 key decoding** (`DS3S3Client.swift` lines 351-358):
```swift
public static func decodeS3Key(_ key: String) throws -> String {
    let normalized = key.replacingOccurrences(of: "+", with: "%20")
    guard let decoded = normalized.removingPercentEncoding else {
        throw DS3ClientError.parseError
    }
    return decoded
}
```

**Rust port pattern:** aws-sdk-s3 `list_objects_v2()` returns typed response. Map `contents` to `S3ObjectSummary`. Handle `+` to space decoding (check if aws-sdk-s3 does this automatically with encoding-type=url).

---

### `core/ds3-s3/src/transfer.rs` (service, streaming)

**Analog:** `DS3Lib/Sources/DS3Lib/DS3S3Client+Transfers.swift` (lines 17-182)

**Download** (`DS3S3Client+Transfers.swift` lines 17-84):
```swift
func getObject(
    bucket: String, key: String, toFile fileURL: URL,
    onProgress: TransferProgressHandler? = nil
) async throws -> S3DownloadResult {
    let request = S3.GetObjectRequest(bucket: bucket, key: key)
    let response = try await streamToFile(request: request, fileURL: fileURL, key: key, onProgress: onProgress)
    return S3DownloadResult(
        etag: ETagUtils.normalize(response.eTag), contentType: response.contentType,
        lastModified: response.lastModified, contentLength: response.contentLength ?? 0
    )
}
```

**Upload** (`DS3S3Client+Transfers.swift` lines 95-153):
```swift
func putObject(
    bucket: String, key: String, fileURL: URL? = nil,
    onProgress: TransferProgressHandler? = nil
) async throws -> String? {
    // Streams file via AWSPayload.stream, 64KB chunks
    let chunkSize = 65536
    let payload = AWSPayload.stream(size: Int(size)) { eventLoop in
        let chunk = uploadHandle.readData(ofLength: chunkSize)
        // ...
    }
    request = S3.PutObjectRequest(body: payload, bucket: bucket, key: key)
    let response = try await s3.putObject(request)
    return response.eTag
}
```

**Rust port pattern:** Use `aws_sdk_s3::Client::get_object()` with `ByteStream` for download. Stream body to file via `tokio::io::copy`. For upload, use `ByteStream::from_path()` for streaming PutObject. Progress callbacks via a custom `Body` wrapper or periodic file-size polling.

---

### `core/ds3-s3/src/multipart.rs` (service, streaming)

**Analog:** `DS3Lib/Sources/DS3Lib/DS3S3Client+Transfers.swift` (lines 186-473)

**Multipart orchestration** (`DS3S3Client+Transfers.swift` lines 344-407):
```swift
func putObjectMultipart(
    bucket: String, key: String, fileURL: URL, totalSize: Int64,
    pendingUploadStore: PendingUploadStore, driveId: UUID,
    onPartComplete: (@Sendable (Int) async -> Void)? = nil,
    onProgress: TransferProgressHandler? = nil
) async throws -> String {
    let uploadId = try await createMultipartUpload(bucket: bucket, key: key)
    do {
        let newParts = try await uploadRemainingParts(...)
        let result = try await completeMultipartUpload(...)
        return result.etag
    } catch {
        try await abortMultipartUpload(bucket: bucket, key: key, uploadId: uploadId)
        throw error
    }
}
```

**Key constants** (`DefaultSettings.swift` lines 181-189):
```swift
public static let multipartUploadPartSize = 5 * 1024 * 1024 // 5 MB
public static let multipartThreshold = 5 * 1024 * 1024 // 5 MB
public static let multipartUploadConcurrency = 4
```

**Concurrent part uploads** (`DS3S3Client+Transfers.swift` lines 435-472):
```swift
return try await withThrowingTaskGroup(of: CompletedPartResult.self) { group in
    var results: [CompletedPartResult] = []
    var partIterator = remainingParts.makeIterator()

    func enqueueNext() {
        guard let part = partIterator.next() else { return }
        group.addTask {
            let data = try Self.readFilePart(at: fileURL, offset: part.offset, length: part.length)
            let result = try await self.uploadPart(
                bucket: bucket, key: key, uploadId: uploadId,
                partNumber: part.partNumber, data: data
            )
            return result
        }
    }

    for _ in 0..<min(maxConcurrency, remainingParts.count) {
        enqueueNext()
    }

    for try await completedPart in group {
        results.append(completedPart)
        enqueueNext()
    }
    return results
}
```

**Rust port pattern:** Use `create_multipart_upload` / `upload_part` / `complete_multipart_upload` from aws-sdk-s3 (low-level API, not the high-level transfer manager). Use `tokio::task::JoinSet` or `futures::stream::FuturesUnordered` with concurrency limit of 4. Read file parts via `tokio::fs::File` + `seek` + `read_exact`. Part size: 5MB. Abort on error.

---

### `core/ds3-s3/src/crud.rs` (service, CRUD)

**Analog:** `DS3Lib/Sources/DS3Lib/DS3S3Client.swift` (lines 289-342)

**headObject** (`DS3S3Client.swift` lines 289-301):
```swift
public func headObject(bucket: String, key: String) async throws -> S3ObjectMetadata {
    let request = S3.HeadObjectRequest(bucket: bucket, key: key)
    let response = try await s3.headObject(request)
    return S3ObjectMetadata(
        etag: ETagUtils.normalize(response.eTag), contentType: response.contentType,
        lastModified: response.lastModified, versionId: response.versionId,
        contentLength: response.contentLength ?? 0, metadata: response.metadata
    )
}
```

**deleteObject / deleteObjects / copyObject** (`DS3S3Client.swift` lines 306-342):
```swift
public func deleteObject(bucket: String, key: String) async throws { ... }
public func deleteObjects(bucket: String, keys: [String]) async throws -> Int { ... }
public func copyObject(bucket: String, sourceKey: String, destinationKey: String, metadata: [String: String]? = nil) async throws { ... }
```

**Rust port pattern:** Direct mapping to `aws_sdk_s3::Client` methods: `.head_object()`, `.delete_object()`, `.delete_objects()`, `.copy_object()`. Copy source format: `"bucket/key"` URL-encoded.

---

### `core/ds3-s3/src/markers.rs` (service, CRUD)

**Analog:** `DS3DriveProvider/S3LibFolderMarker.swift` + `DS3Lib/.../Utils/S3PathUtils.swift`

**Folder marker logic** (`S3LibFolderMarker.swift` lines 17-47):
```swift
func materializeEmptyFolderMarker(
    sourcePrefix: String, destinationPrefix: String,
    bucket: String, client: any DS3S3ClientProtocol, logger: os.Logger
) async throws {
    let sourceMarker = S3PathUtils.markerKey(forFolderKey: sourcePrefix)
    let destMarker = S3PathUtils.markerKey(forFolderKey: destinationPrefix)
    do {
        try await client.copyObject(bucket: bucket, sourceKey: sourceMarker, destinationKey: destMarker, metadata: nil)
    } catch where DS3S3Client.isNotFoundError(error) {
        _ = try await client.putObject(bucket: bucket, key: destMarker, fileURL: nil, onProgress: nil)
    }
}
```

**Marker key computation** (`S3PathUtils.swift` lines 179-183):
```swift
public static func markerKey(forFolderKey folderKey: String) -> String {
    let delimiter = String(DefaultSettings.S3.delimiter)
    let normalized = folderKey.hasSuffix(delimiter) ? folderKey : folderKey + delimiter
    return normalized + DefaultSettings.S3.markerFileName  // ".ds3keep"
}
```

**Probe existence** (`S3PathUtils.swift` lines 168-172):
```swift
public static func isDS3KeepMarkerKey(_ key: String) -> Bool {
    let marker = DefaultSettings.S3.markerFileName
    if key == marker { return true }
    return key.hasSuffix(String(DefaultSettings.S3.delimiter) + marker)
}
```

**Rust port pattern:** `probe_folder_exists` uses `head_object` on the marker key (catch NotFound). `create_folder_marker` uses `put_object` with empty body. `copy_folder_marker` copies marker key with fallback to fresh PUT on NotFound.

---

### `core/ds3-sync/src/diff.rs` (utility, transform)

**Analog:** `DS3Lib/Sources/DS3Lib/Enumeration/EnumerationDiff.swift`

**Full diff computation** (`EnumerationDiff.swift` lines 29-55):
```swift
public enum EnumerationDiff {
    public static func compute(
        local: [String: String?],
        remote: [String: String?]
    ) -> EnumerationDelta {
        let localKeys = Set(local.keys)
        let remoteKeys = Set(remote.keys)

        let added = remoteKeys.subtracting(localKeys)
        let common = remoteKeys.intersection(localKeys)
        let modified = common.filter { key in
            let localETag = local[key].flatMap(\.self)
            let remoteETag = remote[key].flatMap(\.self)
            return localETag != remoteETag
        }
        let deleted = localKeys.subtracting(remoteKeys)

        return EnumerationDelta(
            newOrModified: added.union(modified),
            deleted: deleted
        )
    }
}
```

**EnumerationDelta** (`EnumerationDiff.swift` lines 7-24):
```swift
public struct EnumerationDelta: Sendable, Equatable {
    public let newOrModified: Set<String>
    public let deleted: Set<String>
    public var isEmpty: Bool { newOrModified.isEmpty && deleted.isEmpty }
}
```

**Rust port pattern:** Pure function `compute_diff(local: &HashMap<String, Option<String>>, remote: &HashMap<String, Option<String>>) -> DiffResult`. Returns `DiffResult { new_or_modified: HashSet<String>, deleted: HashSet<String> }`. Unit-testable with no I/O.

---

### `core/ds3-sync/src/conflict.rs` (utility, transform)

**Analog:** `DS3Lib/Sources/DS3Lib/Utils/ConflictNaming.swift`

**Full conflict key generation** (`ConflictNaming.swift` lines 5-66):
```swift
public enum ConflictNaming: Sendable {
    public static func conflictKey(
        originalKey: String, hostname: String, date: Date,
        nonce: String = String(UUID().uuidString.prefix(4).lowercased())
    ) -> String {
        let dateStr = formatDate(date)

        let nsKey = originalKey as NSString
        let parentPath = nsKey.deletingLastPathComponent
        let filename = nsKey.lastPathComponent

        let nsFilename = filename as NSString
        let rawExt = nsFilename.pathExtension
        let isHiddenWithoutExt = filename.hasPrefix(".") && nsFilename.deletingPathExtension.isEmpty

        let name: String
        let ext: String
        if rawExt.isEmpty || isHiddenWithoutExt {
            name = filename; ext = ""
        } else {
            name = nsFilename.deletingPathExtension; ext = rawExt
        }

        let suffix = " (Conflict on \(hostname) \(dateStr) \(nonce))"
        let newFilename = ext.isEmpty ? "\(name)\(suffix)" : "\(name)\(suffix).\(ext)"

        if parentPath.isEmpty || parentPath == "." { return newFilename }
        return parentPath + "/\(newFilename)"
    }

    private static func formatDate(_ date: Date) -> String {
        // "yyyy-MM-dd HH-mm-ss" in UTC, en_US_POSIX locale
    }
}
```

**Rust port pattern:** Use `chrono::Utc::now().format("%Y-%m-%d %H-%M-%S")` for date. Use `uuid::Uuid::new_v4().to_string()[..4]` for nonce. Split filename with `std::path::Path` methods or manual string ops (S3 keys use `/` not platform paths). The `ConflictInfo` struct from `Models/ConflictInfo.swift` maps directly.

---

### `core/ds3-ffi/src/progress.rs` (utility, event-driven)

**Analog (partial):** `DS3Lib/Sources/DS3Lib/DS3S3Client.swift` (lines 88-113)

**TransferProgress callback** (`DS3S3Client.swift` lines 88-113):
```swift
public struct TransferProgress: Sendable {
    public let bytesTransferred: Int64
    public let totalBytes: Int64?
    public let duration: TimeInterval
    public let direction: TransferDirection
    public let filename: String?
}

public typealias TransferProgressHandler = @Sendable (TransferProgress) -> Void
```

**Rust port pattern:** UniFFI side: `#[uniffi::export(callback_interface)] pub trait ProgressCallback: Send + Sync { fn on_progress(&self, bytes_transferred: i64, total_bytes: i64); }`. C# side: `pub type DS3ProgressCallback = extern "C" fn(bytes_transferred: i64, total_bytes: i64, context: *mut c_void);`.

---

### `.github/workflows/build.yml` (config, modified)

**Analog:** `.github/workflows/build.yml` (existing, lines 1-136)

**Current structure** (key sections):
```yaml
jobs:
  lint:           # SwiftLint
  build:          # xcodebuild clean build analyze (macOS)
  test-unit:      # swift test --package-path DS3Lib
  test-integration: # swift test --package-path DS3Lib --filter Integration
  build-ios:      # xcodebuild build (iOS Simulator)
```

**Integration test secret pattern** (lines 79-85):
```yaml
test-integration:
    if: github.event_name == 'push' || github.event.pull_request.head.repo.full_name == github.repository
    env:
      DS3_TEST_EMAIL: ${{ secrets.DS3_TEST_EMAIL }}
      DS3_TEST_PASSWORD: ${{ secrets.DS3_TEST_PASSWORD }}
      DS3_TEST_BUCKET: ${{ secrets.DS3_TEST_BUCKET }}
```

**Rust port pattern:** Add new jobs: `rust-lint` (cargo fmt --check + cargo clippy), `rust-test-unit` (cargo test --workspace --lib), `rust-test-integration` (cargo test --workspace --features integration, same secret pattern). Update path references for `apple/` subdirectory (D-02). Add `csharp-test` job on `windows-latest` runner (D-08).

---

## Shared Patterns

### Authentication Header Pattern
**Source:** `DS3Lib/Sources/DS3Lib/DS3SDK.swift` lines 72-76, `DS3Authentication.swift` lines 547-549
**Apply to:** `ds3-http/src/projects.rs`, `ds3-http/src/keys.rs`, `ds3-auth/src/refresh.rs`
```swift
request.allHTTPHeaderFields = [
    "Content-Type": "application/json",
    "Authorization": "Bearer \(session.token.token)"
]
```

### Cookie-Based Auth Pattern
**Source:** `DS3Lib/Sources/DS3Lib/DS3Authentication.swift` lines 244-248
**Apply to:** `ds3-auth/src/refresh.rs`, `ds3-http/src/client.rs`
```swift
request.allHTTPHeaderFields = [
    "Content-Type": "application/json",
    "Cookie": "_refresh=\(session.refreshToken)"
]
request.httpShouldHandleCookies = true
```
**Rust note:** reqwest's `cookie_store(true)` handles this automatically. The `_refresh` cookie is set by the server in `Set-Cookie` response headers during login and refresh calls. No manual cookie extraction needed.

### JSON CodingKeys Pattern (serde rename)
**Source:** All model files in `DS3Lib/Sources/DS3Lib/Models/`
**Apply to:** All files in `ds3-models/src/`
```swift
// Swift pattern:
private enum CodingKeys: String, CodingKey {
    case firstName = "first_name"
    case tenantId = "tenant_id"
}

// Rust equivalent:
#[derive(Serialize, Deserialize)]
struct Account {
    #[serde(rename = "first_name")]
    first_name: String,
    #[serde(rename = "tenant_id")]
    tenant_id: String,
}
```
**Note:** Most models use snake_case JSON keys with a few exceptions (`"internal"` for `isInternal`, `"banned"` for `isBanned`, `"project_id"` prefix pattern for Project fields). Use per-field `#[serde(rename)]` rather than `#[serde(rename_all)]`.

### Error Handling Pattern
**Source:** `DS3Lib/Sources/DS3Lib/DS3Authentication.swift` lines 6-54
**Apply to:** `ds3-models/src/error.rs`, all service crates
```swift
public enum DS3AuthenticationError: Error, LocalizedError {
    case invalidURL(url: String? = nil)
    case serverError
    case jsonConversion
    case loggedOut
    case tokenExpired
    case missing2FA
}
```
**Rust equivalent:**
```rust
#[derive(thiserror::Error, Debug, uniffi::Error)]
pub enum DS3Error {
    #[error("Invalid URL: {url}")]
    InvalidUrl { url: String },
    #[error("Server error: HTTP {status}")]
    ServerError { status: u16 },
    #[error("Not logged in")]
    LoggedOut,
    #[error("Token expired")]
    TokenExpired,
    #[error("2FA code required")]
    Missing2FA,
    // ... S3 errors, IO errors, etc.
}
```

### S3 Constants Pattern
**Source:** `DS3Lib/Sources/DS3Lib/Constants/DefaultSettings.swift` lines 173-224
**Apply to:** `ds3-s3/src/client.rs`, `ds3-s3/src/multipart.rs`, `ds3-s3/src/markers.rs`
```swift
public enum S3 {
    public static let listBatchSize = 2000
    public static let delimiter: Character = "/"
    public static let multipartUploadPartSize = 5 * 1024 * 1024
    public static let multipartThreshold = 5 * 1024 * 1024
    public static let multipartUploadConcurrency = 4
    public static let timeoutInSeconds: Int64 = 5 * 60
    public static let maxRetries = 5
    public static let markerFileName = ".ds3keep"
}
```
**Rust equivalent:** `pub mod constants` or a `const` block in the relevant module.

### ETag Normalization Pattern
**Source:** Used throughout `DS3S3Client.swift` -- `ETagUtils.normalize(response.eTag)`
**Apply to:** `ds3-s3/src/list.rs`, `ds3-s3/src/crud.rs`, `ds3-s3/src/transfer.rs`
**Rust note:** aws-sdk-s3 may return ETags with surrounding quotes. Strip them: `.trim_matches('"')`.

## No Analog Found

Files with no close match in the codebase (planner should use RESEARCH.md patterns instead):

| File | Role | Data Flow | Reason |
|------|------|-----------|--------|
| `core/ds3-ffi/src/lib.rs` | config | -- | UniFFI scaffolding macro (`uniffi::setup_scaffolding!()`) -- new Rust pattern |
| `core/ds3-ffi/src/uniffi_exports.rs` | service | request-response | UniFFI `#[uniffi::export]` functions -- new FFI boundary, patterns in RESEARCH.md |
| `core/ds3-ffi/src/c_exports.rs` | service | request-response | `extern "C"` functions for csbindgen -- new FFI boundary, patterns in RESEARCH.md |
| `core/ds3-ffi/src/handles.rs` | utility | -- | Opaque `DS3Session` handle management -- new pattern from design spec |
| `core/ds3-ffi/src/panic_guard.rs` | utility | -- | `catch_unwind` macro wrapper -- Rust FFI safety, pattern in RESEARCH.md |
| `core/ds3-ffi/build.rs` | config | -- | csbindgen code generation in build script -- pattern in RESEARCH.md |
| `core/ds3-ffi/uniffi.toml` | config | -- | UniFFI configuration -- new file |
| `core/scripts/build-xcframework.sh` | config | -- | XCFramework build script -- complete example in RESEARCH.md |
| `core/tests/swift_harness/Package.swift` | test | -- | Swift test package consuming XCFramework -- new infrastructure |
| `core/tests/csharp_harness/Program.cs` | test | -- | C# console app calling P/Invoke -- new infrastructure |

## Metadata

**Analog search scope:** `DS3Lib/Sources/DS3Lib/`, `DS3DriveProvider/`, `.github/workflows/`
**Files scanned:** 89 Swift source files + 4 YAML workflows
**Pattern extraction date:** 2026-05-27
