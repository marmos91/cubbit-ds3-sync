import DS3CoreFFI
import FileProvider
import Foundation

/// Errors specific to DS3 S3 operations after the Rust core swap (Phase 16 Plan 03).
///
/// Replaces Soto's `S3ErrorType` / `AWSErrorType` re-exports as the canonical
/// error type Swift adapters throw and FileProvider catches. Translation from
/// Rust's `Ds3Error` is owned by `DS3S3Error.translate(_:)` per D-13 (each
/// adapter owns its own translation table).
///
/// - Mapping to `NSFileProviderError`: see `toFileProviderError()`. The output
///   NSError domain + code is byte-identical to the legacy
///   `extension AWSErrorType.toFileProviderError()` it replaces — see
///   `FileProviderExtension+Errors.swift` history.
/// - Category flags (`isNotFound`, `isThrottling`, `isRecoverableAuthError`)
///   replace `DS3S3Client.isNotFoundError(_:)` / `isRecoverableAuthError(_:)`.
public enum DS3S3Error: Error, LocalizedError, Sendable, Equatable {
    case noSuchKey
    case noSuchBucket
    case accessDenied
    case invalidAccessKey
    case signatureDoesNotMatch
    case expiredToken
    case entityTooLarge
    case slowDown
    case serviceUnavailable
    case internalError
    case requestTimeout
    case missingUploadId
    case emptyFileData
    case missingETag
    case parseError
    case unableToOpenFile
    case thumbnailTooLarge(size: Int, limit: Int)
    case unknown(code: String?, message: String)

    public var errorDescription: String? {
        switch self {
        case .noSuchKey:
            NSLocalizedString("The specified key does not exist.", comment: "S3 NoSuchKey")
        case .noSuchBucket:
            NSLocalizedString("The specified bucket does not exist.", comment: "S3 NoSuchBucket")
        case .accessDenied:
            NSLocalizedString("Access denied to S3 resource.", comment: "S3 AccessDenied")
        case .invalidAccessKey:
            NSLocalizedString("The S3 access key is invalid.", comment: "S3 InvalidAccessKeyId")
        case .signatureDoesNotMatch:
            NSLocalizedString("The S3 request signature is invalid.", comment: "S3 SignatureDoesNotMatch")
        case .expiredToken:
            NSLocalizedString("The S3 session token has expired.", comment: "S3 ExpiredToken")
        case .entityTooLarge:
            NSLocalizedString("The upload exceeds the maximum allowed size.", comment: "S3 EntityTooLarge")
        case .slowDown:
            NSLocalizedString("The S3 service is throttling requests.", comment: "S3 SlowDown")
        case .serviceUnavailable:
            NSLocalizedString("The S3 service is temporarily unavailable.", comment: "S3 ServiceUnavailable")
        case .internalError:
            NSLocalizedString("The S3 service reported an internal error.", comment: "S3 InternalError")
        case .requestTimeout:
            NSLocalizedString("The S3 request timed out.", comment: "S3 RequestTimeout")
        case .missingUploadId:
            NSLocalizedString("The multipart upload ID is missing from the response.", comment: "Missing upload ID")
        case .emptyFileData:
            NSLocalizedString("The file data provided for upload is empty.", comment: "Empty file data")
        case .missingETag:
            NSLocalizedString("The ETag is missing from the S3 response.", comment: "Missing ETag")
        case .parseError:
            NSLocalizedString("Failed to parse an S3 response.", comment: "S3 parse error")
        case .unableToOpenFile:
            NSLocalizedString("Unable to open the local file for reading.", comment: "Unable to open file")
        case let .thumbnailTooLarge(size, limit):
            NSLocalizedString(
                "Thumbnail too large: \(size) bytes exceeds limit of \(limit) bytes.",
                comment: "Thumbnail size limit"
            )
        case let .unknown(code, message):
            if let code {
                NSLocalizedString("S3 error (code \(code)): \(message)", comment: "Unknown S3 error with code")
            } else {
                NSLocalizedString("S3 error: \(message)", comment: "Unknown S3 error")
            }
        }
    }
}

// MARK: - NSFileProviderError mapping (replaces extension AWSErrorType)

public extension DS3S3Error {
    /// Maps DS3S3Error to NSFileProviderError code for correct File Provider retry behavior.
    ///
    /// - `.notAuthenticated`: system throttles domain, shows re-auth UI, waits for `signalErrorResolved()`.
    /// - `.noSuchItem`: system removes item from working set.
    /// - `.insufficientQuota`: system shows quota UI.
    /// - `.serverUnreachable`: system retries with exponential backoff.
    /// - `.cannotSynchronize`: generic retryable error (used as catch-all so the system retries safely).
    ///
    /// Mapping mirrors the legacy `extension AWSErrorType.toFileProviderError()` byte-for-byte
    /// (Phase 13 D-21 / project memory: never throw custom error types past the extension boundary).
    func toFileProviderError() -> NSError {
        let code: NSFileProviderError.Code = switch self {
        case .invalidAccessKey, .signatureDoesNotMatch, .expiredToken:
            .notAuthenticated
        case .accessDenied:
            // Permission denial (not credential failure). cannotSynchronize avoids
            // domain-wide throttling; system will retry with backoff.
            .cannotSynchronize
        case .noSuchKey, .noSuchBucket:
            .noSuchItem
        case .entityTooLarge:
            .insufficientQuota
        case .slowDown, .serviceUnavailable, .internalError, .requestTimeout:
            .serverUnreachable
        default:
            .cannotSynchronize
        }
        return NSFileProviderError(code) as NSError
    }
}

// MARK: - AWS-style error code (source compatibility with legacy AWSErrorType)

public extension DS3S3Error {
    /// Returns the AWS-style S3 error code substring (e.g. "NoSuchKey", "AccessDenied").
    /// Returns an empty string for categories that don't correspond to a specific AWS code
    /// — keeps the source-compatible String type for legacy OSLog interpolation sites
    /// while still allowing `s3Error.errorCode == "NoSuchKey"` style comparisons.
    var errorCode: String {
        switch self {
        case .noSuchKey: "NoSuchKey"
        case .noSuchBucket: "NoSuchBucket"
        case .accessDenied: "AccessDenied"
        case .invalidAccessKey: "InvalidAccessKeyId"
        case .signatureDoesNotMatch: "SignatureDoesNotMatch"
        case .expiredToken: "ExpiredToken"
        case .entityTooLarge: "EntityTooLarge"
        case .slowDown: "SlowDown"
        case .serviceUnavailable: "ServiceUnavailable"
        case .internalError: "InternalError"
        case .requestTimeout: "RequestTimeout"
        case let .unknown(code, _): code ?? ""
        default: ""
        }
    }
}

// MARK: - Category flags (replace static helpers on DS3S3Client)

public extension DS3S3Error {
    /// True for keys/buckets that don't exist (S3 NoSuchKey / NoSuchBucket).
    var isNotFound: Bool {
        switch self {
        case .noSuchKey, .noSuchBucket: true
        default: false
        }
    }

    /// True if this error is a transient S3 throttling / unavailability signal
    /// the caller should back off on. Used by `S3Lib.listWithRetries` (Gap 28).
    var isThrottling: Bool {
        switch self {
        case .slowDown, .serviceUnavailable, .requestTimeout, .internalError: true
        default: false
        }
    }

    /// True for credential errors that the extension can recover from by
    /// reloading credentials from SharedData (InvalidAccessKeyId,
    /// SignatureDoesNotMatch, ExpiredToken).
    var isRecoverableAuthError: Bool {
        switch self {
        case .invalidAccessKey, .signatureDoesNotMatch, .expiredToken: true
        default: false
        }
    }
}

// MARK: - Rust Ds3Error → DS3S3Error translation (D-13)

extension DS3S3Error {
    /// Translates a Rust `Ds3Error` (UniFFI flat-error shape) into the
    /// corresponding `DS3S3Error` case. Code dispatch uses `ds3ErrorCode(message:)`
    /// from Plan 02; the S3-string fallback parses well-known AWS error codes
    /// out of the Display message (matches the AWS-error catch table that
    /// FileProviderExtension+Errors.swift used pre-swap).
    public static func translate(_ rust: Ds3Error) -> DS3S3Error {
        // Step 1: try numeric code from Rust Display string.
        let message = describe(rust)
        let code = ds3ErrorCode(message: message)
        switch code {
        case 2001: return .missingUploadId
        case 2002: return .emptyFileData
        case 2003: return .missingETag
        case 2004: return .parseError
        case 2005: return .unableToOpenFile
        case 3003: return parseS3StringError(message)
        default:
            // 1001-1099 (auth), 3001/3002/3004 (IO/HTTP/Auth-wrapper), or unknown.
            // Surface the numeric code so logs+UI can disambiguate.
            return .unknown(code: code >= 0 ? String(code) : nil, message: message)
        }
    }

    /// Extracts the message string from a `Ds3Error` case. UniFFI's flat_error
    /// emits each variant as `Case(message: String)` — the Display string of
    /// the original Rust error lives in `message`. Use this for both logging
    /// and the numeric-code lookup (`ds3ErrorCode(message:)`).
    private static func describe(_ rust: Ds3Error) -> String {
        switch rust {
        case let .InvalidUrl(message),
             let .ServerError(message),
             let .JsonError(message),
             let .Encoding(message),
             let .LoggedOut(message),
             let .TokenExpired(message),
             let .Missing2Fa(message),
             let .CookieError(message),
             let .MissingUploadId(message),
             let .EmptyFileData(message),
             let .MissingETag(message),
             let .ParseError(message),
             let .UnableToOpenFile(message),
             let .IoError(message),
             let .HttpError(message),
             let .S3Error(message),
             let .AuthError(message):
            message
        }
    }

    /// Parses a Rust `DS3Error::S3Error(String)` message for well-known AWS
    /// error code substrings. This is the fallback path for code 3003 — the
    /// Rust core wraps the raw `aws-sdk-s3` error string verbatim, so the
    /// substring match preserves the legacy AWS-error dispatch behavior.
    ///
    /// Future Rust work can promote these to a structured S3ErrorCode enum
    /// (RESEARCH §"DS3S3Error design", line 565); until then this is the
    /// canonical mapping (matches the deleted `extension AWSErrorType` switch).
    private static func parseS3StringError(_ message: String) -> DS3S3Error {
        // Order matters: the more specific codes must come first so e.g.
        // "NoSuchKey" doesn't accidentally win against an "AccessDenied"
        // substring (these are disjoint AWS codes so practical conflicts
        // are unlikely, but check anyway).
        if message.contains("NoSuchKey") { return .noSuchKey }
        if message.contains("NoSuchBucket") { return .noSuchBucket }
        if message.contains("InvalidAccessKeyId") { return .invalidAccessKey }
        if message.contains("SignatureDoesNotMatch") { return .signatureDoesNotMatch }
        if message.contains("ExpiredToken") { return .expiredToken }
        if message.contains("AccessDenied") { return .accessDenied }
        if message.contains("EntityTooLarge") { return .entityTooLarge }
        if message.contains("SlowDown") { return .slowDown }
        if message.contains("ServiceUnavailable") { return .serviceUnavailable }
        if message.contains("RequestTimeout") { return .requestTimeout }
        if message.contains("InternalError") { return .internalError }
        if message.contains("NotFound") { return .noSuchKey }
        return .unknown(code: nil, message: message)
    }
}
