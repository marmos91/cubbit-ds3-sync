import Foundation
import SwiftUI
import os.log

@Observable class LoginViewModel {
    var logger = Logger(subsystem: "io.cubbit.CubbitDS3Sync", category: "LoginViewModel")
    
    var loginError: Error?
    var need2FA: Bool = false
    var tfaError: Error?
    var isLoading: Bool = false
    
    /// Logs in the account with the provided credentials
    /// - Parameters:
    ///   - email: the account email
    ///   - password: the account password
    func login(withAuthentication authentication: DS3Authentication, email: String, password: String, withTfaToken tfaCode: String? = nil) async throws {
        self.isLoading = true
        defer { isLoading = false }
        
        do {
            self.logger.info("Logging in to Cubbit DS3")
            try await authentication.login(email: email, password: password, withTfaToken: tfaCode)
            try authentication.persist()
            self.logger.info("Login successful")
        }
        catch DS3AuthenticationError.missing2FA {
            self.logger.info("2FA is required")
            self.need2FA = true
        }
        catch {
            self.logger.error("An error occurred during login \(error)")
            self.loginError = error
        }
    }
}
