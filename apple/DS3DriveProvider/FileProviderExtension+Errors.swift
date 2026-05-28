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
// The S3 error → NSFileProviderError mapping lives on `DS3S3Error` in DS3Lib
// (see DS3Lib/Sources/DS3Lib/DS3S3Error.swift). Per project memory rule D-21,
// extension catch sites MUST call `.toFileProviderError()` before throwing —
// never throw custom error types past the extension boundary.
