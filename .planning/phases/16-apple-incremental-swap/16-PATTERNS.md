# Phase 16: Apple Incremental Swap — Pattern Map

**Mapped:** 2026-05-28
**Files analyzed:** 22 (12 Swift create/modify, 8 Rust add/modify, 1 CI, 1 build wiring)
**Analogs found:** 22 / 22 (100% — this phase is a swap, all surfaces already exist)

This phase replaces internals of three Swift façades with Rust core calls. Every new file or modified file has a direct in-repo analog. Copy the pattern from the analog and replace the Soto/URLSession/CryptoKit innards with `DS3SessionHandle` method calls. The public Swift signatures (protocol conformances, `@Observable` properties, App Group JSON persistence) MUST remain byte-identical so the FileProvider extension, ViewModels, and 156+ existing unit tests stay green without modification.

---

## File Classification

| New/Modified File | Role | Data Flow | Closest Analog | Match Quality |
|-------------------|------|-----------|----------------|---------------|
| `apple/DS3Lib/Sources/DS3Lib/DS3S3Client.swift` (rewrite internals) | adapter / service | request-response | self (current Soto impl) — replace body, keep signatures | exact (self) |
| `apple/DS3Lib/Sources/DS3Lib/DS3S3Client+Transfers.swift` (rewrite) | adapter extension | streaming / multipart | self — replace `s3.getObjectStreaming`/`putObject` with `handle.download_object`/`upload_object` + FFI gap closures | exact (self) |
| `apple/DS3Lib/Sources/DS3Lib/DS3S3Client+Presign.swift` (rewrite) | adapter extension | request-response (URL gen) | self — replace `s3.signURL` with `handle.presignGet` and new `handle.presignUploadPart` | exact (self) |
| `apple/DS3Lib/Sources/DS3Lib/DS3S3Client+Thumbnails.swift` (no-op) | protocol extension | request-response | self — body retained verbatim | exact (self) |
| `apple/DS3Lib/Sources/DS3Lib/DS3S3Client+ThumbnailPrefix.swift` (no-op) | protocol extension | request-response | self — body retained verbatim | exact (self) |
| `apple/DS3Lib/Sources/DS3Lib/DS3S3Client+Protocol.swift` (no-op) | protocol conformance | — | self — body retained verbatim | exact (self) |
| `apple/DS3Lib/Sources/DS3Lib/DS3S3Error.swift` (NEW) | error enum | — | `DS3AuthenticationError` (DS3Authentication.swift:6-54) + `DS3SDKError` (DS3SDK.swift:5-23) + `extension AWSErrorType` (FileProviderExtension+Errors.swift:49-93) | composite (3 analogs) |
| `apple/DS3Lib/Sources/DS3Lib/DS3Authentication.swift` (rewrite internals) | adapter / `@Observable` | request-response | self — replace URLSession + CryptoKit with `DS3SessionHandle.authenticate` / `verify2fa` / `refreshToken` / `forgeIamToken` | exact (self) |
| `apple/DS3Lib/Sources/DS3Lib/DS3SDK.swift` (rewrite internals) | adapter / `@Observable` | request-response | self — replace URLSession with `handle.get_projects` / `load_api_keys` / `create_api_key` / `delete_api_key` | exact (self) |
| `apple/DS3Lib/Sources/DS3Lib/Enumeration/SyncAnchorHash.swift` (modify) | hashing utility | transform | self — replace `import CryptoKit` + `SHA256.hash(...)` with `import CommonCrypto` + `CC_SHA256` | exact (self) |
| `apple/DS3Lib/Package.swift` (modify) | config | — | self — add `.binaryTarget`, drop `soto`, audit `swift-nio` | exact (self) |
| `apple/DS3Drive.xcodeproj/project.pbxproj` (modify — add Run Script Phase) | config | — | **no existing Run Script Phase in this project** — pattern derived from `core/scripts/build-xcframework.sh` interface + canonical Mozilla UniFFI Xcode setup | RESEARCH-only (see §"No Analog Found") |
| `apple/DS3DriveProvider/FileProviderExtension+Errors.swift` (modify) | error mapping | transform | self — replace `extension AWSErrorType` (line 49) with `extension DS3S3Error`; preserve `NSFileProviderError.Code` switch logic verbatim | exact (self) |
| `apple/DS3DriveProvider/FileProviderExtension.swift` + `+Create` + `+Modify` + `+Delete` (catch sites) | catch-block migration | — | self — `catch let s3Error as AWSErrorType` → `catch let s3Error as DS3S3Error` | exact (self) |
| `apple/DS3Lib/Tests/DS3LibTests/SchemaParityTests.swift` (NEW) | test | — | `core/ds3-models/tests/serde_tests.rs` mirror (esp. `test_ds3_drive_round_trip`, lines 232-270) | role-match cross-language |
| `apple/DS3Lib/Tests/DS3LibTests/DS3S3ErrorTranslationTests.swift` (NEW) | test | — | `DescribeSotoErrorTests.swift` + `core/ds3-models/tests/serde_tests.rs::test_ds3_error_codes` (lines 354-402) | role-match |
| `core/ds3-ffi/src/uniffi_exports.rs` (extend) | FFI export | request-response | self — add `download_to_memory`, `upload_from_memory`, `presign_upload_part`, `current_session`, extend `copy_object` w/ metadata, free fn `ds3_error_code` | exact (self) |
| `core/ds3-ffi/src/cancellation.rs` (NEW) | FFI Object (uniffi::Object) | event-driven | `DS3SessionHandle` struct definition in uniffi_exports.rs:36-40 (Arc + RwLock pattern) | role-match (same uniffi::Object idiom) |
| `core/ds3-s3/src/multipart.rs` (modify — thread cancellation) | service | streaming | self — add cancellation token check between parts (see lines 130-198 stream loop) | exact (self) |
| `core/ds3-s3/src/crud.rs` (extend — `download_to_memory`, `upload_from_memory`, metadata copy) | service | streaming | self + aws-sdk-s3 ByteStream pattern from multipart.rs:160 (`ByteStream::from(buf)`) | exact (self) |
| `core/ds3-http/src/client.rs` (modify — verify/add retry) | service | request-response | self — current builder pattern lines 28-34, add `reqwest-retry` middleware OR document aws-sdk-s3-only retry | exact (self) |
| `core/ds3-models/tests/fixtures/*.json` (NEW) + `tests/serde_tests.rs` (extend) | test fixtures | — | `core/ds3-models/tests/serde_tests.rs::test_ds3_drive_round_trip` (lines 232-270) — current pattern uses inline `json!()`, extend with `include_bytes!()` from fixtures | role-match (extension of existing) |
| `.github/workflows/build.yml` (modify) | CI | — | self — `rust-check` job at line 22, `cargo test --workspace --lib` at line 50 — bump to `--lib --tests` and add xcframework prebuild step before xcodebuild | exact (self) |

---

## Pattern Assignments

### `DS3S3Client.swift` rewrite (adapter, request-response)

**Analog:** `apple/DS3Lib/Sources/DS3Lib/DS3S3Client.swift` (self, current Soto impl) — keep the **shape**, replace the **mechanism**.

**Class declaration to preserve** (DS3S3Client.swift:176-217):
```swift
public final class DS3S3Client: Sendable {
    let logger = os.Logger(subsystem: LogSubsystem.provider, category: LogCategory.transfer.rawValue)
    public let customEndpoint: String?

    public init(
        accessKeyId: String,
        secretAccessKey: String,
        endpoint: String?,
        timeout: Int64 = DefaultSettings.S3.timeoutInSeconds
    ) { /* ... */ }

    public func shutdown() throws { /* ... */ }
}
```

**Deviation for new impl:** the singleton `DS3SessionHandle` is borrowed (researcher recommendation §"DS3SessionHandle Lifecycle in Swift"). Rust owns the `aws-sdk-s3` client; Swift holds a reference only. `awsClient` property and `deinit { try? awsClient.syncShutdown() }` are deleted.

```swift
// New init signature (research §"Pattern 2 + Pitfall 3"):
public init(handle: DS3SessionHandle, endpoint: String, accessKey: String, secretKey: String) throws {
    self.handle = handle
    self.customEndpoint = endpoint
    try handle.connectS3(endpoint: endpoint, accessKey: accessKey, secretKey: secretKey, region: nil)
}
```

**Per-method adapter pattern to copy** — derived from RESEARCH §"Pattern 1: Adapter Owns Translation":
```swift
public func headObject(bucket: String, key: String) async throws -> S3ObjectMetadata {
    do {
        let meta = try handle.headObject(bucket: bucket, key: key)
        return S3ObjectMetadata(
            etag: ETagUtils.normalize(meta.etag),
            contentType: meta.contentType,
            lastModified: meta.lastModified.flatMap { /* RFC3339 -> Date */ },
            versionId: meta.versionId,
            contentLength: meta.contentLength,
            metadata: meta.metadata
        )
    } catch let e as Ds3Error {
        // D-16: log original (code + body) BEFORE translation
        logger.error("S3 head failed: code=\(ds3ErrorCode(e), privacy: .public) \(String(describing: e), privacy: .public)")
        throw DS3S3Error.translate(e)
    }
}
```

**Helpers retained verbatim** (DS3S3Client.swift:351-416):
- `decodeS3Key(_:)` — pure-Swift logic, no Soto dep
- `readFilePart(at:offset:length:)` — pure-Foundation, no Soto dep
- `describeSotoError(_:)` — RENAME to `describeS3Error(_:)`, switch implementation to read `ds3ErrorCode(e)` on `Ds3Error`

**Error inspection statics** (DS3S3Client.swift:374-388) — replace with `DS3S3Error` static methods on the new enum. `s3ErrorCode(from:)`, `isNotFoundError(_:)`, `isRecoverableAuthError(_:)` move onto `DS3S3Error` as computed `var` properties (already drafted in research §"DS3S3Error design", lines 449-522).

---

### `DS3S3Client+Transfers.swift` rewrite (adapter extension, streaming + multipart)

**Analog:** self — current Soto streaming pattern (DS3S3Client+Transfers.swift:46-84).

**Soto streaming pattern to replace** (lines 46-84):
```swift
internal func streamToFile(request: S3.GetObjectRequest, fileURL: URL, ...) async throws -> S3.GetObjectOutput {
    let fileHandle = try FileHandle(forWritingTo: fileURL)
    defer { fileHandle.closeFile() }
    return try await s3.getObjectStreaming(request) { byteBuffer, eventLoop in
        // … write each chunk, report progress …
    }
}
```

**Rust-backed replacement** — Rust core does the streaming + temp-file write internally; Swift just receives the result + a progress callback:
```swift
func getObject(bucket: String, key: String, toFile fileURL: URL,
               onProgress: TransferProgressHandler? = nil) async throws -> S3DownloadResult {
    let callback = onProgress.map { ProgressCallbackBridge(handler: $0, direction: .download, filename: key.lastPathComponent) }
    do {
        let result = try handle.downloadObject(bucket: bucket, key: key,
                                                filePath: fileURL.path,
                                                progress: callback)
        return S3DownloadResult.fromFFI(result)
    } catch let e as Ds3Error {
        logger.error("download failed: \(String(describing: e), privacy: .public)")
        throw DS3S3Error.translate(e)
    }
}
```

`ProgressCallbackBridge` is a Swift class conforming to UniFFI's `ProgressCallback` protocol (Rust trait `ProgressCallback` exposed at `core/ds3-ffi/src/progress.rs:10-17`) that adapts `on_progress(bytesTransferred, totalBytes)` → existing `TransferProgress` struct + handler.

**Multipart pattern preserved** (`putObjectMultipart` lines 344-407) — orchestration STAYS in Swift because `PendingUploadStore` is Swift-only. Inner calls swap:
- `createMultipartUpload(...)` → `handle.multipartCreate(...)`
- `uploadPart(...)` → `handle.multipartUploadPart(...)` (verify accepts `Data` — RESEARCH FFI gap audit row)
- `completeMultipartUpload(...)` → `handle.multipartComplete(...)`
- `abortMultipartUpload(...)` → `handle.multipartAbort(...)`

The `withThrowingTaskGroup` concurrency loop (lines 435-471) is RETAINED — Swift owns concurrency for resume-state coordination with `PendingUploadStore`.

**FFI gaps to call** (added in this phase under `core/ds3-ffi/src/uniffi_exports.rs`):
- `getObjectData(bucket:key:)` → `handle.downloadToMemory(bucket:key:)` returning `Data`
- `putObjectData(bucket:key:data:metadata:)` → `handle.uploadFromMemory(bucket:key:data:metadata:)` returning `String?`

---

### `DS3S3Client+Presign.swift` rewrite (adapter extension, URL generation)

**Analog:** self (lines 12-62).

**Soto presign pattern to replace** (DS3S3Client+Presign.swift:43-61, 303-341 in +Transfers):
```swift
return try await s3.signURL(url: objectURL, httpMethod: .GET, expires: .seconds(Int64(expiresIn)))
```

**Rust-backed replacement:**
```swift
func presignedGetURL(bucket: String, key: String, expiresIn: Int) async throws -> URL {
    guard expiresIn > 0, expiresIn <= 604_800 else { throw PresignError.invalidPresignExpiry }
    do {
        let urlString = try handle.presignGet(bucket: bucket, key: key, expiresInSeconds: Int64(expiresIn))
        guard let url = URL(string: urlString) else { throw PresignError.invalidObjectURL }
        return url
    } catch let e as Ds3Error {
        throw DS3S3Error.translate(e)
    }
}
```

**Helpers retained verbatim:**
- `PresignError` enum (lines 5-10) — pure Swift, no Soto
- `buildObjectURL(endpoint:bucket:key:)` (lines 21-29) — pure Foundation

**FFI gap closed in this phase:** `presignUploadPart(bucket:key:uploadId:partNumber:expiresIn:)` — adds new `handle.presignUploadPart` UniFFI export. Returns a string URL; Swift wraps in `URLRequest` with `httpMethod = "PUT"` (logic from current lines 318-340 retained).

---

### `DS3S3Error.swift` NEW (error enum)

**Composite analogs:**
1. **Enum + LocalizedError shape:** `DS3AuthenticationError` (DS3Authentication.swift:6-54) and `DS3SDKError` (DS3SDK.swift:5-23). Both expose `errorDescription: String?` via `NSLocalizedString(...)`.
2. **AWS-code → NSFileProviderError switch:** `extension AWSErrorType` (FileProviderExtension+Errors.swift:49-93). Move its `.toFileProviderError()`, `.isNotFound`, `.isThrottling` onto cases of `DS3S3Error`.
3. **Numeric code → enum case dispatch:** mirror Rust `DS3Error::code()` (core/ds3-models/src/error.rs:97-117).

**LocalizedError + enum pattern to copy** (DS3AuthenticationError shape, DS3Authentication.swift:19-53):
```swift
public enum DS3S3Error: Error, LocalizedError, Sendable {
    case noSuchKey
    case noSuchBucket
    case accessDenied
    case invalidAccessKey
    case signatureDoesNotMatch
    case expiredToken
    case entityTooLarge
    case slowDown
    case serviceUnavailable
    case internalError
    case requestTimeout
    case missingUploadId
    case emptyFileData
    case missingETag
    case parseError
    case unableToOpenFile
    case thumbnailTooLarge(size: Int, limit: Int)
    case unknown(code: String?, message: String)

    public var errorDescription: String? {
        switch self {
        case .noSuchKey: NSLocalizedString("The specified key does not exist.", comment: "S3 NoSuchKey")
        // … etc, mirroring DS3AuthenticationError.errorDescription pattern …
        }
    }
}
```

**FileProvider mapping to migrate verbatim** — copy from `extension AWSErrorType.toFileProviderError()` (FileProviderExtension+Errors.swift:74-92), invert from `errorCode` string switch to enum case switch:
```swift
public extension DS3S3Error {
    func toFileProviderError() -> NSError {
        let code: NSFileProviderError.Code = switch self {
        case .invalidAccessKey, .signatureDoesNotMatch, .expiredToken: .notAuthenticated
        case .accessDenied: .cannotSynchronize
        case .noSuchKey, .noSuchBucket: .noSuchItem
        case .entityTooLarge: .insufficientQuota
        case .slowDown, .serviceUnavailable, .internalError, .requestTimeout: .serverUnreachable
        default: .cannotSynchronize
        }
        return NSFileProviderError(code) as NSError
    }

    var isNotFound: Bool { /* matches lines 50-52 */ }
    var isThrottling: Bool { /* matches lines 58-65 */ }
}
```

**Rust `Ds3Error` → `DS3S3Error` translator** — code dispatch on `ds3_error_code(e)` (the new FFI free fn). Pattern lifted from RESEARCH §"Error translation table", lines 526-562. The S3-string-error parsing (lines 547-561) is a deliberate fallback while the better path is exposing structured `S3ErrorCode` from Rust (researcher recommendation, line 565).

**Deviation:** drop the `Soto re-export typealiases` (current DS3S3Client.swift:11-12) entirely. Compile errors guide the migration — every `as AWSErrorType` site becomes `as DS3S3Error` (~60 sites enumerated in RESEARCH §"Soto/CryptoKit Removal Audit").

---

### `DS3Authentication.swift` internals swap (`@Observable`, request-response)

**Analog:** self (DS3Authentication.swift:104-563). KEEP everything observable; SWAP the I/O bodies only.

**`@Observable` shell to preserve verbatim** (lines 104-144):
```swift
@Observable
public final class DS3Authentication: @unchecked Sendable {
    private let logger = Logger(subsystem: LogSubsystem.app, category: LogCategory.auth.rawValue)
    public var urls: CubbitAPIURLs
    public var accountSession: AccountSession?
    public var account: Account?
    public var isLogged: Bool = false
    public var isNotLogged: Bool { !self.isLogged }
    private let sharedData: SharedData
    // … two inits …
}
```

**New private property:** `private(set) var handle: DS3SessionHandle?` (RESEARCH §"Pattern 2 + Pitfall 3", line 273-274).

**Internals to swap:**

| Existing method | Soto/URLSession body | Rust-backed replacement |
|-----------------|----------------------|-------------------------|
| `signChallenge(challenge:password:)` (lines 371-393) | CryptoKit `Curve25519.Signing.PrivateKey`, `SHA256` | DELETED — Rust does this inside `authenticate` |
| `getChallenge(email:tenant:)` (lines 331-364) | URLSession POST to `challengeURL` | DELETED — Rust does inside `authenticate` (free fn `get_challenge` available standalone if needed) |
| `getAccountSession(email:signedChallengeBase64:withTfaToken:tenant:)` (lines 401-451) | URLSession POST to `signinURL`, 2FA branch (lines 438-441) | DELETED — Rust does inside `authenticate` / `verify2fa` |
| `login(email:password:withTfaToken:tenant:)` (lines 268-289) | calls the three above | replaced — calls `DS3SessionHandle.authenticate` OR `verify2fa`; catches `Ds3Error` code 1007 → throws `DS3AuthenticationError.missing2FA` (D-15) |
| `refreshIfNeeded(force:)` (lines 230-258) | URLSession GET to `tokenRefreshURL`, `parseTokenResponse` | calls `handle?.refreshToken()` then refreshes Swift `accountSession` via new `handle.currentSession()` FFI fn |
| `forgeIAMToken(forIAMUser:)` (lines 152-186) | URLSession GET to `forgeAccessJWTURL` | calls `handle?.forgeIamToken(userId:)` and translates the returned `Token` struct |
| `accountInfo()` (lines 535-562) | URLSession GET to `accountsMeURL` | calls `handle?.accountInfo()` and translates to Swift `Account` |
| `parseTokenResponse(data:response:url:)` (lines 457-479) | cookie extraction | DELETED — cookie jar lives inside `DS3SessionHandle` |

**2FA path translation — load-bearing per D-15** (RESEARCH §"DS3Authentication adapter", lines 581-613):
```swift
do {
    let h: DS3SessionHandle
    if let code = tfaCode {
        h = try DS3SessionHandle.verify2fa(email: email, password: password, tfaCode: code,
                                            tenantId: tenant, coordinatorUrl: urls.coordinatorURL)
    } else {
        h = try DS3SessionHandle.authenticate(email: email, password: password,
                                               tenantId: tenant, coordinatorUrl: urls.coordinatorURL)
    }
    self.handle = h
    // … account + accountSession reconstruct …
} catch let e as Ds3Error where ds3ErrorCode(e) == 1007 {
    logger.info("2FA required — prompting user")
    throw DS3AuthenticationError.missing2FA  // exact existing case — LoginViewModel unchanged
} catch let e as Ds3Error {
    logger.error("login failed: code=\(ds3ErrorCode(e), privacy: .public) \(String(describing: e), privacy: .public)")
    throw DS3AuthenticationError.translate(e)
}
```

**Methods retained verbatim:**
- `shouldRefreshToken(_:threshold:)` (lines 194-196) — pure expiry math
- `startProactiveRefreshTimer()` (lines 201-224) — Task lifecycle
- `logout(driveManager:)` (lines 299-324) — Swift orchestration of UI + cleanup
- `persist()` (lines 483-492) — App Group JSON, MUST stay
- `loadFromPersistenceOrCreateNew(urls:)` (lines 496-511) — Codable
- `deleteFromDisk()` (lines 523-529) — UserDefaults + JSON delete

**CryptoKit removal:** `import CryptoKit` (line 1) deleted; `signChallenge`'s body deleted. The hash/sign happens inside `DS3SessionHandle.authenticate` (Rust `ds3-auth` via ring/ed25519-dalek).

**FFI gap to add:** `handle.currentSession() -> AccountSession` (RESEARCH §"DS3Authentication adapter" line 616, Assumption A7). Needed so `persist()` can write the post-login token + refresh cookie to `accountSession.json`.

---

### `DS3SDK.swift` internals swap (`@Observable`, request-response)

**Analog:** self (DS3SDK.swift:25-244). Same recipe as `DS3Authentication`: keep shell, swap internals.

**`@Observable` shell to preserve** (lines 27-42):
```swift
@Observable
public final class DS3SDK: @unchecked Sendable {
    private var authentication: DS3Authentication
    private let urls: CubbitAPIURLs
    private let sharedData: SharedData
    private let logger = Logger(subsystem: LogSubsystem.app, category: LogCategory.auth.rawValue)
    public init(withAuthentication: DS3Authentication, urls: CubbitAPIURLs? = nil, sharedData: SharedData = .default()) { /* ... */ }
}
```

**Methods to swap** — every one currently follows the same URLSession pattern (DS3SDK.swift:63-91 is the canonical example):
```swift
public func getRemoteProjects() async throws -> [Project] {
    try await self.authentication.refreshIfNeeded()
    guard let url = URL(string: self.urls.projectsURL) else { throw DS3AuthenticationError.invalidURL(url: self.urls.projectsURL) }
    guard let session = self.authentication.accountSession else { throw DS3AuthenticationError.loggedOut }
    var request = URLRequest(url: url)
    request.allHTTPHeaderFields = ["Content-Type": "application/json", "Authorization": "Bearer \(session.token.token)"]
    let (responseData, response) = try await URLSession.shared.data(for: request)
    try validateResponse(response, data: responseData, expectedStatus: [200], error: DS3AuthenticationError.serverError)
    guard let projects = try? JSONDecoder().decode([Project].self, from: responseData)
    else { throw DS3AuthenticationError.jsonConversion }
    return projects
}
```

**Becomes** (per RESEARCH §"Auth/SDK Swap Sub-Ordering"):
```swift
public func getRemoteProjects() async throws -> [Project] {
    guard let handle = self.authentication.handle else { throw DS3AuthenticationError.loggedOut }
    do {
        let rustProjects = try handle.getProjects()  // FFI; calls refresh internally
        return rustProjects.map { Project.fromFFI($0) }
    } catch let e as Ds3Error {
        logger.error("getRemoteProjects failed: \(String(describing: e), privacy: .public)")
        throw DS3SDKError.translate(e)
    }
}
```

**Methods mapped to FFI calls** (one-to-one, see RESEARCH §"FFI Surface Audit" lines 661-693):
| Swift method | FFI replacement |
|--------------|-----------------|
| `getRemoteProjects()` | `handle.getProjects()` |
| `getRemoteApiKeys(forIAMUser:)` | `handle.loadApiKeys(userId:, iamToken:)` |
| `deleteApiKey(_:forIAMUser:)` | `handle.deleteApiKey(userId:, apiKeyId:, iamToken:)` |
| `generateDS3APIKey(forIAMUser:iamToken:apiKeyName:)` | `handle.createApiKey(userId:, keyName:, iamToken:)` |

**Methods retained verbatim:**
- `loadOrCreateDS3APIKeys(forIAMUser:ds3ProjectName:)` (lines 160-192) — reconciliation logic stays Swift, just calls the swapped methods above
- `apiKeyName(forUser:projectName:)` (lines 238-243) — pure string construction
- `validateResponse(...)` (lines 45-57) — DELETED, FFI returns typed errors

**DS3SDKError extension:** add `static func translate(_ rust: Ds3Error) -> DS3SDKError` mirroring the pattern drafted in `DS3S3Error.translate`. Per-adapter ownership of translation (D-13).

---

### `SyncAnchorHash.swift` CryptoKit removal

**Analog:** self (current CryptoKit body, SyncAnchorHash.swift:28-36 and 68-79).

**Imports to change:**
```swift
// Before
import CryptoKit
// After
import CommonCrypto
```

**Pattern to copy** (RESEARCH §"Soto/CryptoKit Removal Audit" lines 766-773):
```swift
func sha256(_ data: Data) -> Data {
    var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
    data.withUnsafeBytes { _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &hash) }
    return Data(hash)
}
```

**Existing call sites to update** (lines 33 and 76):
```swift
// Before
let digest = SHA256.hash(data: Data(joined.utf8))
let hex = digest.map { String(format: "%02x", $0) }.joined()
// After
let digest = sha256(Data(joined.utf8))
let hex = digest.map { String(format: "%02x", $0) }.joined()
```

**Deviation:** the algorithm output is byte-identical (Assumption A6: both wrap Apple CoreCrypto's FIPS 180-4 SHA-256). Existing `NSFileProviderSyncAnchor` values produced before the swap MUST continue to compare equal to post-swap values for the same input — otherwise the system triggers a full re-enumeration on first launch after upgrade. The `v1:` format prefix (line 24) is unchanged.

---

### `Package.swift` (SPM manifest)

**Analog:** self (apple/DS3Lib/Package.swift, all 35 lines).

**Current pattern** (lines 10-32):
```swift
dependencies: [
    .package(url: "https://github.com/soto-project/soto", from: "6.8.0"),
    .package(url: "https://github.com/apple/swift-atomics.git", from: "1.2.0"),
    .package(url: "https://github.com/apple/swift-nio.git", from: "2.62.0")
],
targets: [
    .target(
        name: "DS3Lib",
        dependencies: [
            .product(name: "SotoS3", package: "soto"),
            .product(name: "Atomics", package: "swift-atomics")
        ],
        swiftSettings: [.swiftLanguageMode(.v6)]
    ),
    .testTarget(
        name: "DS3LibTests",
        dependencies: ["DS3Lib", .product(name: "NIOCore", package: "swift-nio")]
    )
]
```

**Post-swap target** (per D-07 + research §"Package Legitimacy Audit"):
```swift
dependencies: [
    .package(url: "https://github.com/apple/swift-atomics.git", from: "1.2.0")
    // soto removed (D-14, end-of-phase)
    // swift-nio audit: remove if no DS3LibTests files import NIOCore
],
targets: [
    .binaryTarget(
        name: "DS3CoreFFI",
        path: "../../core/out/DS3CoreFFI.xcframework"
    ),
    .target(
        name: "DS3Lib",
        dependencies: [
            "DS3CoreFFI",
            .product(name: "Atomics", package: "swift-atomics")
        ],
        swiftSettings: [.swiftLanguageMode(.v6)]
    ),
    .testTarget(
        name: "DS3LibTests",
        dependencies: ["DS3Lib"]
    )
]
```

**Path verification** (Assumption A8): `apple/DS3Lib/Package.swift` → `..` (apple/) → `..` (repo root) → `core/out/DS3CoreFFI.xcframework`. The artifact already exists at this exact path (Phase 15 output).

---

### Xcode Run Script Phase (NEW — no in-repo analog)

**Analog:** there is **no existing Run Script Phase** in `apple/DS3Drive.xcodeproj/project.pbxproj` (grep returned 0 hits). Pattern is from RESEARCH §"Pattern 3: Xcode Run Script Phase" (lines 301-336) and §"Code Examples — Run Script Phase body" (lines 618-640), built on top of `core/scripts/build-xcframework.sh`'s existing `--debug`/`--release` interface (build-xcframework.sh:32-38).

**Position:** BEFORE "Compile Sources" on three targets — DS3Drive (macOS app), DS3DriveApp (iOS app), DS3DriveProvider (extension). Anywhere DS3CoreFFI is linked, the script must run.

**Script body to paste verbatim into each target's Run Script Phase:**
```bash
#!/bin/bash
set -euo pipefail

# Make Homebrew/Cargo-bin visible to Xcode's stripped PATH (Pitfall 4).
export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

# Map Xcode $CONFIGURATION → cargo profile (D-10).
PROFILE_FLAG="--debug"
if [ "$CONFIGURATION" = "Release" ]; then
    PROFILE_FLAG="--release"
fi

# Always invoke (D-09); cargo handles incremental compile.
exec "${SRCROOT}/../core/scripts/build-xcframework.sh" $PROFILE_FLAG
```

**Configuration table** (RESEARCH lines 318-326):
| Setting | Value |
|---------|-------|
| Shell | `/bin/bash` |
| Show env vars in build log | yes (for debugging) |
| Run only when installing | NO (must run every build) |
| For install builds also | YES |
| Input Files | `$(SRCROOT)/../core/scripts/build-xcframework.sh` |
| Output Files | `$(SRCROOT)/../core/out/DS3CoreFFI.xcframework/Info.plist` |
| Input File Lists | (none — see RESEARCH line 327 anti-pattern) |

**Verification target SRCROOT mapping:**
- `apple/DS3Drive` target → `$SRCROOT = apple/DS3Drive` → `../core/scripts/...` resolves correctly
- DS3DriveApp/Provider targets — verify SRCROOT path during Plan A wiring

---

### FileProvider extension catch-block migration

**Analog:** self — `apple/DS3DriveProvider/FileProviderExtension+Errors.swift`, plus the 5 source files with 30+ `catch let s3Error as AWSErrorType` sites.

**Mapping**: replace AWSErrorType identifier on every catch site. Confirmed sites (grep output above):
- `FileProviderExtension.swift:332` (1 site)
- `FileProviderExtension+Create.swift` lines 130, 175, 196, 258, 402 (5 sites; line 258 is `catch is S3ErrorType`)
- `FileProviderExtension+Modify.swift` lines 127, 134, 207, 268, 345, 416, 535 (7 sites)
- `FileProviderExtension+Delete.swift` (9 sites — research §"Soto/CryptoKit Removal Audit")
- Test files: 13 files total (research line 795)

**Before** (representative example from FileProviderExtension+Create.swift:175-180):
```swift
} catch let s3Error as AWSErrorType {
    throw s3Error.toFileProviderError()
}
```

**After:**
```swift
} catch let s3Error as DS3S3Error {
    throw s3Error.toFileProviderError()
}
```

**Note `catch is S3ErrorType`** (FileProviderExtension+Create.swift:258) — this is a *type-only* catch with no binding. Becomes `catch is DS3S3Error`.

**FileProviderExtension+Errors.swift extension migration** (lines 49-93):
- Delete `extension AWSErrorType { ... }`
- Add equivalent computed properties (`isNotFound`, `isThrottling`) and `.toFileProviderError()` to `DS3S3Error` (already specified in `DS3S3Error.swift` pattern above)

**Critical constraint (per project memory + D-21):** the `.toFileProviderError()` switch table MUST produce byte-identical `NSError` domain + code for the same logical S3 error pre- and post-swap. The 9 mapped error codes (`InvalidAccessKeyId`, `SignatureDoesNotMatch`, `ExpiredToken`, `AccessDenied`, `NoSuchKey`, `NoSuchBucket`, `NotFound`, `EntityTooLarge`, `SlowDown`, `ServiceUnavailable`, `InternalError`, `RequestTimeout`) map to the same `NSFileProviderError.Code` values listed in FileProviderExtension+Errors.swift:74-92.

---

### `core/ds3-ffi/src/uniffi_exports.rs` extensions

**Analog:** self (core/ds3-ffi/src/uniffi_exports.rs:194-305 — the S3 functions section).

**Existing pattern to copy** for every new method — uniffi_exports.rs:229-232 (head_object) is the minimal example:
```rust
pub fn head_object(&self, bucket: String, key: String) -> Result<S3ObjectMetadata, DS3Error> {
    let client = self.require_s3()?;
    runtime().block_on(client.head_object(&bucket, &key))
}
```

**Seven new methods to add** (research §"FFI Surface Audit" totals, lines 685-695):

1. **`download_to_memory`** — pattern: copy head_object, swap to `client.download_to_memory(&bucket, &key)` returning `Result<Vec<u8>, DS3Error>`. New impl lives in `core/ds3-s3/src/crud.rs` using `aws_sdk_s3::primitives::ByteStream::collect()`.

2. **`upload_from_memory`** — pattern: copy upload_object (lines 252-264), but accept `data: Vec<u8>` and `metadata: HashMap<String, String>` instead of `file_path`. Body wraps data in `ByteStream::from(buf)` (the same pattern used at multipart.rs:160).

3. **`presign_upload_part`** — pattern: mirror existing `presign_get` (not shown but exists in repo — research §FFI Surface Audit line 678). Signature: `fn presign_upload_part(&self, bucket, key, upload_id, part_number: i32, expires_in: i64) -> Result<String, DS3Error>`. Uses `aws_sdk_s3::presigning::PresigningConfig`.

4. **`current_session`** — pattern: mirror existing `account_info` (lines 103-105):
   ```rust
   pub fn account_info(&self) -> Result<Account, DS3Error> {
       Ok(self.session.account.clone())
   }
   ```
   New: `pub fn current_session(&self) -> Result<AccountSession, DS3Error>` — reads from the session's mutex-guarded token + refresh cookie. Requires `AccountSession` model record to be added/exposed via `ds3_models` (verify in `core/ds3-models/src/auth.rs`).

5. **Extend `copy_object`** to accept optional metadata — current signature (lines 280-288):
   ```rust
   pub fn copy_object(&self, bucket: String, source_key: String, dest_key: String) -> Result<(), DS3Error>
   ```
   Becomes:
   ```rust
   pub fn copy_object(&self, bucket: String, source_key: String, dest_key: String,
                      metadata: Option<HashMap<String, String>>) -> Result<(), DS3Error>
   ```
   With `metadata_directive("REPLACE")` set in `core/ds3-s3/src/crud.rs` when `metadata.is_some()`. Mirrors current Swift logic (DS3S3Client.swift:336-340).

6. **`CancellationHandle`** UniFFI Object (D-20) — pattern: copy `DS3SessionHandle` struct decl (uniffi_exports.rs:36-40):
   ```rust
   #[derive(uniffi::Object)]
   pub struct DS3SessionHandle {
       session: Arc<DS3Session>,
       s3_client: std::sync::RwLock<Option<DS3S3Client>>,
   }
   ```
   New: `core/ds3-ffi/src/cancellation.rs`:
   ```rust
   #[derive(uniffi::Object)]
   pub struct CancellationHandle {
       cancelled: Arc<AtomicBool>,
   }

   #[uniffi::export]
   impl CancellationHandle {
       #[uniffi::constructor]
       pub fn new() -> Arc<Self> { Arc::new(Self { cancelled: Arc::new(AtomicBool::new(false)) }) }
       pub fn cancel(&self) { self.cancelled.store(true, Ordering::Relaxed); }
       pub fn is_cancelled(&self) -> bool { self.cancelled.load(Ordering::Relaxed) }
   }
   ```
   Thread the handle into `multipart_create`/`upload_object`/`download_object` as `Option<Arc<CancellationHandle>>` parameter. Inside the multipart loop (core/ds3-s3/src/multipart.rs:189-195, after each part completes), check `if token.is_cancelled() { return Err(DS3Error::S3Error("cancelled".into())); }`.

7. **Free function `ds3_error_code`** — pattern: copy existing free fn `conflict_key` (uniffi_exports.rs:356-364):
   ```rust
   #[uniffi::export]
   pub fn conflict_key(original_key: String, hostname: String, nonce: Option<String>) -> String { /* ... */ }
   ```
   New:
   ```rust
   #[uniffi::export]
   pub fn ds3_error_code(err: &DS3Error) -> i32 { err.code() }
   ```
   The `code()` method already exists at `core/ds3-models/src/error.rs:97-117`. **Caveat (Pitfall 1):** UniFFI's `#[uniffi(flat_error)]` may forbid borrowing `&DS3Error` from Swift. Fallback per RESEARCH: take `err: String` (the error's Display) and parse a numeric prefix — but the cleaner solution is to remove `#[uniffi(flat_error)]` and let UniFFI generate a full enum mirror. Decide during Plan A (Assumption A1).

---

### `core/ds3-s3/src/multipart.rs` cancellation thread-through

**Analog:** self (multipart.rs:130-198 — the `upload_parts` inner loop).

**Existing chunked stream pattern** (lines 143-187):
```rust
let mut stream = stream::iter(parts.iter().cloned())
    .map(|part| { /* per-part async block */ })
    .buffer_unordered(MULTIPART_CONCURRENCY);

while let Some(result) = stream.next().await {
    completed.push(result?);
    if let Some(cb) = on_progress {
        cb(uploaded_bytes.load(Ordering::Relaxed), total);
    }
}
```

**Pattern to add** (D-20):
```rust
while let Some(result) = stream.next().await {
    if let Some(token) = &cancel_token {
        if token.is_cancelled() {
            // Drop the stream — pending parts cancel; we'll abort the upload outside.
            return Err(DS3Error::S3Error("cancelled by caller".into()));
        }
    }
    completed.push(result?);
    if let Some(cb) = on_progress {
        cb(uploaded_bytes.load(Ordering::Relaxed), total);
    }
}
```

The outer `upload_multipart` already aborts on `Err` (multipart.rs:122-125) — cancellation propagates naturally through the existing abort path.

---

### `core/ds3-http/src/client.rs` retry policy

**Analog:** self (ds3-http/src/client.rs:21-35 — the `SharedHttpClient::new` builder).

**Existing pattern** (lines 28-34):
```rust
let client = reqwest::ClientBuilder::new()
    .cookie_store(true)
    .default_headers(headers)
    .build()
    .map_err(|e| DS3Error::HttpError(e.to_string()))?;
```

**Decision point (Assumption A2 + A3, RESEARCH §"Assumptions Log"):**
- aws-sdk-s3 v1 already has built-in retry via `behavior_version_latest()` (verified at core/ds3-s3/src/client.rs:59). S3 ops are covered.
- reqwest 0.13 has NO built-in retry. Auth, projects, keys, forge requests are NOT retried today.

**Pattern to add** (if Plan A verification shows reqwest needs retry — per D-18):
```rust
use reqwest_retry::{policies::ExponentialBackoff, RetryTransientMiddleware};
use reqwest_middleware::ClientBuilder as MiddlewareClientBuilder;

let inner = reqwest::ClientBuilder::new()
    .cookie_store(true)
    .default_headers(headers)
    .build()?;
let retry_policy = ExponentialBackoff::builder().build_with_max_retries(5);
let client = MiddlewareClientBuilder::new(inner)
    .with(RetryTransientMiddleware::new_with_policy(retry_policy))
    .build();
```

`SharedHttpClient` struct field changes from `reqwest::Client` to `reqwest_middleware::ClientWithMiddleware`. All call sites use the same `.get`/`.post`/`.delete` API.

**Deviation:** `reqwest-retry` requires adding two new crates to `core/Cargo.toml` workspace dependencies. Confirm with Phase 16 scope budget before adding.

---

### `core/ds3-models/tests/serde_tests.rs` fixture parity gate

**Analog:** self (core/ds3-models/tests/serde_tests.rs:232-270 — `test_ds3_drive_round_trip`).

**Current pattern** (inline json!()):
```rust
#[test]
fn test_ds3_drive_round_trip() {
    let json_data = json!({ /* literal */ });
    let drive: DS3Drive = serde_json::from_value(json_data).unwrap();
    assert_eq!(drive.id.to_string(), "550e8400-e29b-41d4-a716-446655440000");
    /* ... */
}
```

**Pattern to add** (RESEARCH §"CI Parity Gate Design" lines 841-852):
```rust
#[test]
fn test_drives_fixture_round_trip() {
    let bytes = include_bytes!("fixtures/drives_v4.json");
    let drives: Vec<DS3Drive> = serde_json::from_slice(bytes).unwrap();
    assert!(!drives.is_empty(), "fixture should have ≥1 drive");
    assert_eq!(drives[0].sync_anchor.bucket.name, "test-bucket-1");
    // Round-trip: serialize back, parse again, compare struct
    let reserialized = serde_json::to_vec(&drives).unwrap();
    let drives_round: Vec<DS3Drive> = serde_json::from_slice(&reserialized).unwrap();
    assert_eq!(drives, drives_round);
}
```

**Fixtures to create:**
- `core/ds3-models/tests/fixtures/drives_v4.json` (Vec<DS3Drive>)
- `core/ds3-models/tests/fixtures/credentials_v1.json` (Vec<DS3ApiKey>)
- `core/ds3-models/tests/fixtures/accountSession_v1.json` (AccountSession)
- `core/ds3-models/tests/fixtures/account_v1.json` (Account)

**Swift counterpart** (new file `apple/DS3Lib/Tests/DS3LibTests/SchemaParityTests.swift`) — pattern from `DescribeSotoErrorTests.swift` shape; uses XCTest's `Bundle.module.url(forResource: ...)` to load the SAME fixture bytes from `../../core/ds3-models/tests/fixtures/` (test bundle resource path declared in Package.swift). Asserts the Swift `Codable` decode produces equivalent field values to the Rust serde decode (verified against same expected constants).

---

### `.github/workflows/build.yml` CI integration

**Analog:** self (.github/workflows/build.yml — `rust-check` job at line 22, `xcodebuild build analyze` at line 77).

**Existing rust-check pattern** (line 50):
```yaml
- name: Run tests
  run: cargo test --workspace --lib
```

**Pattern to extend** (D-25 + RESEARCH §"CI Parity Gate Design"):
```yaml
- name: Run tests (incl. parity fixtures)
  run: cargo test --workspace --lib --tests
```

**Existing macOS xcodebuild pattern** (lines 74-78):
```yaml
- name: Resolve dependencies
  run: |
    xcodebuild -resolvePackageDependencies -project apple/DS3Drive.xcodeproj -scheme DS3Drive
- name: Build & analyze
  run: |
    xcodebuild clean build analyze \
      -project apple/DS3Drive.xcodeproj \
      ...
```

**Pattern to extend** (RESEARCH §Pitfall 9 — XCFramework path drift):
```yaml
- name: Build DS3CoreFFI XCFramework
  working-directory: core
  run: ./scripts/build-xcframework.sh --release
- name: Verify XCFramework exists
  run: ls -la core/out/DS3CoreFFI.xcframework
- name: Resolve dependencies
  run: xcodebuild -resolvePackageDependencies ...
```

This step must be added BEFORE the existing `xcodebuild` step in both the macOS (line 77) and iOS (line 160) jobs. Required Rust targets must be installed first (`rustup target add aarch64-apple-darwin aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios` — research §"Environment Availability").

**Integration test scheduling** (Claude's Discretion per RESEARCH §"Integration Test CI Schedule"): every PR during Phase 16 development; downgrade to nightly after merge to main.

---

## Shared Patterns

### Pattern 1: Logger Boundary Convention

**Source:** `DS3Authentication.swift:106`, `DS3SDK.swift:32`, `DS3S3Client.swift:178`.

**Pattern:**
```swift
private let logger = Logger(subsystem: LogSubsystem.app, category: LogCategory.auth.rawValue)
// or
let logger = os.Logger(subsystem: LogSubsystem.provider, category: LogCategory.transfer.rawValue)
```

**Apply to all three adapters.** Subsystem stays `LogSubsystem.app` (main app, `io.cubbit.DS3Drive`) for `DS3Authentication`/`DS3SDK`; stays `LogSubsystem.provider` (`io.cubbit.DS3Drive.provider`) for `DS3S3Client`. Categories unchanged: `auth`, `transfer`. Project memory note: `--info --debug` flags are needed to surface these in `log show`.

### Pattern 2: Privacy Annotations on Dynamic Strings

**Source:** `DS3Authentication.swift:309, 322, 351, 354, 432, 435, 559` and CLAUDE.md "OSLog with `privacy: .public`" rule.

**Pattern:**
```swift
self.logger.error("...failed: \(error.localizedDescription, privacy: .public)")
self.logger.error("Sign-in response body: \(body, privacy: .private)")
```

**Apply to all FFI-boundary log lines (D-16):**
- `code` (integer from `ds3ErrorCode`) → `privacy: .public` (needed for triage)
- `String(describing: rust_error)` → `privacy: .public` (loses payload otherwise; Rust never includes secrets in Display per `core/ds3-models/src/error.rs:8`)
- token/cookie strings → `privacy: .private`

### Pattern 3: Per-Adapter Error Translation (D-13)

**Source:** RESEARCH §"Pattern 1: Adapter Owns Translation" + the three current error enum declarations (DS3AuthenticationError, DS3SDKError, DS3ClientError).

**Pattern to apply to all three adapter classes** — each defines its own `static func translate(_:DS3Error) -> Self`:
```swift
extension DS3S3Error {
    static func translate(_ rust: Ds3Error) -> DS3S3Error { /* code-based switch */ }
}
extension DS3AuthenticationError {
    static func translate(_ rust: Ds3Error) -> DS3AuthenticationError { /* code-based switch */ }
}
extension DS3SDKError {
    static func translate(_ rust: Ds3Error) -> DS3SDKError { /* code-based switch */ }
}
```

Adapter call sites uniformly:
```swift
do {
    return try handle.someMethod(...)
} catch let e as Ds3Error {
    logger.error("...: code=\(ds3ErrorCode(e), privacy: .public) \(String(describing: e), privacy: .public)")
    throw <PerAdapterErrorEnum>.translate(e)
}
```

### Pattern 4: Existing 2FA UI Contract (D-15, load-bearing)

**Source:** `DS3Authentication.swift:438-441` + `LoginViewModel` (referenced in research line 62) — the path that ends in `throw DS3AuthenticationError.missing2FA`.

**The translation rule that MUST exist** in `DS3AuthenticationError.translate(_:)`:
```swift
static func translate(_ rust: Ds3Error) -> DS3AuthenticationError {
    let code = ds3ErrorCode(rust)
    switch code {
    case 1005: return .loggedOut
    case 1006: return .tokenExpired
    case 1007: return .missing2FA   // <-- load-bearing: keeps LoginViewModel 2FA prompt working
    case 1008: return .cookies
    case 1002: return .serverError
    case 1003: return .jsonConversion
    case 1004: return .encoding
    case 1001: return .invalidURL()
    default: return .serverError
    }
}
```

Existing `DS3AuthenticationTests.swift` and `LoginFlowTests.swift` cover this path — they MUST stay green.

### Pattern 5: App Group Persistence Boundary (D-04, D-06)

**Source:** `DS3Authentication.persist()` (lines 483-492), `DS3Authentication.deleteFromDisk()` (lines 523-529), `SharedData` (apple/DS3Lib/Sources/DS3Lib/SharedData/*).

**Rule:** Rust NEVER touches App Group container. After every successful `handle.*` mutation that changes session state (login, refresh, forge), the Swift adapter MUST:
1. Pull updated `AccountSession` via `handle.currentSession()` (NEW FFI fn)
2. Update Swift `@Observable` properties
3. Call `try self.persist()` to write to App Group JSON

**Apply to:** `login`, `refreshIfNeeded`, `forgeIAMToken` in DS3Authentication; `generateDS3APIKey` in DS3SDK.

### Pattern 6: Sendable + UniFFI Object Storage (Pitfall 5)

**Source:** `DS3Authentication.swift:105` (`@unchecked Sendable` pattern), `DS3SDK.swift:28`, `DS3S3Client.swift:176` (`Sendable`).

**Rule:** UniFFI 0.27+ generates `Sendable` on `#[uniffi::Object]` types. Verify by reading `core/out/DS3CoreFFI.swift` for `DS3SessionHandle: Sendable`. If absent, add:
```swift
extension DS3SessionHandle: @unchecked Sendable {}  // safe — Rust uses Arc<DS3Session>
```

Apply this extension in DS3Lib if needed; place near the adapter's logger declaration so it's discoverable.

---

## No Analog Found

| File | Role | Data Flow | Reason | Substitute Pattern |
|------|------|-----------|--------|--------------------|
| Xcode Run Script Phase in `DS3Drive.xcodeproj/project.pbxproj` | build config | — | No existing Run Script Phase exists in this project (grep returned 0 matches for `Run Script`, `shellScript`, `cargo`, `swiftlint`). | Use canonical Mozilla UniFFI pattern documented in RESEARCH §"Pattern 3: Xcode Run Script Phase" (lines 301-336) and §"Code Examples — Run Script Phase body" (lines 618-640). Output Files declaration is the production-tested pattern (Mozilla AS / Glean). |
| `core/ds3-ffi/src/cancellation.rs` | new UniFFI Object | event-driven | No existing `Cancel`-like UniFFI Object in the codebase. | Use existing `DS3SessionHandle` struct decl as the `#[derive(uniffi::Object)]` template (uniffi_exports.rs:36-40); body pattern from research §"Cancellation" (lines 147, D-20). |
| reqwest retry middleware (if added) | new dependency | — | `core/ds3-http` does not currently use any retry crate. | Use canonical `reqwest-retry` + `reqwest-middleware` pattern from research §"DS3 Hand-Roll" table (line 343). Two new workspace dependencies. |

These three items are the only places where research-only patterns (no in-repo analog) are needed. All other files have direct, file-local analogs.

---

## Metadata

**Analog search scope:**
- `/Users/marmos91/Projects/cubbit-ds3-drive/apple/DS3Lib/Sources/DS3Lib/` — all 22 root-level Swift files
- `/Users/marmos91/Projects/cubbit-ds3-drive/apple/DS3DriveProvider/` — 21 Swift files (catch sites + error mapping)
- `/Users/marmos91/Projects/cubbit-ds3-drive/core/ds3-ffi/src/` — all 6 files
- `/Users/marmos91/Projects/cubbit-ds3-drive/core/ds3-models/src/` — 9 files (error.rs + tests)
- `/Users/marmos91/Projects/cubbit-ds3-drive/core/ds3-s3/src/` — 7 files (client.rs, multipart.rs, crud.rs)
- `/Users/marmos91/Projects/cubbit-ds3-drive/core/ds3-http/src/` — 5 files
- `/Users/marmos91/Projects/cubbit-ds3-drive/core/scripts/build-xcframework.sh`
- `/Users/marmos91/Projects/cubbit-ds3-drive/.github/workflows/build.yml`
- `/Users/marmos91/Projects/cubbit-ds3-drive/apple/DS3Drive.xcodeproj/project.pbxproj` (grep for Run Script — 0 matches)

**Files read in full:** DS3S3Client.swift, DS3S3ClientProtocol.swift, DS3S3Client+Transfers.swift, DS3S3Client+Presign.swift, DS3S3Client+Thumbnails.swift, DS3S3Client+ThumbnailPrefix.swift, DS3S3Client+Protocol.swift, DS3Authentication.swift, DS3SDK.swift, Package.swift, FileProviderExtension+Errors.swift, SyncAnchorHash.swift, uniffi_exports.rs, error.rs, serde_tests.rs, client.rs (both s3 + http), progress.rs, handles.rs, panic_guard.rs, build-xcframework.sh. multipart.rs read in two non-overlapping segments (1-80, 80-200).

**Pattern extraction date:** 2026-05-28
