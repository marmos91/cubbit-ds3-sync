import XCTest
@testable import DS3Lib

/// Tests for Account.primaryEmail computed property.
final class AccountHelperTests: XCTestCase {

    // MARK: - Helper to build Account instances

    private func makeAccount(emails: [AccountEmail]) -> Account {
        Account(
            id: "test-id",
            firstName: "Test",
            lastName: "User",
            isInternal: false,
            isBanned: false,
            createdAt: "2025-01-01T00:00:00Z",
            maxAllowedProjects: 5,
            emails: emails,
            isTwoFactorEnabled: false,
            tenantId: "test-tenant",
            endpointGateway: "https://s3.example.com",
            authProvider: "local"
        )
    }

    private func makeEmail(_ email: String, isDefault: Bool) -> AccountEmail {
        AccountEmail(
            id: UUID().uuidString,
            email: email,
            isDefault: isDefault,
            createdAt: "2025-01-01T00:00:00Z",
            isVerified: true,
            tenantId: "test-tenant"
        )
    }

    // MARK: - Tests

    func testPrimaryEmailReturnsDefaultEmail() {
        let account = makeAccount(emails: [
            makeEmail("default@cubbit.io", isDefault: true)
        ])
        XCTAssertEqual(account.primaryEmail, "default@cubbit.io")
    }

    func testPrimaryEmailReturnsDefaultWhenMultipleEmails() {
        let account = makeAccount(emails: [
            makeEmail("other@cubbit.io", isDefault: false),
            makeEmail("default@cubbit.io", isDefault: true)
        ])
        XCTAssertEqual(account.primaryEmail, "default@cubbit.io")
    }

    func testPrimaryEmailReturnsFirstWhenNoDefault() {
        let account = makeAccount(emails: [
            makeEmail("first@cubbit.io", isDefault: false),
            makeEmail("second@cubbit.io", isDefault: false)
        ])
        XCTAssertEqual(account.primaryEmail, "first@cubbit.io")
    }

    func testPrimaryEmailReturnsUnknownWhenEmpty() {
        let account = makeAccount(emails: [])
        XCTAssertEqual(account.primaryEmail, "Unknown")
    }
}
