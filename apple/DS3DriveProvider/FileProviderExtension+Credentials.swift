import DS3Lib
@preconcurrency import FileProvider
import os.log

// MARK: - S3 Credential Reload

extension FileProviderExtension {
    /// Re-reads the API key from SharedData and reinitializes the S3 client if the key has changed.
    /// This handles the case where the main app has already fixed/rotated the credentials.
    /// - Returns: `true` if credentials were reloaded, `false` if unchanged or unavailable.
    @discardableResult
    private func reloadS3CredentialsIfNeeded() -> Bool {
        guard let drive = self.drive, let ds3Client = self.ds3Client else { return false }

        guard let changed = try? ds3Client.reloadDriveCredentials(drive: drive), changed else {
            return false
        }

        if let s3Lib = self.s3Lib {
            Task { try? await s3Lib.shutdown() }
        }

        // Update local references
        self.s3Client = ds3Client.driveS3Client
        self.endpoint = ds3Client.endpoint
        self.apiKeys = ds3Client.apiKeys

        // Rebuild S3Lib with new client
        if let client = ds3Client.driveS3Client, let nm = self.notificationManager {
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
        } catch {
            // Check all Soto error types (S3ErrorType, AWSClientError, AWSResponseError)
            // for recoverable auth codes. S3ErrorType only covers 9 S3-specific codes;
            // auth errors like InvalidAccessKeyId arrive as AWSResponseError.
            guard let errorCode = DS3S3Client.s3ErrorCode(from: error),
                  S3ErrorRecovery.isRecoverableAuthError(errorCode)
            else {
                throw error
            }

            // Try reloading one more time in case main app just fixed them
            if reloadS3CredentialsIfNeeded() {
                self.logger.info("Retrying after credential reload")
                return try await operation()
            }

            self.logger.error("S3 auth error: \(errorCode, privacy: .public). Notifying main app.")
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
