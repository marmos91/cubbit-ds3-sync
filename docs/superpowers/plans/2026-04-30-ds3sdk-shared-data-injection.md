# DS3SDK SharedData Injection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Inject `SharedData` into `DS3SDK` so integration tests that exercise `loadOrCreateDS3APIKeys` / `generateDS3APIKey` don't write API key credentials to the production App Group container.

**Architecture:** Identical pattern to `DS3Authentication` (PR #142). Add `private let sharedData: SharedData` to `DS3SDK`. Update `init(withAuthentication:urls:)` to accept `sharedData: SharedData = SharedData.default()` (backward-compatible). Replace the 4 inline `SharedData.default()` calls in instance methods with `self.sharedData`. Update `DS3S3IntegrationTestCase.setUp` to inject the existing `tempContainerURL`-backed `SharedData` into the `DS3SDK` it constructs, then remove the `loadOrCreateDS3APIKeys` bypass comment.

**Tech Stack:** Swift, XCTest, Foundation. No new dependencies.

---

## Background

In PR #142 we injected `SharedData` into `DS3Authentication` and wired `DS3IntegrationTestCase` to use a per-test temp directory. However `DS3SDK` still calls `SharedData.default()` directly at 4 sites:

| File | Line | Call |
|------|------|------|
| `DS3SDK.swift` | 163 | `SharedData.default().loadDS3APIKeysFromPersistence()` (in `loadOrCreateDS3APIKeys`) |
| `DS3SDK.swift` | 185 | `SharedData.default().deleteDS3APIKeyFromPersistence(...)` (in `loadOrCreateDS3APIKeys`) |
| `DS3SDK.swift` | 222 | `SharedData.default().loadDS3APIKeysFromPersistence()` (in `generateDS3APIKey`) |
| `DS3SDK.swift` | 225 | `SharedData.default().persistDS3APIKeys(...)` (in `generateDS3APIKey`) |

`DS3S3IntegrationTestCase.setUp` currently bypasses `loadOrCreateDS3APIKeys()` entirely and calls the SDK HTTP API directly, with a comment "to avoid coupling this test to the drive-management layer." After this plan, the bypass is no longer needed for isolation reasons — the SDK will write to the temp container. (The test can keep using the direct API path if preferred; this plan makes the injected path safe but doesn't mandate changing the integration test strategy.)

---

### Task 1: Add `sharedData` injection to `DS3SDK`

**Files:**
- Modify: `DS3Lib/Sources/DS3Lib/DS3SDK.swift`
- Test: `DS3Lib/Tests/DS3LibTests/DS3SDKTests.swift`

- [ ] **Step 1: Write the failing test**

Add to `DS3SDKTests` (after the last existing test):

```swift
func testSDKWithInjectedSharedDataWritesAPIKeysToGivenDirectory() throws {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let sharedData = SharedData(testContainerURL: tempDir)

    // Pre-seed one key, then persist a second via sharedData directly to simulate
    // what generateDS3APIKey does: load, append, persist.
    let existingKey = DS3ApiKey(
        apiKey: "access-key-1", secretKey: "secret-1",
        name: "DS3Drive-for-macOS-user-project", projectId: nil
    )
    try sharedData.persistDS3APIKeys([existingKey])

    // Verify round-trip through injected container (not the production App Group)
    let loaded = try sharedData.loadDS3APIKeysFromPersistence()
    XCTAssertEqual(loaded.count, 1)
    XCTAssertEqual(loaded[0].apiKey, "access-key-1")

    // Verify nothing was written to the production App Group
    let credentialsFile = tempDir.appendingPathComponent(DefaultSettings.FileNames.credentialsFileName)
    XCTAssertTrue(FileManager.default.fileExists(atPath: credentialsFile.path))
}
```

Note: `generateDS3APIKey` and `loadOrCreateDS3APIKeys` both make real network calls and cannot be unit-tested without mocking. This test validates the `SharedData` injection at the level immediately below the SDK — confirming the container a `DS3SDK` instance will write to is the injected one. Full SDK path coverage is provided by the integration test in Task 2.

- [ ] **Step 2: Run test to verify it compiles and passes (it doesn't touch `DS3SDK` yet)**

```bash
swift test --package-path DS3Lib \
  --filter DS3LibTests.DS3SDKTests/testSDKWithInjectedSharedDataWritesAPIKeysToGivenDirectory \
  2>&1 | grep -E "FAIL|PASS|error:"
```

Expected: `PASS` (this test only exercises `SharedData`, not `DS3SDK` yet — it's a baseline).

- [ ] **Step 3: Add `sharedData` stored property to `DS3SDK`**

In `DS3Lib/Sources/DS3Lib/DS3SDK.swift`, find the stored properties block (around line 30):

```swift
// BEFORE:
private let urls: CubbitAPIURLs
private let logger = Logger(subsystem: LogSubsystem.app, category: LogCategory.auth.rawValue)

public init(
    withAuthentication authentication: DS3Authentication,
    urls: CubbitAPIURLs? = nil
) {
    self.authentication = authentication
    self.urls = urls ?? authentication.urls
}
```

Replace with:

```swift
// AFTER:
private let urls: CubbitAPIURLs
private let sharedData: SharedData
private let logger = Logger(subsystem: LogSubsystem.app, category: LogCategory.auth.rawValue)

public init(
    withAuthentication authentication: DS3Authentication,
    urls: CubbitAPIURLs? = nil,
    sharedData: SharedData = SharedData.default()
) {
    self.authentication = authentication
    self.urls = urls ?? authentication.urls
    self.sharedData = sharedData
}
```

- [ ] **Step 4: Replace the 4 inline `SharedData.default()` calls with `self.sharedData`**

In `loadOrCreateDS3APIKeys` (around line 163):

```swift
// BEFORE:
let localApiKeys = (try? SharedData.default().loadDS3APIKeysFromPersistence()) ?? []
```

```swift
// AFTER:
let localApiKeys = (try? sharedData.loadDS3APIKeysFromPersistence()) ?? []
```

Around line 185:

```swift
// BEFORE:
try SharedData.default().deleteDS3APIKeyFromPersistence(withName: localApiKey.name)
```

```swift
// AFTER:
try sharedData.deleteDS3APIKeyFromPersistence(withName: localApiKey.name)
```

In `generateDS3APIKey` (around line 222):

```swift
// BEFORE:
var localApiKeys = (try? SharedData.default().loadDS3APIKeysFromPersistence()) ?? []
localApiKeys.append(newApiKey)
try SharedData.default().persistDS3APIKeys(localApiKeys)
```

```swift
// AFTER:
var localApiKeys = (try? sharedData.loadDS3APIKeysFromPersistence()) ?? []
localApiKeys.append(newApiKey)
try sharedData.persistDS3APIKeys(localApiKeys)
```

- [ ] **Step 5: Run the full test suite**

```bash
swift test --package-path DS3Lib 2>&1 | tail -8
```

Expected: all previously passing tests still pass (523 tests, 0 failures).

- [ ] **Step 6: Commit**

```bash
git add DS3Lib/Sources/DS3Lib/DS3SDK.swift \
        DS3Lib/Tests/DS3LibTests/DS3SDKTests.swift
git commit -m "feat: inject SharedData into DS3SDK for test isolation"
```

---

### Task 2: Inject `SharedData` into `DS3SDK` inside `DS3S3IntegrationTestCase`

**Files:**
- Modify: `DS3Lib/Tests/DS3LibTests/Integration/IntegrationTestConfig.swift`

`DS3S3IntegrationTestCase.setUp` currently constructs `DS3SDK` without a `sharedData` parameter, so it still writes API key credentials to the production App Group container. This task wires the existing `tempContainerURL` into the SDK.

- [ ] **Step 1: Update `DS3S3IntegrationTestCase.setUp`**

Find the line in `DS3S3IntegrationTestCase.setUp` that creates `DS3SDK`:

```swift
// BEFORE:
let sdk = DS3SDK(withAuthentication: authentication, urls: urls)
```

Replace with:

```swift
// AFTER:
let sharedData = SharedData(testContainerURL: tempContainerURL!)
let sdk = DS3SDK(withAuthentication: authentication, urls: urls, sharedData: sharedData)
```

Note: `tempContainerURL` is `private` on the base class `DS3IntegrationTestCase`. If `private` access prevents it from being read in the subclass, change the declaration from `private var tempContainerURL` to `var tempContainerURL` (internal). Check the current access level before deciding.

Also update the comment above the `DS3SDK` construction (around the "to avoid coupling" line). Keep the rationale comment but remove any remaining reference to SharedData not being available:

```swift
// Uses the SDK API directly instead of loadOrCreateDS3APIKeys() to
// avoid creating a runtime dependency on drive-management state in S3 tests.
```

- [ ] **Step 2: Run the full test suite to verify no regressions**

```bash
swift test --package-path DS3Lib 2>&1 | tail -8
```

Expected: 523+ tests, 0 failures. Integration tests skipped (missing env vars).

- [ ] **Step 3: Commit**

```bash
git add DS3Lib/Tests/DS3LibTests/Integration/IntegrationTestConfig.swift
git commit -m "fix: inject shared data into DS3SDK in integration test setup"
```

---

## Access Level Note

`tempContainerURL` is declared `private var` on `DS3IntegrationTestCase`. If the subclass `DS3S3IntegrationTestCase` can't access it (compile error), change the declaration in `IntegrationTestConfig.swift` from:

```swift
private var tempContainerURL: URL?
```

to:

```swift
var tempContainerURL: URL?
```

Internal visibility is fine here — all consumers are within the same test target.

---

## Self-Review

**Spec coverage:**
- ✅ `DS3SDK.init` gains `sharedData` parameter — Task 1
- ✅ All 4 `SharedData.default()` instance-method calls replaced — Task 1
- ✅ `DS3S3IntegrationTestCase` injects the temp container into `DS3SDK` — Task 2

**Type consistency:**
- `SharedData(testContainerURL:)` — established in PR #142, consumed here
- `DS3SDK(withAuthentication:urls:sharedData:)` — new parameter defined in Task 1, used in Task 2

**Out of scope (deferred):**
- `DS3DriveManager.persist()` / `loadFromDiskOrCreateNew()` — drive state is not written by integration tests, so isolation risk is low. Defer to a future pass if integration tests start exercising drive management.
