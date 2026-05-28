import DS3Lib
import FileProvider
import Foundation

enum FileProviderExtensionError: Error {
    case disabled
    case notImplemented
    case skipped
    case unableToOpenFile
    case s3ItemParseFailed
    case fatal
    case parseError
    case fileNotFound
    case uploadValidationFailed

    /// Maps extension errors to NSFileProviderError codes for correct system retry behavior.
    func toPresentableError() -> NSError {
        switch self {
        case .disabled:
            NSFileProviderError(.serverUnreachable) as NSError
        case .notImplemented:
            NSError(
                domain: NSCocoaErrorDomain,
                code: NSFeatureUnsupportedError,
                userInfo: [NSLocalizedDescriptionKey: "This feature is not implemented"]
            )
        case .skipped:
            NSError(
                domain: NSCocoaErrorDomain,
                code: NSUserCancelledError,
                userInfo: [NSLocalizedDescriptionKey: "This item was skipped"]
            )
        case .unableToOpenFile:
            NSFileProviderError(.cannotSynchronize) as NSError
        case .s3ItemParseFailed:
            NSFileProviderError(.cannotSynchronize) as NSError
        case .fatal:
            NSFileProviderError(.cannotSynchronize) as NSError
        case .parseError:
            NSFileProviderError(.cannotSynchronize) as NSError
        case .fileNotFound:
            NSFileProviderError(.noSuchItem) as NSError
        case .uploadValidationFailed:
            NSFileProviderError(.cannotSynchronize) as NSError
        }
    }
}

// MARK: - DS3S3Error → NSFileProviderError mapping

//
// The legacy `extension AWSErrorType` mapping moved onto `DS3S3Error` in DS3Lib
// (see DS3Lib/Sources/DS3Lib/DS3S3Error.swift). FileProvider catch blocks now
// catch `DS3S3Error` directly. The mapping is byte-identical:
// - .notAuthenticated for credential errors
// - .noSuchItem for missing keys
// - .insufficientQuota for size
// - .serverUnreachable for transient
// - .cannotSynchronize as catch-all
//
// Project memory rule (D-21): NEVER return custom error types to the File Provider
// system. Always call `.toFileProviderError()` (defined on DS3S3Error) at the
// extension boundary, then throw the resulting NSError.
