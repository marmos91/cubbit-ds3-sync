# Coding Conventions

**Analysis Date:** 2026-03-11

## Naming Patterns

**Files:**
- PascalCase for all Swift files: `PreferencesViewModel.swift`, `TrayDriveRowView.swift`, `Account.swift`
- Suffix naming by type:
  - Views: `*View.swift` (e.g., `PreferencesView.swift`, `TutorialView.swift`, `TrayDriveRowView.swift`)
  - ViewModels: `*ViewModel.swift` (e.g., `PreferencesViewModel.swift`, `SyncAnchorSelectionViewModel.swift`)
  - Models: `*Model.swift` or plain name for data structures (e.g., `SlideModel.swift`, `Account.swift`, `Project.swift`)
- Extensions: `Type+Extensions.swift` (e.g., `View+Extensions.swift`, `Notifications+Extensions.swift`, `Bundle+Extensions.swift`)

**Types and Classes:**
- PascalCase: `PreferencesViewModel`, `DS3DriveViewModel`, `SyncAnchorSelectionViewModel`
- Observable classes: `@Observable class ClassName` (Swift 6+ observation pattern)
- Enums for errors: `*Error` suffix (e.g., `SyncAnchorSelectionError`, `DS3SDKError`, `ControlFlowError`)
- Enums for grouping constants: `DefaultSettings`, with nested enums for organization (e.g., `DefaultSettings.S3`, `DefaultSettings.Extension`)

**Functions and Methods:**
- camelCase: `loadBuckets()`, `selectProject()`, `formatFullName()`, `listFoldersForCurrentBucket()`
- Verb-first pattern for action methods: `load`, `select`, `disconnect`, `format`, `setup`
- Getter methods are simple nouns: `getRemoteProjects()`, `getSelectedSyncAnchor()`, `consoleURL()`
- Helper methods use `with` prefix: `withRetries()`, `withAuthentication`, `withLogger`

**Variables and Properties:**
- camelCase: `selectedProject`, `driveStatus`, `totalTransferredSize`, `setupStep`
- Boolean properties: `is*` or `*Shown` prefix (e.g., `isLogged`, `isDefault`, `isVerified`, `tutorialShown`, `loginItemSet`)
- Private properties: `private let logger`, `private var instance`
- Computed state variables in views: Clear names without underscore (e.g., `isHovering`, `isShowingPassword`)

**Constants:**
- UPPER_SNAKE_CASE for config values: Used within enums like `DefaultSettings.S3.multipartUploadPartSize`
- API keys and URL constants: Within enum structures for organization
  - `DefaultSettings.appGroup = "group.io.cubbit.CubbitDS3Sync"`
  - `DefaultSettings.apiKeyNamePrefix = "DS3Sync-for-macOS"`

## Code Style

**Formatting:**
- No explicit formatter configured in codebase
- Consistent spacing: Single blank line between methods, logical sections separated by MARK comments
- Line length: Generally under 120 characters
- Indentation: 4 spaces (standard Swift)

**Linting:**
- No linting tool configured
- Code follows standard Swift conventions by community consensus

**Conditional Spacing:**
- Multi-line conditions on guard statements use specific alignment
- Example: `guard let url = URL(...) else { throw error }`
- Multi-line guards use proper indentation for readability

## Import Organization

**Order:**
1. Framework imports (SwiftUI, Foundation, etc.)
2. System imports (os.log, FileProvider, AppKit)
3. External SDK imports (SotoS3)
4. Internal module imports (DS3Lib)

**Example from `SyncAnchorSelectionViewModel.swift`:**
```swift
import Foundation
import SwiftUI
import SotoS3
import os.log
```

**Path Aliases:**
- No path aliases used in the codebase
- Imports reference full module names: `import DS3Lib`

## Error Handling

**Patterns:**
- Custom error enums conforming to `Error` and `LocalizedError`
- All custom errors implement `errorDescription` property for user-facing messages
- Example from `SyncAnchorSelectionError`:
```swift
enum SyncAnchorSelectionError: Error, LocalizedError {
    case missingBuckets
    case noBucketSelected
    case noIAMUserSelected
    case DS3ClientError
    case DS3ServerError

    var errorDescription: String? {
        switch self {
        case .missingBuckets:
            return NSLocalizedString("No buckets found in server response", comment: "Missing buckets in response")
        // ...
        }
    }
}
```

**Try-Catch Pattern:**
```swift
do {
    try await self.initializeAWSIfNecessary()
    // perform operation
} catch is AWSClientError {
    self.error = SyncAnchorSelectionError.DS3ClientError
} catch is AWSServerError {
    self.error = SyncAnchorSelectionError.DS3ServerError
} catch let error as DS3AuthenticationError {
    self.authenticationError = error
} catch {
    self.logger.error("An error occurred...")
    self.error = error
}
```

**Empty Catch Blocks:**
- Occasionally used when error is ignored: `catch { }`
- Not recommended practice but used in `PreferencesViewModel.swift` line 23

**Retries:**
- Dedicated utility function `withRetries()` in `ControlFlow.swift` for retry logic
- Accepts generic return type and async/throwing closures

## Logging

**Framework:** `os.log.Logger` (native macOS/iOS logging)

**Initialization Pattern:**
```swift
private let logger: Logger = Logger(subsystem: "io.cubbit.CubbitDS3Sync", category: "ClassName")
```

**Subsystem/Category Naming:**
- Subsystem: `io.cubbit.CubbitDS3Sync` (consistent across app)
- Category: Class or module name (e.g., `"LoginViewModel"`, `"PreferencesViewModel"`, `"DS3SDK"`)

**Log Levels Used:**
- `.info`: Login successful, operation milestones (line 22 in `LoginViewModel.swift`)
- `.debug`: Detailed flow information, bucket loading (line 86 in `SyncAnchorSelectionViewModel.swift`)
- `.error`: Failures, exceptions (line 110 in `SyncAnchorSelectionViewModel.swift`)

**Logging Pattern:**
```swift
self.logger.info("Logging in to Cubbit DS3")
self.logger.debug("Loading buckets for project \(self.project.name)")
self.logger.error("An error occurred while loading buckets \(error)")
```

## Comments

**When to Comment:**
- MARK comments for section organization: `// MARK: - Main view`
- TODO comments for incomplete features: `// TODO: Hide tray menu when not logged in`
- NOTE comments for important context: `// NOTE: Just for display purposes`
- Inline comments for non-obvious logic (used sparingly)

**Docstring/Documentation Comments:**
- Used for public functions and complex operations
- Format: Three-slash `///` comments
- Example from `DS3DriveViewModel.swift`:
```swift
/// Sets up the observer for the drive to listen for notifications from the extension
private func setupObserver() { ... }
```

**Function Documentation Pattern:**
```swift
/// Retriieves all the projects for the current user.
/// - Returns: the list of projects for the current user.
func getRemoteProjects() async throws -> [Project]

/// Retries a block of code a given number of times before throwing an error
/// - Parameters:
///   - retries: the number of retries
///   - logger: optional logger
///   - block: the block of code to retry
/// - Throws: the error thrown by the block of code
/// - Returns: the result of the block of code
func withRetries<T>(...)
```

## Function Design

**Size:** Functions generally 5-50 lines (pragmatic, not overly granular)

**Parameters:**
- Named parameters for clarity: `selectIAMUser(withID id:)`, `setStartAtLogin(_:)`
- Use of keyword arguments: `withAuthentication:`, `withLogger:`, `withRetries(retries:withLogger:block:)`

**Return Values:**
- Explicit return types, including optionals: `-> URL?`, `-> String`, `-> [Project]`
- Async/throwing signature: `async throws -> T`

**Mutating Pattern:**
- Direct state mutation in Observable classes (Swift 6 observation model)
- No need for explicit `@State` bindings in class methods
- Example: `self.driveStatus = updateDriveStatusNotification.status`

## Module Design

**Exports:**
- Implicit public exports (no explicit access control shown, using default internal)
- Public models in `DS3Lib`: `Account`, `Project`, `DS3Drive`, `SyncAnchor`, etc.
- Internal manager classes exposed for environment injection

**Barrel Files:**
- No barrel file pattern (`index.swift` exports) used
- Each module/class in its own file

**Environment Injection Pattern:**
- Uses SwiftUI `@Environment` macro for dependency injection
- Example from `TrayDriveRowView.swift`:
```swift
@Environment(\.openWindow) var openWindow
@Environment(\.openURL) var openURL
@Environment(DS3DriveManager.self) var ds3DriveManager: DS3DriveManager
```

**Lazy Initialization:**
- Constants computed at startup: `DefaultSettings.appUUID`, `DefaultSettings.appVersion`
- Example:
```swift
static let appUUID = {
    if let userDefaults = UserDefaults(suiteName: DefaultSettings.appGroup) {
        if let uuid = userDefaults.string(forKey: ...) {
            return uuid
        } else {
            let uuid = UUID().uuidString
            userDefaults.set(uuid, forKey: ...)
            return uuid
        }
    } else {
        return UUID().uuidString
    }
}()
```

## Type Conformance and Markers

**Observable Pattern:**
- `@Observable` macro for view model classes (Swift 6)
- Replaces `ObservableObject` + `@Published`
- Example: `@Observable class PreferencesViewModel`

**Codable Conformance:**
- Standard `Codable` protocol for JSON encoding/decoding
- Custom `CodingKeys` enum for mapping to snake_case API responses
- Example from `Account.swift`:
```swift
struct Account: Codable {
    var firstName: String
    var lastName: String

    private enum CodingKeys: String, CodingKey {
        case firstName = "first_name"
        case lastName = "last_name"
        // ...
    }
}
```

---

*Convention analysis: 2026-03-11*
