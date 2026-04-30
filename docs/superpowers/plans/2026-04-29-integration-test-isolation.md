# Integration Test Isolation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prevent integration tests from touching the production App Group container by injecting a per-test temp directory into `SharedData` and `DS3Authentication`.

**Architecture:** Add a second `init(testContainerURL:)` to `SharedData` that stores an override URL. `sharedContainerURL()` returns that URL instead of the App Group path. `DS3Authentication` gains a `sharedData` stored property (defaulting to `SharedData.default()`) so tests can inject a temp-backed instance. `DS3IntegrationTestCase.setUp` creates a UUID temp dir and tears it down after each test.

**Tech Stack:** Swift, XCTest, Foundation (`FileManager`, `URL`), no new dependencies.

---

### Task 1: Add `init(testContainerURL:)` to `SharedData`

**Files:**
- Modify: `DS3Lib/Sources/DS3Lib/SharedData/SharedData.swift:30-54`
- Test: `DS3Lib/Tests/DS3LibTests/SharedDataPersistenceTests.swift`

- [ ] **Step 1: Write the failing test**

Add this test method to `SharedDataPersistenceTests` (inside the existing class, after the last test):

```swift
func testSharedDataWithTestContainerURLWritesToGivenDirectory() throws {
    let sharedData = SharedData(testContainerURL: tempDir)
    try sharedData.persistDS3Drives(ds3Drives: [])
    let expected = tempDir.appendingPathComponent(DefaultSettings.FileNames.drivesFileName)
    XCTAssertTrue(FileManager.default.fileExists(atPath: expected.path))
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
xcodebuild test \
  -scheme DS3Lib \
  -destination 'platform=macOS' \
  -testIdentifier 'DS3LibTests/SharedDataPersistenceTests/testSharedDataWithTestContainerURLWritesToGivenDirectory' \
  2>&1 | grep -E "FAIL|PASS|error:"
```

Expected: compile error — `SharedData` has no `init(testContainerURL:)`.

- [ ] **Step 3: Implement the change in `SharedData.swift`**

Replace the existing singleton block (lines 31–43):

```swift
// BEFORE:
public class SharedData: @unchecked Sendable {
    private static let instance = SharedData()

    let logger = Logger(subsystem: LogSubsystem.app, category: LogCategory.metadata.rawValue)

    private init() {
        // Singleton
    }

    public static func `default`() -> SharedData {
        instance
    }
```

With:

```swift
// AFTER:
public class SharedData: @unchecked Sendable {
    private static let instance = SharedData()

    let logger = Logger(subsystem: LogSubsystem.app, category: LogCategory.metadata.rawValue)
    private let _testContainerURL: URL?

    private init() {
        _testContainerURL = nil
    }

    /// Creates a SharedData instance backed by `url` instead of the App Group container.
    /// For test use only — production code must use `SharedData.default()`.
    public init(testContainerURL url: URL) {
        _testContainerURL = url
    }

    public static func `default`() -> SharedData {
        instance
    }
```

Replace `sharedContainerURL()` (lines 47–54):

```swift
// BEFORE:
func sharedContainerURL() throws -> URL {
    guard let url = FileManager.default
        .containerURL(forSecurityApplicationGroupIdentifier: DefaultSettings.appGroup)
    else {
        throw SharedDataError.cannotAccessAppGroup
    }
    return url
}
```

With:

```swift
// AFTER:
func sharedContainerURL() throws -> URL {
    if let url = _testContainerURL { return url }
    guard let url = FileManager.default
        .containerURL(forSecurityApplicationGroupIdentifier: DefaultSettings.appGroup)
    else {
        throw SharedDataError.cannotAccessAppGroup
    }
    return url
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
xcodebuild test \
  -scheme DS3Lib \
  -destination 'platform=macOS' \
  -testIdentifier 'DS3LibTests/SharedDataPersistenceTests/testSharedDataWithTestContainerURLWritesToGivenDirectory' \
  2>&1 | grep -E "FAIL|PASS|error:"
```

Expected: `PASS`.

- [ ] **Step 5: Run the full DS3Lib test suite to check for regressions**

```bash
xcodebuild test \
  -scheme DS3Lib \
  -destination 'platform=macOS' \
  2>&1 | tail -20
```

Expected: all previously passing tests still pass.

- [ ] **Step 6: Commit**

```bash
git add DS3Lib/Sources/DS3Lib/SharedData/SharedData.swift \
        DS3Lib/Tests/DS3LibTests/SharedDataPersistenceTests.swift
git commit -m "feat: add SharedData(testContainerURL:) for test isolation"
```

---

### Task 2: Inject `SharedData` into `DS3Authentication`

**Files:**
- Modify: `DS3Lib/Sources/DS3Lib/DS3Authentication.swift:125–139, 453–487`
- Test: `DS3Lib/Tests/DS3LibTests/DS3AuthenticationTests.swift`

- [ ] **Step 1: Write the failing test**

Add this test to `DS3AuthenticationTests` (inside the existing class, after `testLogoutWhenAlreadyLoggedOutIsNoOp`):

```swift
func testLogoutDeletesFilesFromInjectedSharedData() throws {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let sharedData = SharedData(testContainerURL: tempDir)
    let token = try TestHelpers.makeToken(expiringAt: Date().addingTimeInterval(3600))
    let session = AccountSession(token: token, refreshToken: "refresh")
    let account = Account(
        id: "acc-1", firstName: "Test", lastName: "User",
        isInternal: false, isBanned: false, createdAt: "2023-01-01",
        maxAllowedProjects: 5,
        emails: [], isTwoFactorEnabled: false, tenantId: "t-1",
        endpointGateway: "https://s3.cubbit.eu", authProvider: "cubbit"
    )

    let auth = DS3Authentication(
        accountSession: session, account: account,
        isLogged: true, sharedData: sharedData
    )
    // Write session and account to the temp dir
    try auth.persist()

    let sessionFile = tempDir.appendingPathComponent(DefaultSettings.FileNames.accountSessionFileName)
    let accountFile = tempDir.appendingPathComponent(DefaultSettings.FileNames.accountFileName)
    XCTAssertTrue(FileManager.default.fileExists(atPath: sessionFile.path), "session should exist before logout")
    XCTAssertTrue(FileManager.default.fileExists(atPath: accountFile.path), "account should exist before logout")

    auth.logout()

    XCTAssertFalse(FileManager.default.fileExists(atPath: sessionFile.path), "session should be deleted after logout")
    XCTAssertFalse(FileManager.default.fileExists(atPath: accountFile.path), "account should be deleted after logout")
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
xcodebuild test \
  -scheme DS3Lib \
  -destination 'platform=macOS' \
  -testIdentifier 'DS3LibTests/DS3AuthenticationTests/testLogoutDeletesFilesFromInjectedSharedData' \
  2>&1 | grep -E "FAIL|PASS|error:"
```

Expected: compile error — no `sharedData` parameter on `DS3Authentication.init(accountSession:account:isLogged:)` and `persist()` uses `SharedData.default()`.

- [ ] **Step 3: Add `sharedData` stored property and update the inits**

Find the class body opening and stored property declarations of `DS3Authentication`. Add the `sharedData` property and update both inits.

The current `init(urls:)` at line 125:

```swift
// BEFORE:
public init(urls: CubbitAPIURLs = CubbitAPIURLs()) {
    self.urls = urls
}
```

Replace with:

```swift
// AFTER:
private let sharedData: SharedData

public init(urls: CubbitAPIURLs = CubbitAPIURLs(), sharedData: SharedData = SharedData.default()) {
    self.urls = urls
    self.sharedData = sharedData
}
```

The current `init(accountSession:account:isLogged:urls:)` at line 129:

```swift
// BEFORE:
public init(
    accountSession: AccountSession,
    account: Account,
    isLogged: Bool,
    urls: CubbitAPIURLs = CubbitAPIURLs()
) {
    self.urls = urls
    self.accountSession = accountSession
    self.account = account
    self.isLogged = isLogged
}
```

Replace with:

```swift
// AFTER:
public init(
    accountSession: AccountSession,
    account: Account,
    isLogged: Bool,
    urls: CubbitAPIURLs = CubbitAPIURLs(),
    sharedData: SharedData = SharedData.default()
) {
    self.urls = urls
    self.sharedData = sharedData
    self.accountSession = accountSession
    self.account = account
    self.isLogged = isLogged
}
```

- [ ] **Step 4: Replace `SharedData.default()` calls with `self.sharedData` in instance methods**

In `persist()` (around line 453):

```swift
// BEFORE:
let sharedData = SharedData.default()
try sharedData.persistAccountSession(accountSession: accountSession)
try sharedData.persistAccount(account: account)
```

Replace with:

```swift
// AFTER:
try sharedData.persistAccountSession(accountSession: accountSession)
try sharedData.persistAccount(account: account)
```

In `deleteFromDisk()` (around line 483):

```swift
// BEFORE:
let sharedData = SharedData.default()
try sharedData.deleteAccountSessionFromPersistence()
try sharedData.deleteAccountFromPersistence()
try sharedData.deleteDS3APIKeysFromPersistence()
```

Replace with:

```swift
// AFTER:
try sharedData.deleteAccountSessionFromPersistence()
try sharedData.deleteAccountFromPersistence()
try sharedData.deleteDS3APIKeysFromPersistence()
```

Note: `loadFromPersistenceOrCreateNew()` is a static factory method — it cannot use `self.sharedData`. Leave its `SharedData.default()` calls unchanged; this method is production-only.

- [ ] **Step 5: Run the failing test to verify it now passes**

```bash
xcodebuild test \
  -scheme DS3Lib \
  -destination 'platform=macOS' \
  -testIdentifier 'DS3LibTests/DS3AuthenticationTests/testLogoutDeletesFilesFromInjectedSharedData' \
  2>&1 | grep -E "FAIL|PASS|error:"
```

Expected: `PASS`.

- [ ] **Step 6: Run the full test suite**

```bash
xcodebuild test \
  -scheme DS3Lib \
  -destination 'platform=macOS' \
  2>&1 | tail -20
```

Expected: all previously passing tests still pass.

- [ ] **Step 7: Commit**

```bash
git add DS3Lib/Sources/DS3Lib/DS3Authentication.swift \
        DS3Lib/Tests/DS3LibTests/DS3AuthenticationTests.swift
git commit -m "feat: inject SharedData into DS3Authentication for test isolation"
```

---

### Task 3: Wire `DS3IntegrationTestCase` to use a temp container

**Files:**
- Modify: `DS3Lib/Tests/DS3LibTests/Integration/IntegrationTestConfig.swift:53–84`

- [ ] **Step 1: Update `DS3IntegrationTestCase`**

Replace the existing `DS3IntegrationTestCase` class body (lines 53–84):

```swift
// BEFORE:
class DS3IntegrationTestCase: XCTestCase {
    var authentication: DS3Authentication!
    var urls: CubbitAPIURLs!

    override func setUp() async throws {
        try IntegrationTestConfig.skipIfNotConfigured()

        // Ensure the App Group container directory exists.
        // On CI runners (SPM test environment), there are no entitlements so
        // FileManager.containerURL(forSecurityApplicationGroupIdentifier:) returns nil
        // on iOS but on macOS it resolves to ~/Library/Group Containers/<appGroup>.
        // Create it preemptively so SharedData.persist() doesn't fail.
        let groupDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/\(DefaultSettings.appGroup)")
        try? FileManager.default.createDirectory(at: groupDir, withIntermediateDirectories: true)

        urls = IntegrationTestConfig.makeURLs()
        authentication = DS3Authentication(urls: urls)

        try await authentication.login(
            email: IntegrationTestConfig.email!,
            password: IntegrationTestConfig.password!,
            tenant: IntegrationTestConfig.tenant
        )
    }

    override func tearDown() async throws {
        authentication?.logout()
        authentication = nil
        urls = nil
    }
}
```

With:

```swift
// AFTER:
class DS3IntegrationTestCase: XCTestCase {
    var authentication: DS3Authentication!
    var urls: CubbitAPIURLs!
    private var tempContainerURL: URL!

    override func setUp() async throws {
        try IntegrationTestConfig.skipIfNotConfigured()

        tempContainerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempContainerURL, withIntermediateDirectories: true)

        urls = IntegrationTestConfig.makeURLs()
        let sharedData = SharedData(testContainerURL: tempContainerURL)
        authentication = DS3Authentication(urls: urls, sharedData: sharedData)

        try await authentication.login(
            email: IntegrationTestConfig.email!,
            password: IntegrationTestConfig.password!,
            tenant: IntegrationTestConfig.tenant
        )
    }

    override func tearDown() async throws {
        authentication?.logout()
        authentication = nil
        urls = nil
        try? FileManager.default.removeItem(at: tempContainerURL)
        tempContainerURL = nil
    }
}
```

`DS3S3IntegrationTestCase` inherits `setUp`/`tearDown` from `DS3IntegrationTestCase` — no changes needed there.

- [ ] **Step 2: Run the full test suite to verify everything compiles and unit tests pass**

```bash
xcodebuild test \
  -scheme DS3Lib \
  -destination 'platform=macOS' \
  2>&1 | tail -20
```

Expected: all previously passing unit tests still pass. Integration tests require env vars and will be skipped in normal CI.

- [ ] **Step 3: Commit**

```bash
git add DS3Lib/Tests/DS3LibTests/Integration/IntegrationTestConfig.swift
git commit -m "fix: isolate integration tests from production App Group container"
```

---

## Self-Review

**Spec coverage:**
- ✅ `SharedData.init(testContainerURL:)` — Task 1
- ✅ `DS3Authentication.init(urls:sharedData:)` — Task 2
- ✅ `DS3Authentication.init(accountSession:account:isLogged:urls:sharedData:)` — Task 2
- ✅ `DS3IntegrationTestCase` uses temp container — Task 3
- ✅ Temp dir cleaned up in `tearDown` — Task 3
- ✅ `SharedData.default()` production path unchanged — invariant held throughout

**Placeholder scan:** No TBDs or vague steps. All code blocks are complete.

**Type consistency:**
- `SharedData(testContainerURL:)` — consistent across Task 1 (impl) and Tasks 2–3 (usage)
- `DS3Authentication(urls:sharedData:)` — consistent across Task 2 (impl) and Task 3 (usage)
- `DefaultSettings.FileNames.accountSessionFileName` / `accountFileName` — verified names in `DefaultSettings.swift`
