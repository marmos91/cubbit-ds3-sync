import FileProvider
import Foundation
import SotoS3

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

extension S3ErrorType {
    var isNotFound: Bool {
        errorCode == "NoSuchKey" || errorCode == "NotFound"
    }

    /// Maps S3 error codes to NSFileProviderError codes for correct system retry behavior.
    /// - .notAuthenticated: system throttles domain, shows re-auth UI, waits for signalErrorResolved()
    /// - .noSuchItem: system removes item from working set
    /// - .insufficientQuota: system shows quota UI
    /// - .serverUnreachable: system retries with exponential backoff
    /// - .cannotSynchronize: generic retryable error
    func toFileProviderError() -> NSError {
        let code: NSFileProviderError.Code = switch self.errorCode {
        case "InvalidAccessKeyId", "SignatureDoesNotMatch", "ExpiredToken":
            .notAuthenticated
        case "AccessDenied":
            // Permission denial (not credential failure). Maps to cannotSynchronize rather than
            // notAuthenticated to avoid domain-wide throttling. System will retry with backoff.
            .cannotSynchronize
        case "NoSuchKey", "NoSuchBucket", "NotFound", "404 Not Found":
            .noSuchItem
        case "EntityTooLarge":
            .insufficientQuota
        case "SlowDown", "ServiceUnavailable", "InternalError", "RequestTimeout":
            .serverUnreachable
        default:
            .cannotSynchronize
        }
        return NSFileProviderError(code) as NSError
    }
}
