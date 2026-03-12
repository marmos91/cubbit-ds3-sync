# Technology Stack

**Project:** DS3 Drive (macOS cloud file sync with S3 backend)
**Researched:** 2026-03-11
**Confidence:** HIGH

## Executive Summary

DS3 Drive requires a **modern Swift-first stack** optimized for File Provider extensions, async S3 operations, and reliable local state management. The recommended stack keeps Soto v6 (not v7) for stability, adopts SwiftData for local metadata, and leverages native macOS frameworks for logging and UI.

**Key decision:** Stay on Soto v6 to avoid Swift 6 migration complexity while the project stabilizes core sync logic. Upgrade to v7 in a future phase when Swift 6 is validated.

---

## Recommended Stack

### Core Language & Runtime

| Technology | Version | Purpose | Why |
|------------|---------|---------|-----|
| **Swift** | 5.10+ | Primary language | Native macOS development, type safety, modern concurrency (async/await), required for SwiftUI/File Provider |
| **macOS SDK** | 14.0+ (Sonoma) | Target platform | SwiftData requires macOS 14+, File Provider improvements in recent releases |
| **Xcode** | 15.3+ | IDE & build toolchain | Latest stable Xcode supporting Swift 5.10 and macOS 14 SDK |

**Rationale:** Swift 5.10 provides stable async/await without Swift 6's strict concurrency checks. SwiftData requires macOS 14 minimum. Soto v6 is compatible with Swift 5.x.

**Confidence:** HIGH (official Apple requirements)

---

### S3 Client Library

| Technology | Version | Purpose | Why |
|------------|---------|---------|-----|
| **Soto (SotoS3)** | v6.13.0+ (NOT v7) | S3 operations | Mature, proven, async/await support without Swift 6 migration complexity |

**Why Soto v6 instead of v7:**
- **v7 requires Swift 6.0+** (breaking change announced in v7.10.0) and removes all EventLoopFuture APIs
- **v6 supports async/await** (added in v6.5.0) while maintaining compatibility with Swift 5.x
- **Project currently on v6.8.0** — upgrading to latest v6.x (v6.13.0+) is low-risk incremental improvement
- **Swift 6 migration is premature** — project needs to stabilize sync engine first, then upgrade language version

**Migration path:** Soto v6.8.0 → v6.13.0 (current) → v7.x (future phase after Swift 6 validation)

**Why NOT aws-sdk-swift:** Amazon's official SDK is still maturing and lacks Soto's track record on Apple platforms. Soto has 8 years of development, 100 releases, and proven S3-compatible endpoint support.

**Confidence:** HIGH (official releases verified, current project already using Soto v6)

**Sources:**
- [Soto v7.0.0 release notes](https://soto.codes/2024/07/v7-release.html) (confirms Swift 6 requirement and EventLoopFuture removal)
- [Soto GitHub releases](https://github.com/soto-project/soto/releases) (latest v7.13.0 available, v6.13.0 last v6 release)

---

### Local Metadata Database

| Technology | Version | Purpose | Why |
|------------|---------|---------|-----|
| **SwiftData** | Built-in (macOS 14+) | Metadata tracking (ETag, LastModified, sync state, conflict detection) | Native, modern Swift API, SQLite-backed, cross-platform ready (iOS/iPadOS) |

**What to store:**
- File metadata: `itemIdentifier`, `filename`, `etag`, `lastModified`, `localHash`, `versionIdentifier`
- Sync state: `syncStatus` (pending/synced/conflict/error), `lastSyncedAt`, `errorMessage`
- Conflict tracking: `conflictVersion`, `conflictDetectedAt`

**Why SwiftData over Core Data:**
- **Modern Swift-first API** — @Model macro, property wrappers, no NSManagedObject subclassing
- **Cross-platform** — same code works on iOS/iPadOS when project expands
- **Less boilerplate** — schema definition via Swift types, automatic migration (with `Schema` versioning)
- **Production-ready** — shipped in macOS 14 (2023), refined in macOS 15 (2024-2025), stable for CRUD and querying

**Why SwiftData over custom SQLite:**
- Relationship management and indexing built-in
- iCloud sync support (future feature)
- Apple's recommended path forward

**Limitations to be aware of:**
- Advanced Core Data features not yet available (custom migration policies, complex predicates)
- Smaller community/ecosystem than Core Data (fewer StackOverflow answers)

**Migration from current state:** Project has no local DB currently, so this is net-new. No migration complexity.

**Confidence:** MEDIUM (SwiftData is production-ready but less mature than Core Data; for metadata tracking use case, it's sufficient)

**Sources:**
- [SwiftData documentation](https://developer.apple.com/documentation/swiftdata) (macOS 14+ requirement confirmed)
- [What's new in SwiftData (WWDC24)](https://developer.apple.com/videos/play/wwdc2024/10137/) (indexing, schema versioning improvements)

---

### File System Integration

| Technology | Version | Purpose | Why |
|------------|---------|---------|-----|
| **FileProvider** | Built-in (macOS 11+) | Finder integration, on-demand sync | Apple's standard for cloud storage providers |
| **NSFileProviderReplicatedExtension** | Built-in (macOS 11+) | Two-way sync protocol | Modern File Provider API, replaces older enumeration-based approach |

**Key implementation patterns:**

1. **Version tracking via `versionIdentifier`:**
   - Store S3 ETag in `NSFileProviderItem.versionIdentifier`
   - Compare versions in `modifyItem()` to detect conflicts
   - Create conflict copies when remote version ≠ local version

2. **Conflict resolution strategy:**
   - Before upload: compare ETag from SwiftData with current S3 ETag
   - If mismatch: rename to "filename (Conflict copy YYYY-MM-DD).ext"
   - Signal change enumeration via `NSFileProviderManager.signalEnumerator()`

3. **Error handling:**
   - Return correct `NSFileProviderError` codes (system uses these for retry logic)
   - Example: `.serverUnreachable` triggers automatic retry, `.noSuchItem` does not

4. **Async/await integration:**
   - File Provider uses completion handlers (not async/await)
   - Wrap async S3 calls in `Task { }` and call completion handler when done

**Confidence:** HIGH (official Apple framework, well-documented)

**Sources:**
- [Build your own cloud sync using FileProvider](https://claudiocambra.com/posts/build-file-provider-sync/) (comprehensive implementation guide)
- [NSFileProviderReplicatedExtension documentation](https://developer.apple.com/documentation/fileprovider/nsfileproviderreplicatedextension) (official API reference)

---

### UI Framework

| Technology | Version | Purpose | Why |
|------------|---------|---------|-----|
| **SwiftUI** | Built-in (macOS 14+) | Main app UI (setup wizard, preferences) | Modern, declarative, cross-platform ready |
| **AppKit** | Built-in | Menu bar tray integration (`NSStatusBar`) | SwiftUI doesn't support menu bar apps natively |

**Hybrid approach:**
- **SwiftUI** for windows (drive setup, preferences, conflict resolution dialogs)
- **AppKit** for menu bar tray (NSStatusItem + SwiftUI views via `NSHostingView`)

**Why not pure AppKit:** SwiftUI reduces boilerplate for forms, lists, settings screens. AppKit needed only for system menu bar integration.

**Confidence:** HIGH (current project already uses this hybrid approach)

---

### Logging & Debugging

| Technology | Version | Purpose | Why |
|------------|---------|---------|-----|
| **OSLog (Logger)** | Built-in (macOS 11+) | Structured logging | Apple's recommended logging framework, integrates with Console.app, privacy controls |

**Best practices:**

1. **Create categorized loggers:**
   ```swift
   let logger = Logger(subsystem: "io.cubbit.DS3Drive", category: "FileProvider")
   let s3Logger = Logger(subsystem: "io.cubbit.DS3Drive", category: "S3Client")
   ```

2. **Use appropriate log levels:**
   - `debug`: Development-only (not persisted in production)
   - `info`: General information (persisted briefly)
   - `notice`: Default level (persisted)
   - `error`: Errors requiring attention
   - `fault`: Critical failures

3. **Apply privacy controls:**
   ```swift
   logger.info("Uploading file: \(filename, privacy: .public)")
   logger.error("S3 error: \(error.localizedDescription, privacy: .private)")
   ```

4. **Performance:** Debug logs are zero-cost in release builds if not actively captured

**Why OSLog over swift-log:**
- Native integration with Console.app and Instruments
- Built-in privacy redaction (critical for user data)
- No external dependencies
- File Provider extensions can't easily write to custom log files (sandboxing)

**Why NOT print/NSLog:**
- No categorization or filtering
- No log levels
- Not accessible via Console.app for extension processes

**Confidence:** HIGH (Apple's official logging framework, widely adopted)

**Sources:**
- [OSLog and Unified logging best practices](https://www.avanderlee.com/debugging/oslog-unified-logging/) (comprehensive guide)
- [Modern logging with OSLog framework](https://www.donnywals.com/modern-logging-with-the-oslog-framework-in-swift/) (Swift examples)

---

### Cryptography & Security

| Technology | Version | Purpose | Why |
|------------|---------|---------|-----|
| **CryptoKit** | Built-in (macOS 10.15+) | Challenge-response auth (Curve25519/ED25519) | Native, audited, performant |
| **Security.framework** | Built-in | Keychain storage (tokens, credentials) | Secure credential storage, shared via App Group |

**Current usage:**
- Curve25519 key exchange for auth challenge-response
- Keychain for storing auth tokens (shared between main app and extension via App Group)

**No changes needed** — current approach is correct.

**Confidence:** HIGH (standard Apple security frameworks)

---

### Networking & HTTP

| Technology | Version | Purpose | Why |
|------------|---------|---------|-----|
| **AsyncHTTPClient** | v1.20.1+ | HTTP client (transitive via Soto) | High-performance async HTTP, NIO-based |
| **URLSession** | Built-in | Direct HTTP calls (if needed) | Fallback for non-S3 API calls (IAM, Composer Hub) |

**Primary HTTP client:** Soto handles all S3 calls via AsyncHTTPClient internally. For Cubbit API calls (IAM, Composer Hub, Keyvault), use URLSession with async/await:

```swift
let (data, response) = try await URLSession.shared.data(for: request)
```

**Why URLSession for non-S3 calls:**
- Native, no extra dependencies
- Built-in async/await support (iOS 15+/macOS 12+)
- Simpler for REST API calls (vs. adding another HTTP client)

**Confidence:** HIGH (URLSession is standard, AsyncHTTPClient is mature)

---

### Concurrency & Performance

| Technology | Version | Purpose | Why |
|------------|---------|---------|-----|
| **Swift Concurrency** | Built-in (Swift 5.5+) | async/await, Task, actors | Modern async code, required for Soto v6 async APIs |
| **swift-atomics** | v1.2.0 | Thread-safe state in extension | File Provider extensions run multi-threaded |

**Patterns to follow:**

1. **File Provider methods → async calls:**
   ```swift
   func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier,
                      version requestedVersion: NSFileProviderItemVersion?,
                      request: NSFileProviderRequest,
                      completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress {
       Task {
           do {
               let result = await downloadFromS3(itemIdentifier)
               completionHandler(result.url, result.item, nil)
           } catch {
               completionHandler(nil, nil, error)
           }
       }
       return Progress()
   }
   ```

2. **Shared state management:**
   - Use `actor` for shared mutable state (e.g., sync queue manager)
   - Use `@MainActor` for UI updates

3. **Avoid blocking File Provider threads:**
   - Never use `Task { }.value` (blocks)
   - Use completion handlers as shown above

**Confidence:** HIGH (Swift concurrency is mature, File Provider integration patterns documented)

---

### Testing (Currently Missing)

**Recommended additions:**

| Technology | Version | Purpose | Why |
|------------|---------|---------|-----|
| **XCTest** | Built-in | Unit tests | Apple's standard testing framework |
| **swift-testing** | Future | Modern testing (Swift 6+) | Replacement for XCTest, but requires Swift 6 (defer until Soto v7 migration) |

**Testing strategy:**

1. **Unit tests:**
   - S3 client wrapper (mock Soto calls)
   - Metadata database operations (SwiftData queries)
   - Conflict detection logic

2. **Integration tests:**
   - File Provider extension methods (use `NSFileProviderTestingOperation`)
   - End-to-end sync scenarios

3. **Manual testing:**
   - File Provider extensions are notoriously hard to debug
   - Use Console.app to view OSLog output from extension process
   - Test in clean environment (separate user account)

**Confidence:** MEDIUM (testing File Provider is challenging; tooling is limited)

---

## Supporting Libraries (Transitive Dependencies)

These are pulled in by Soto and require no explicit management:

| Library | Version | Purpose |
|---------|---------|---------|
| swift-nio | v2.62.0+ | Async I/O primitives (Soto dependency) |
| swift-nio-ssl | v2.25.0+ | TLS support |
| swift-collections | v1.0.6+ | High-performance collections |
| swift-log | v1.5.3+ | Logging abstraction (Soto uses internally) |
| swift-metrics | v2.4.1+ | Metrics collection |

**No action needed** — SPM resolves these automatically.

---

## Package Manager

| Technology | Purpose | Why |
|------------|---------|-----|
| **Swift Package Manager (SPM)** | Dependency management | Native Xcode integration, lockfile support (Package.resolved), no external tools |

**Why NOT CocoaPods/Carthage:**
- SPM is Apple's official package manager
- Xcode-native (no separate install)
- Soto fully supports SPM

**Configuration:**
- Dependencies declared in Xcode project settings (or `Package.swift` if creating a package)
- Lockfile: `CubbitDS3Sync.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`

**Confidence:** HIGH (SPM is standard for Swift projects)

---

## Build & Distribution

| Technology | Version | Purpose | Why |
|------------|---------|---------|-----|
| **Xcode Build System** | Built-in | Compilation, signing, bundling | Apple-native, required for File Provider entitlements |
| **Git LFS** | 2.x | Asset storage (images, resources) | Current project already uses LFS for images |

**Code signing requirements:**
- App Group entitlement: `group.io.cubbit.DS3Drive` (shared between main app and extension)
- File Provider entitlement: `com.apple.developer.fileprovider.testing-mode` (development only)
- Provisioning profiles: separate profiles for main app and extension (matching bundle IDs)

**Distribution:**
- macOS App Store (requires App Store Connect submission)
- Direct distribution (requires Developer ID certificate + notarization)

**Confidence:** HIGH (standard Xcode workflow)

---

## Alternatives Considered

### S3 Client: Soto v7

**Why NOT adopted:**
- Requires Swift 6.0+ (breaking change)
- Removes EventLoopFuture APIs entirely (migration effort)
- Project needs to stabilize sync engine first
- v6 has async/await support already

**When to reconsider:** After sync engine stabilizes and Swift 6 migration validated

---

### S3 Client: aws-sdk-swift

**Why NOT adopted:**
- Amazon's official SDK, but less mature on Apple platforms
- Soto has 8 years of development vs. aws-sdk-swift's 3 years
- Soto has proven S3-compatible endpoint support (required for Cubbit DS3)
- No compelling reason to switch from working dependency

---

### Database: Core Data

**Why NOT adopted:**
- More boilerplate than SwiftData
- NSManagedObject subclassing, .xcdatamodel files
- Not cross-platform friendly (iOS/iPadOS requires different setup)

**When to reconsider:** If SwiftData limitations become blocking (complex migrations, advanced predicates)

---

### Database: Custom SQLite

**Why NOT adopted:**
- Reinventing the wheel (relationship management, indexing, migrations)
- More code to maintain
- No iCloud sync support (future feature)

---

### Logging: swift-log

**Why NOT adopted:**
- Requires custom backend implementation
- OSLog integration requires additional code
- OSLog is more performant and native

---

### Logging: SwiftyBeaver

**Why NOT adopted:**
- Third-party dependency (introduces maintenance risk)
- File Provider sandboxing makes file logging difficult
- OSLog is sufficient and native

---

## Installation

### Core Dependencies (Xcode SPM)

```swift
// Add to Xcode project via File → Add Package Dependencies
dependencies: [
    .package(url: "https://github.com/soto-project/soto.git", from: "6.13.0")
]

// Add to targets
targets: [
    .target(
        name: "DS3Drive",
        dependencies: [
            .product(name: "SotoS3", package: "soto")
        ]
    ),
    .target(
        name: "FileProviderExtension",
        dependencies: [
            .product(name: "SotoS3", package: "soto")
        ]
    )
]
```

### SwiftData

No installation needed — built into macOS 14+ SDK. Import in Swift files:

```swift
import SwiftData
```

### OSLog

No installation needed — built into macOS 11+ SDK. Import in Swift files:

```swift
import OSLog
```

---

## Version Matrix

| Component | Current | Recommended | Future |
|-----------|---------|-------------|--------|
| Swift | 5.x | 5.10+ | 6.0+ (with Soto v7) |
| macOS target | 14.2+ | 14.0+ | 15.0+ (for SwiftData improvements) |
| Xcode | 15.x | 15.3+ | 16.0+ (Swift 6 support) |
| Soto | v6.8.0 | v6.13.0 | v7.13.0+ (after Swift 6 migration) |
| SwiftData | macOS 14 | macOS 14+ | macOS 15+ (indexing, schema versioning) |

---

## Migration Strategy

### Immediate (Phase 1)

1. **Upgrade Soto v6.8.0 → v6.13.0**
   - Low risk (patch releases)
   - Verify async/await API stability
   - Test multipart upload edge cases

2. **Add SwiftData models**
   - Define `@Model` for file metadata
   - Create `ModelContainer` shared via App Group
   - Migrate from in-memory state to persistent DB

3. **Implement OSLog categorization**
   - Replace print statements with Logger instances
   - Add subsystem/category structure
   - Configure privacy levels

### Future (Phase 2+)

1. **Swift 6 migration**
   - Enable strict concurrency checking
   - Resolve data race warnings
   - Upgrade to Soto v7.x

2. **macOS 15 features**
   - SwiftData compound indexes (`#Index` macro)
   - Improved schema migration
   - Performance optimizations

---

## Confidence Assessment

| Area | Confidence | Rationale |
|------|------------|-----------|
| S3 Client (Soto v6) | HIGH | Official releases verified, current project dependency, async/await support confirmed |
| Database (SwiftData) | MEDIUM | Production-ready but less mature than Core Data; sufficient for metadata use case |
| File Provider | HIGH | Official Apple framework, well-documented, existing project implementation |
| Logging (OSLog) | HIGH | Apple's official logging framework, widely adopted, Console.app integration |
| Swift Concurrency | HIGH | Mature (Swift 5.5+), required for Soto async APIs |
| Testing | MEDIUM | File Provider testing is challenging; limited tooling |

---

## Sources

### High Confidence (Official Documentation)

- [Soto v7.0.0 release notes](https://soto.codes/2024/07/v7-release.html) — Swift 6 requirement confirmed
- [Soto GitHub releases](https://github.com/soto-project/soto/releases) — Latest versions verified
- [SwiftData documentation](https://developer.apple.com/documentation/swiftdata) — macOS 14+ requirement
- [What's new in SwiftData (WWDC24)](https://developer.apple.com/videos/play/wwdc2024/10137/) — Schema versioning, indexing improvements
- [NSFileProviderReplicatedExtension docs](https://developer.apple.com/documentation/fileprovider/nsfileproviderreplicatedextension) — Official API reference

### Medium Confidence (Community Resources)

- [Build your own cloud sync using FileProvider](https://claudiocambra.com/posts/build-file-provider-sync/) — Implementation guide (comprehensive)
- [OSLog and Unified logging best practices](https://www.avanderlee.com/debugging/oslog-unified-logging/) — Community tutorial
- [Modern logging with OSLog](https://www.donnywals.com/modern-logging-with-the-oslog-framework-in-swift/) — Code examples

### Low Confidence (Training Data)

- General Swift concurrency patterns (not verified with 2026 sources)

---

**Last updated:** 2026-03-11
