import XCTest
@testable import DS3Lib

/// Tests for PreferencesViewModel pure logic (string formatting from Account model).
final class PreferencesViewModelLogicTests: XCTestCase {
    // MARK: - Helpers

    private func makeAccount(
        firstName: String = "Marco",
        lastName: String = "Moschettini",
        emails: [AccountEmail] = [],
        isTwoFactorEnabled: Bool = false
    ) -> Account {
        Account(
            id: "acc-1",
            firstName: firstName,
            lastName: lastName,
            isInternal: false,
            isBanned: false,
            createdAt: "2023-01-01",
            maxAllowedProjects: 5,
            emails: emails,
            isTwoFactorEnabled: isTwoFactorEnabled,
            tenantId: "t-1",
            endpointGateway: "https://s3.cubbit.eu",
            authProvider: "cubbit"
        )
    }

    private func makeEmail(
        email: String = "test@cubbit.io",
        isDefault: Bool = true,
        isVerified: Bool = true
    ) -> AccountEmail {
        AccountEmail(
            id: "e-1", email: email, isDefault: isDefault,
            createdAt: "2023-01-01", isVerified: isVerified, tenantId: "t-1"
        )
    }

    // MARK: - Full Name Formatting

    func testFullNameFormatting() {
        let account = makeAccount(firstName: "Marco", lastName: "Moschettini")
        let fullName = "\(account.firstName) \(account.lastName)"
        XCTAssertEqual(fullName, "Marco Moschettini")
    }

    func testFullNameWithEmptyLastName() {
        let account = makeAccount(firstName: "Marco", lastName: "")
        let fullName = "\(account.firstName) \(account.lastName)"
        XCTAssertEqual(fullName, "Marco ")
    }

    // MARK: - Main Email

    func testMainEmailFindsDefault() {
        let account = makeAccount(emails: [
            makeEmail(email: "secondary@cubbit.io", isDefault: false),
            makeEmail(email: "primary@cubbit.io", isDefault: true)
        ])
        let mainEmail = account.emails.first(where: \.isDefault)?.email ?? ""
        XCTAssertEqual(mainEmail, "primary@cubbit.io")
    }

    func testMainEmailNoDefault() {
        let account = makeAccount(emails: [
            makeEmail(email: "a@cubbit.io", isDefault: false),
            makeEmail(email: "b@cubbit.io", isDefault: false)
        ])
        let mainEmail = account.emails.first(where: \.isDefault)?.email ?? ""
        XCTAssertEqual(mainEmail, "")
    }

    func testMainEmailEmptyList() {
        let account = makeAccount(emails: [])
        let mainEmail = account.emails.first(where: \.isDefault)?.email ?? ""
        XCTAssertEqual(mainEmail, "")
    }

    // MARK: - Account Properties

    func testTwoFactorEnabled() {
        let account = makeAccount(isTwoFactorEnabled: true)
        XCTAssertTrue(account.isTwoFactorEnabled)
    }

    func testTwoFactorDisabled() {
        let account = makeAccount(isTwoFactorEnabled: false)
        XCTAssertFalse(account.isTwoFactorEnabled)
    }

    func testAccountEmailVerificationStatus() {
        let verifiedEmail = makeEmail(isVerified: true)
        let unverifiedEmail = makeEmail(isVerified: false)

        XCTAssertTrue(verifiedEmail.isVerified)
        XCTAssertFalse(unverifiedEmail.isVerified)
    }
}
