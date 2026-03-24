@testable import Cubbit_DS3_Drive
@testable import DS3Lib
import XCTest

final class PreferencesViewModelTests: XCTestCase {
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
        isDefault: Bool = true
    ) -> AccountEmail {
        AccountEmail(
            id: "e-1", email: email, isDefault: isDefault,
            createdAt: "2023-01-01", isVerified: true, tenantId: "t-1"
        )
    }

    // MARK: - Format Full Name

    @MainActor
    func testFormatFullName() {
        let account = makeAccount(firstName: "Marco", lastName: "Moschettini")
        let vm = PreferencesViewModel(account: account)
        XCTAssertEqual(vm.formatFullName(), "Marco Moschettini")
    }

    @MainActor
    func testFormatFullNameEmptyLastName() {
        let account = makeAccount(firstName: "Marco", lastName: "")
        let vm = PreferencesViewModel(account: account)
        XCTAssertEqual(vm.formatFullName(), "Marco ")
    }

    // MARK: - Main Email

    @MainActor
    func testMainEmailFindsDefault() {
        let account = makeAccount(emails: [
            makeEmail(email: "secondary@cubbit.io", isDefault: false),
            makeEmail(email: "primary@cubbit.io", isDefault: true)
        ])
        let vm = PreferencesViewModel(account: account)
        XCTAssertEqual(vm.mainEmail(), "primary@cubbit.io")
    }

    @MainActor
    func testMainEmailNoDefault() {
        let account = makeAccount(emails: [
            makeEmail(email: "a@cubbit.io", isDefault: false)
        ])
        let vm = PreferencesViewModel(account: account)
        XCTAssertEqual(vm.mainEmail(), "")
    }

    @MainActor
    func testMainEmailEmpty() {
        let account = makeAccount(emails: [])
        let vm = PreferencesViewModel(account: account)
        XCTAssertEqual(vm.mainEmail(), "")
    }
}
