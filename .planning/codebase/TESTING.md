# Testing Patterns

**Analysis Date:** 2026-03-11

## Test Framework Status

**Runner:**
- No dedicated test framework found in codebase
- No XCTest configuration detected
- No test targets in Xcode project

**Assertion Library:**
- Not applicable (no testing framework)

**Run Commands:**
```bash
# Testing infrastructure not present in this codebase
# To add testing:
xcode-build test                    # Would run tests once configured
```

## Test File Organization

**Location:**
- No test files present in repository
- No `Tests/` or `*Tests` directories found
- No `*.swift` files in test targets

**Naming Convention (if tests were added):**
- Would follow Swift testing standard: `*Tests.swift` suffix
- Example: `PreferencesViewModelTests.swift`, `DS3SDKTests.swift`

**Structure (Recommended):**
```
CubbitDS3Sync/
├── CubbitDS3Sync/         # Main app target (no tests)
├── Provider/              # File Provider extension (no tests)
└── DS3Lib/                # Library (no tests)

Tests/ (if implemented)
├── CubbitDS3SyncTests/
├── ProviderTests/
└── DS3LibTests/
```

## Test Structure - Reference Patterns

**Would Likely Use:**
- XCTest framework (standard for Swift)
- Test case classes extending `XCTestCase`
- Async test methods with `async` keyword

**Recommended Setup Pattern:**
```swift
import XCTest
@testable import CubbitDS3Sync

class PreferencesViewModelTests: XCTestCase {
    var sut: PreferencesViewModel!
    var mockAccount: Account!

    override func setUp() {
        super.setUp()
        // Initialize test fixtures
    }

    override func tearDown() {
        sut = nil
        super.tearDown()
    }

    func testDisconnectAccountRemovesPersistenceData() async throws {
        // Test implementation
    }
}
```

## Mocking - Current Gaps

**Framework:** No mocking framework present
- Would use `@testable import` for internal access
- Could use protocol-based mocking or manual stubs

**Recommended Patterns (Not Yet Implemented):**
```swift
// Protocol-based mocking approach
protocol DS3SDKProtocol {
    func getRemoteProjects() async throws -> [Project]
}

class MockDS3SDK: DS3SDKProtocol {
    var getRemoteProjectsStub: [Project] = []

    func getRemoteProjects() async throws -> [Project] {
        return getRemoteProjectsStub
    }
}
```

**What Should Be Mocked:**
- Network calls (`DS3SDK.getRemoteProjects()`)
- File system operations (FileProvider interactions)
- User defaults and persistence
- External authentication flows

**What Should NOT Be Mocked:**
- Data model encoding/decoding (test with real Codable)
- Core business logic (error handling, state transitions)
- Observable value changes

## Fixtures and Factories

**Test Data (Currently Used in Previews):**
- `#Preview` blocks use actual model initialization
- Example from `TrayDriveRowView.swift`:
```swift
#Preview {
    TrayDriveRowView(
        driveViewModel: DS3DriveViewModel(
            drive: DS3Drive(
                id: UUID(),
                name: "My drive",
                syncAnchor: SyncAnchor(...)
            )
        )
    )
}
```

**Recommended Fixture Location (Not Implemented):**
- Would create: `Tests/Fixtures/` or `Tests/Helpers/`
- Factory pattern for common test objects

**Factory Pattern (Recommended):**
```swift
// Tests/Fixtures/AccountFactory.swift
struct AccountFactory {
    static func makeAccount(
        id: String = "test-id",
        firstName: String = "Test",
        lastName: String = "User"
    ) -> Account {
        Account(
            id: id,
            firstName: firstName,
            lastName: lastName,
            isInternal: false,
            isBanned: false,
            createdAt: "2024-01-01T00:00:00Z",
            emails: [
                AccountEmail(
                    id: "email-id",
                    email: "test@example.com",
                    isDefault: true,
                    createdAt: "2024-01-01T00:00:00Z",
                    isVerified: true,
                    tenantId: "tenant-id"
                )
            ],
            // ...
        )
    }
}
```

## Coverage

**Requirements:** Not enforced (no CI/testing infrastructure)

**View Coverage:**
- Currently absent (would need to be implemented)
- Recommended approach: Start with 70%+ coverage on critical paths

**Module to Prioritize Testing:**
1. `DS3SDK` - API communication logic
2. `DS3Authentication` - Auth flows and token management
3. `SharedData` - Persistence layer
4. `SyncAnchorSelectionViewModel` - Complex state management
5. `DS3DriveManager` - Drive lifecycle management

## Test Types

**Unit Tests (Recommended Focus):**
- Scope: Individual classes in isolation (ViewModels, SDKs, utilities)
- Approach: Mock external dependencies
- Examples to create:
  - `PreferencesViewModelTests` - Format functions, disconnect logic
  - `SyncAnchorSelectionViewModelTests` - Bucket/folder selection state
  - `DS3SDKTests` - API request formatting, error handling
  - `ControlFlowTests` - Retry logic

**Integration Tests (Recommended Secondary Focus):**
- Scope: Multiple components working together
- Approach: Real file system and UserDefaults
- Examples:
  - Persistence flow: `DS3Authentication` → `SharedData` → UserDefaults
  - Auth flow: Login → Token storage → Drive loading
  - Could use in-memory UserDefaults for testing

**E2E Tests:**
- Framework: Not used (would use XCTest with UI automation if needed)
- Status: Not applicable for current architecture

## Common Patterns - Async Testing

**Current Async Usage:**
- ViewModels use `async`/`await` extensively
- Example from `LoginViewModel.swift` line 17:
```swift
func login(withAuthentication authentication: DS3Authentication, email: String, password: String, withTfaToken tfaCode: String? = nil) async throws
```

**Testing Async Pattern (Not Yet Implemented):**
```swift
func testLoginWithValidCredentials() async throws {
    // Arrange
    let sut = LoginViewModel()
    let mockAuth = MockDS3Authentication()

    // Act
    try await sut.login(
        withAuthentication: mockAuth,
        email: "test@example.com",
        password: "password"
    )

    // Assert
    XCTAssertTrue(sut.isLoading == false)
    XCTAssertNil(sut.loginError)
}
```

**Swift Concurrency Testing:**
- Use `async` test methods (available in Swift 5.8+)
- Await operations directly without DispatchQueue
- Use `MainActor` for UI state assertions when needed

## Common Patterns - Error Testing

**Error Type Coverage:**
- Errors are custom enums conforming to `LocalizedError`
- Example types to test: `SyncAnchorSelectionError`, `DS3AuthenticationError`, `DS3SDKError`

**Testing Error Cases (Recommended Pattern):**
```swift
func testSelectBucketWhenNoBucketsThrowsError() async throws {
    // Arrange
    var sut = SyncAnchorSelectionViewModel(
        project: makeProject(),
        authentication: MockDS3Authentication(),
        buckets: [] // Empty buckets
    )

    // Act & Assert
    XCTAssertThrowsError(
        try await sut.selectBucket(withName: "nonexistent")
    ) { error in
        XCTAssertEqual(error as? SyncAnchorSelectionError, .noBucketSelected)
    }
}
```

**Error Description Testing:**
```swift
func testErrorDescriptionIsLocalized() {
    let error = SyncAnchorSelectionError.missingBuckets

    XCTAssertNotNil(error.errorDescription)
    XCTAssertFalse(error.errorDescription!.isEmpty)
}
```

## Testing Gaps and Needs

**Critical Areas Missing Tests:**
1. `SharedData` persistence methods (encode/decode cycles)
2. `DS3DriveManager` drive lifecycle (add, remove, list)
3. `PreferencesViewModel` disconnect flow
4. `LoginViewModel` error handling and 2FA flow
5. Notification handling in `DS3DriveViewModel`

**Observable State Testing:**
- Would need to test state transitions in `@Observable` classes
- Verify property changes trigger appropriate side effects

**Preview-Based Testing:**
- Current app uses SwiftUI previews for visual testing
- No automated assertion of preview states
- Could formalize preview data into test fixtures

---

*Testing analysis: 2026-03-11*

## Summary

This codebase has **no automated testing infrastructure**. The app is pure SwiftUI without test targets. Adding comprehensive test coverage should be a priority for:
- ViewModels (especially async operations)
- Persistence layer (SharedData)
- Authentication flows
- API communication (DS3SDK)

Start with unit tests for `DS3SDK`, `DS3Authentication`, and key ViewModels before attempting integration tests.
