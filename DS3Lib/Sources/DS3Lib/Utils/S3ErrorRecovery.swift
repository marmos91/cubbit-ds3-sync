import Foundation

/// Utility for detecting recoverable S3 authentication errors.
/// Used by the File Provider extension to trigger API key self-healing.
public enum S3ErrorRecovery {
    /// S3 error codes that indicate an expired or invalid API key, recoverable by key recreation.
    public static let recoverableErrorCodes: Set<String> = [
        "AccessDenied",
        "InvalidAccessKeyId",
        "SignatureDoesNotMatch"
    ]

    /// Returns true if the given S3 error code indicates a recoverable auth error
    /// that can be fixed by recreating the API key.
    public static func isRecoverableAuthError(_ errorCode: String) -> Bool {
        recoverableErrorCodes.contains(errorCode)
    }
}
