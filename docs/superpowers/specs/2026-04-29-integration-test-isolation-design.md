# Integration Test Isolation Design

**Date:** 2026-04-29
**Status:** Approved

## Problem

`DS3IntegrationTestCase` runs against the production App Group container (`group.X889956QSM.io.cubbit.DS3Drive`). Its `tearDown()` calls `authentication.logout()` → `deleteFromDisk()`, which deletes auth files from the shared container. This was also deleting `drives.json` (now fixed), but the root problem remains: tests write/delete real files from the container the development build uses, creating risk of data loss and test interference.

## Goal

Integration tests must use an isolated temp directory, leaving the production App Group container untouched.

## Design

### 1. `SharedData` — injectable container URL

Add a second public init that accepts a `URL` directly. When this init is used, `sharedContainerURL()` returns that URL instead of resolving the App Group path. The production singleton (`SharedData.default()`) is unchanged.

```swift
// Production path (unchanged):
private init() {}
private static let instance = SharedData()
public static func `default`() -> SharedData { instance }

// Test path (new):
public init(testContainerURL: URL) {
    self._testContainerURL = testContainerURL
}

private var _testContainerURL: URL?

private func sharedContainerURL() throws -> URL {
    if let url = _testContainerURL { return url }
    guard let url = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: DefaultSettings.appGroup
    ) else { throw SharedDataError.containerNotFound }
    return url
}
```

All existing methods (`loadDS3DrivesFromPersistence`, `persistDS3Drives`, `loadAccountSession`, etc.) call `sharedContainerURL()` — no other changes needed in `SharedData`.

### 2. `DS3Authentication` — accept injected `SharedData`

Add an init overload that takes a `SharedData` instance. The no-arg init continues calling `SharedData.default()`, so all production call sites are unchanged.

```swift
// Production (unchanged):
public init() {
    self.sharedData = SharedData.default()
}

// Test injection (new):
public init(sharedData: SharedData) {
    self.sharedData = sharedData
}
```

`DS3Authentication` must replace any remaining `SharedData.default()` calls inside the class body with `self.sharedData` — these are the ones that would still escape to the production container.

### 3. `DS3IntegrationTestCase` — use temp directory

```swift
private var tempContainerURL: URL!

override func setUp() async throws {
    tempContainerURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempContainerURL, withIntermediateDirectories: true)
    let sharedData = SharedData(testContainerURL: tempContainerURL)
    authentication = DS3Authentication(sharedData: sharedData)
    try await authentication.login(...)
}

override func tearDown() async throws {
    try? await authentication?.logout()
    try? FileManager.default.removeItem(at: tempContainerURL)
    tempContainerURL = nil
}
```

Each test run gets a fresh UUID directory under `/tmp`. Cleanup is a single `removeItem` on the root — atomic and complete.

## Scope

| File | Change |
|------|--------|
| `DS3Lib/Sources/DS3Lib/SharedData/SharedData.swift` | Add `init(testContainerURL:)`, thread `_testContainerURL` through `sharedContainerURL()` |
| `DS3Lib/Sources/DS3Lib/DS3Authentication.swift` | Add `init(sharedData:)`, replace internal `SharedData.default()` calls with `self.sharedData` |
| `DS3Lib/Tests/DS3LibTests/Integration/IntegrationTestConfig.swift` | Use temp container as above |

No other production files are touched. No env vars, no global state mutation, no changes to `DS3DriveManager`.

## Invariants

- `SharedData.default()` always resolves the production App Group container — no change to production behaviour.
- Tests that don't use `DS3Authentication` or `SharedData` are unaffected.
- Each test run gets a unique directory, so parallel test execution is safe.
- `tearDown` removes the entire temp tree — no leftover files accumulate in `/tmp`.

## Out of Scope

- Unit tests that mock `SharedData` at a higher level (e.g. `SharedDataPersistenceTests`) — they already use their own temp dirs and are fine.
- `DS3DriveManager` injection — drive state is not written by integration tests, so no change needed there.
