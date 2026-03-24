import DS3Lib
@preconcurrency import FileProvider
import os.log
import SotoS3

// MARK: - S3 Credential Reload

extension FileProviderExtension {
    /// Re-reads the API key from SharedData and reinitializes the S3 client if the key has changed.
    /// This handles the case where the main app has already fixed/rotated the credentials.
    /// - Returns: `true` if credentials were reloaded, `false` if unchanged or unavailable.
    @discardableResult
    private func reloadS3CredentialsIfNeeded() -> Bool {
        guard let drive = self.drive else { return false }

        guard let freshKey = try? SharedData.default().loadDS3APIKeyFromPersistence(
            forUser: drive.syncAnchor.IAMUser,
            projectName: drive.syncAnchor.project.name
        ) else { return false }

        // Only reload if the key actually changed
        guard freshKey.apiKey != self.apiKeys?.apiKey, let secretKey = freshKey.secretKey else {
            return false
        }

        if let s3Lib = self.s3Lib {
            Task { try? await s3Lib.shutdown() }
        }

        let client = DS3S3Client(
            accessKeyId: freshKey.apiKey,
            secretAccessKey: secretKey,
            endpoint: self.endpoint
        )

        self.s3Client = client
        self.apiKeys = freshKey
        if let nm = self.notificationManager {
            self.s3Lib = S3Lib(withClient: client, withNotificationManager: nm)
        }

        self.logger.info("S3 credentials reloaded from SharedData")
        return true
    }

    // MARK: - S3 Auth Error Recovery

    /// Wraps an S3 operation with credential reload and retry on auth errors.
    /// On recoverable S3 auth errors (InvalidAccessKeyId, SignatureDoesNotMatch),
    /// attempts to reload credentials from SharedData (in case the main app already fixed them).
    /// If reload doesn't help, notifies the main app and returns `.notAuthenticated`.
    func withAPIKeyRecovery<T>(
        operation: @escaping () async throws -> T
    ) async throws -> T {
        // Check if main app has updated credentials since our last load
        _ = reloadS3CredentialsIfNeeded()

        do {
            return try await operation()
        } catch let s3Error as S3ErrorType where S3ErrorRecovery.isRecoverableAuthError(s3Error.errorCode) {
            // Try reloading one more time in case main app just fixed them
            if reloadS3CredentialsIfNeeded() {
                self.logger.info("Retrying after credential reload")
                return try await operation()
            }

            self.logger.error("S3 auth error: \(s3Error.errorCode, privacy: .public). Notifying main app.")
            if let nm = self.notificationManager {
                await nm.sendAuthFailureNotification(
                    domainId: self.domain.identifier.rawValue,
                    reason: "s3AuthError"
                )
            }
            throw NSFileProviderError(.notAuthenticated) as NSError
        }
    }
}
