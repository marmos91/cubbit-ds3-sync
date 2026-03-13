import Foundation
import os.log
import DS3Lib

@Observable class LoginViewModel {
    var logger = Logger(subsystem: LogSubsystem.app, category: LogCategory.auth.rawValue)

    var loginError: Error?
    var need2FA: Bool = false
    var tfaError: Error?
    var isLoading: Bool = false

    /// Logs in the account with the provided credentials
    /// - Parameters:
    ///   - email: the account email
    ///   - password: the account password
    ///   - tfaCode: optional 2FA code
    ///   - tenant: optional tenant identifier for multi-tenant login
    ///   - coordinatorURL: optional coordinator URL override
    func login(withAuthentication authentication: DS3Authentication, email: String, password: String, withTfaToken tfaCode: String? = nil, tenant: String? = nil, coordinatorURL: String? = nil) async throws {
        self.isLoading = true
        defer { isLoading = false }

        do {
            self.logger.info("Logging in to Cubbit DS3")
            try await authentication.login(email: email, password: password, withTfaToken: tfaCode, tenant: tenant)
            try authentication.persist()

            // Persist tenant and coordinator URL after successful login
            let effectiveTenant = tenant ?? ""
            let effectiveCoordinatorURL = coordinatorURL ?? CubbitAPIURLs.defaultCoordinatorURL

            let sharedData = SharedData.default()
            try? sharedData.persistTenantName(effectiveTenant)
            try? sharedData.persistCoordinatorURL(effectiveCoordinatorURL)
            UserDefaults.standard.set(effectiveTenant, forKey: DefaultSettings.UserDefaultsKeys.lastTenant)
            UserDefaults.standard.set(effectiveCoordinatorURL, forKey: DefaultSettings.UserDefaultsKeys.lastCoordinatorURL)

            self.logger.info("Login successful")
        } catch DS3AuthenticationError.missing2FA {
            self.logger.info("2FA is required")
            self.need2FA = true
        } catch {
            self.logger.error("An error occurred during login \(error)")
            self.loginError = error
        }
    }
}
