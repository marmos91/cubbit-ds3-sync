import Foundation
import SwiftUI
import os.log

@Observable class LoginViewModel {
    var loginError: Error?
    var isLoading: Bool = false
    var logger = Logger(subsystem: "io.cubbit.ds3sync", category: "LoginViewModel")
    
    /// Logs in the account with the provided credentials
    /// - Parameters:
    ///   - email: the account email
    ///   - password: the account password
    func login(withAuthentication authentication: DS3Authentication, email: String, password: String) async throws {
        self.isLoading = true
        defer { isLoading = false }
        
        do {
            self.logger.info("Logging in to Cubbit DS3")
            try await authentication.login(email: email, password: password)
            try authentication.persist()
            self.logger.info("Login successful")
        }
        catch {
            self.logger.error("An error occurred during login \(error)")
            self.loginError = error
        }
    }
}
