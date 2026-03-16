import Foundation
import SotoS3
import FileProvider

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
            return NSFileProviderError(.serverUnreachable) as NSError
        case .notImplemented:
            return NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError, userInfo: [NSLocalizedDescriptionKey: "This feature is not implemented"])
        case .skipped:
            return NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError, userInfo: [NSLocalizedDescriptionKey: "This item was skipped"])
        case .unableToOpenFile:
            return NSFileProviderError(.cannotSynchronize) as NSError
        case .s3ItemParseFailed:
            return NSFileProviderError(.cannotSynchronize) as NSError
        case .fatal:
            return NSFileProviderError(.cannotSynchronize) as NSError
        case .parseError:
            return NSFileProviderError(.cannotSynchronize) as NSError
        case .fileNotFound:
            return NSFileProviderError(.noSuchItem) as NSError
        case .uploadValidationFailed:
            return NSFileProviderError(.cannotSynchronize) as NSError
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
        let code: NSFileProviderError.Code
        switch self.errorCode {
        case "InvalidAccessKeyId", "SignatureDoesNotMatch", "ExpiredToken":
            code = .notAuthenticated
        case "AccessDenied":
            // Permission denial (not credential failure). Maps to cannotSynchronize rather than
            // notAuthenticated to avoid domain-wide throttling. System will retry with backoff.
            code = .cannotSynchronize
        case "NoSuchKey", "NoSuchBucket", "NotFound", "404 Not Found":
            code = .noSuchItem
        case "EntityTooLarge":
            code = .insufficientQuota
        case "SlowDown", "ServiceUnavailable", "InternalError", "RequestTimeout":
            code = .serverUnreachable
        default:
            code = .cannotSynchronize
        }
        return NSFileProviderError(code) as NSError
    }
}
