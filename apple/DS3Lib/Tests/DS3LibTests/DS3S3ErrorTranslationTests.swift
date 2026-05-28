import DS3CoreFFI
@testable import DS3Lib
import FileProvider
import XCTest

/// Phase 16 Plan 03 / D-13, D-16: pins behavior of `DS3S3Error.translate(_:)`
/// (Rust `Ds3Error` → `DS3S3Error` enum dispatch) and `toFileProviderError()`
/// (DS3S3Error → NSFileProviderError NSError).
///
/// Translation must match `core/ds3-models/src/error.rs` `DS3Error::code()` table
/// exactly. NSFileProviderError mapping must be byte-identical with the legacy
/// `extension AWSErrorType.toFileProviderError()` in FileProviderExtension+Errors.swift.
final class DS3S3ErrorTranslationTests: XCTestCase {
    // MARK: - Numeric-code translation (Rust error variants → DS3S3Error)

    //
    // Each `Ds3Error` variant's `message` carries the Rust `Display` output
    // (UniFFI flat_error). `ds3_error_code(message:)` parses this. The fixtures
    // below mirror the exact Display strings from `core/ds3-models/src/error.rs`.

    func testTranslateMissingUploadId() {
        let err = Ds3Error.MissingUploadId(message: "Missing upload ID")
        XCTAssertEqual(DS3S3Error.translate(err), .missingUploadId)
    }

    func testTranslateEmptyFileData() {
        let err = Ds3Error.EmptyFileData(message: "Empty file data")
        XCTAssertEqual(DS3S3Error.translate(err), .emptyFileData)
    }

    func testTranslateMissingETag() {
        let err = Ds3Error.MissingETag(message: "Missing ETag")
        XCTAssertEqual(DS3S3Error.translate(err), .missingETag)
    }

    func testTranslateParseError() {
        let err = Ds3Error.ParseError(message: "Parse error")
        XCTAssertEqual(DS3S3Error.translate(err), .parseError)
    }

    func testTranslateUnableToOpenFile() {
        let err = Ds3Error.UnableToOpenFile(message: "Unable to open file")
        XCTAssertEqual(DS3S3Error.translate(err), .unableToOpenFile)
    }

    // MARK: - S3Error (code 3003) substring parsing

    func testTranslateS3ErrorNoSuchKey() {
        let err = Ds3Error.S3Error(message: "S3 error: NoSuchKey: object missing")
        XCTAssertEqual(DS3S3Error.translate(err), .noSuchKey)
    }

    func testTranslateS3ErrorNoSuchBucket() {
        let err = Ds3Error.S3Error(message: "S3 error: NoSuchBucket: bucket missing")
        XCTAssertEqual(DS3S3Error.translate(err), .noSuchBucket)
    }

    func testTranslateS3ErrorAccessDenied() {
        let err = Ds3Error.S3Error(message: "S3 error: AccessDenied: insufficient permissions")
        XCTAssertEqual(DS3S3Error.translate(err), .accessDenied)
    }

    func testTranslateS3ErrorInvalidAccessKeyId() {
        let err = Ds3Error.S3Error(message: "S3 error: InvalidAccessKeyId: bad key")
        XCTAssertEqual(DS3S3Error.translate(err), .invalidAccessKey)
    }

    func testTranslateS3ErrorSignatureDoesNotMatch() {
        let err = Ds3Error.S3Error(message: "S3 error: SignatureDoesNotMatch: signature mismatch")
        XCTAssertEqual(DS3S3Error.translate(err), .signatureDoesNotMatch)
    }

    func testTranslateS3ErrorExpiredToken() {
        let err = Ds3Error.S3Error(message: "S3 error: ExpiredToken: token expired")
        XCTAssertEqual(DS3S3Error.translate(err), .expiredToken)
    }

    func testTranslateS3ErrorEntityTooLarge() {
        let err = Ds3Error.S3Error(message: "S3 error: EntityTooLarge: too big")
        XCTAssertEqual(DS3S3Error.translate(err), .entityTooLarge)
    }

    func testTranslateS3ErrorSlowDown() {
        let err = Ds3Error.S3Error(message: "S3 error: SlowDown: throttled")
        XCTAssertEqual(DS3S3Error.translate(err), .slowDown)
    }

    func testTranslateS3ErrorServiceUnavailable() {
        let err = Ds3Error.S3Error(message: "S3 error: ServiceUnavailable: try again")
        XCTAssertEqual(DS3S3Error.translate(err), .serviceUnavailable)
    }

    func testTranslateS3ErrorRequestTimeout() {
        let err = Ds3Error.S3Error(message: "S3 error: RequestTimeout: timed out")
        XCTAssertEqual(DS3S3Error.translate(err), .requestTimeout)
    }

    func testTranslateS3ErrorInternalError() {
        let err = Ds3Error.S3Error(message: "S3 error: InternalError: server hiccup")
        XCTAssertEqual(DS3S3Error.translate(err), .internalError)
    }

    func testTranslateS3ErrorUnknown() {
        let err = Ds3Error.S3Error(message: "S3 error: WeirdNewS3ErrorCode: never seen")
        switch DS3S3Error.translate(err) {
        case let .unknown(code, _):
            XCTAssertNil(code)
        default:
            XCTFail("Expected .unknown, got \(DS3S3Error.translate(err))")
        }
    }

    // MARK: - Non-S3 Rust errors (auth/IO/HTTP/transport)

    func testTranslateLoggedOut() {
        let err = Ds3Error.LoggedOut(message: "Not logged in")
        switch DS3S3Error.translate(err) {
        case let .unknown(code, _):
            XCTAssertEqual(code, "1005")
        default:
            XCTFail("Expected .unknown(code:1005), got \(DS3S3Error.translate(err))")
        }
    }

    func testTranslateTokenExpired() {
        let err = Ds3Error.TokenExpired(message: "Token expired")
        switch DS3S3Error.translate(err) {
        case let .unknown(code, _):
            XCTAssertEqual(code, "1006")
        default:
            XCTFail("Expected .unknown(code:1006), got \(DS3S3Error.translate(err))")
        }
    }

    func testTranslateIoError() {
        let err = Ds3Error.IoError(message: "IO error: disk full")
        switch DS3S3Error.translate(err) {
        case let .unknown(code, _):
            XCTAssertEqual(code, "3001")
        default:
            XCTFail("Expected .unknown(code:3001), got \(DS3S3Error.translate(err))")
        }
    }

    func testTranslateHttpError() {
        let err = Ds3Error.HttpError(message: "HTTP error: connection reset")
        switch DS3S3Error.translate(err) {
        case let .unknown(code, _):
            XCTAssertEqual(code, "3002")
        default:
            XCTFail("Expected .unknown(code:3002), got \(DS3S3Error.translate(err))")
        }
    }

    // MARK: - toFileProviderError() — must match legacy AWSErrorType mapping

    private func code(_ fpCode: NSFileProviderError.Code) -> Int {
        (NSFileProviderError(fpCode) as NSError).code
    }

    func testToFileProviderErrorInvalidAccessKey() {
        let nsError = DS3S3Error.invalidAccessKey.toFileProviderError()
        XCTAssertEqual(nsError.domain, NSFileProviderErrorDomain)
        XCTAssertEqual(nsError.code, code(.notAuthenticated))
    }

    func testToFileProviderErrorSignatureDoesNotMatch() {
        let nsError = DS3S3Error.signatureDoesNotMatch.toFileProviderError()
        XCTAssertEqual(nsError.code, code(.notAuthenticated))
    }

    func testToFileProviderErrorExpiredToken() {
        let nsError = DS3S3Error.expiredToken.toFileProviderError()
        XCTAssertEqual(nsError.code, code(.notAuthenticated))
    }

    func testToFileProviderErrorAccessDenied() {
        let nsError = DS3S3Error.accessDenied.toFileProviderError()
        XCTAssertEqual(nsError.code, code(.cannotSynchronize))
    }

    func testToFileProviderErrorNoSuchKey() {
        let nsError = DS3S3Error.noSuchKey.toFileProviderError()
        XCTAssertEqual(nsError.code, code(.noSuchItem))
    }

    func testToFileProviderErrorNoSuchBucket() {
        let nsError = DS3S3Error.noSuchBucket.toFileProviderError()
        XCTAssertEqual(nsError.code, code(.noSuchItem))
    }

    func testToFileProviderErrorEntityTooLarge() {
        let nsError = DS3S3Error.entityTooLarge.toFileProviderError()
        XCTAssertEqual(nsError.code, code(.insufficientQuota))
    }

    func testToFileProviderErrorSlowDown() {
        let nsError = DS3S3Error.slowDown.toFileProviderError()
        XCTAssertEqual(nsError.code, code(.serverUnreachable))
    }

    func testToFileProviderErrorServiceUnavailable() {
        let nsError = DS3S3Error.serviceUnavailable.toFileProviderError()
        XCTAssertEqual(nsError.code, code(.serverUnreachable))
    }

    func testToFileProviderErrorInternalError() {
        let nsError = DS3S3Error.internalError.toFileProviderError()
        XCTAssertEqual(nsError.code, code(.serverUnreachable))
    }

    func testToFileProviderErrorRequestTimeout() {
        let nsError = DS3S3Error.requestTimeout.toFileProviderError()
        XCTAssertEqual(nsError.code, code(.serverUnreachable))
    }

    func testToFileProviderErrorUnknownDefaults() {
        let nsError = DS3S3Error.unknown(code: "Whatever", message: "x").toFileProviderError()
        XCTAssertEqual(nsError.code, code(.cannotSynchronize))
    }

    func testToFileProviderErrorMissingUploadIdDefaults() {
        let nsError = DS3S3Error.missingUploadId.toFileProviderError()
        XCTAssertEqual(nsError.code, code(.cannotSynchronize))
    }

    // MARK: - Category flags

    func testIsNotFound() {
        XCTAssertTrue(DS3S3Error.noSuchKey.isNotFound)
        XCTAssertTrue(DS3S3Error.noSuchBucket.isNotFound)
        XCTAssertFalse(DS3S3Error.accessDenied.isNotFound)
        XCTAssertFalse(DS3S3Error.slowDown.isNotFound)
    }

    func testIsThrottling() {
        XCTAssertTrue(DS3S3Error.slowDown.isThrottling)
        XCTAssertTrue(DS3S3Error.serviceUnavailable.isThrottling)
        XCTAssertTrue(DS3S3Error.internalError.isThrottling)
        XCTAssertTrue(DS3S3Error.requestTimeout.isThrottling)
        XCTAssertFalse(DS3S3Error.noSuchKey.isThrottling)
        XCTAssertFalse(DS3S3Error.accessDenied.isThrottling)
    }

    func testIsRecoverableAuthError() {
        XCTAssertTrue(DS3S3Error.invalidAccessKey.isRecoverableAuthError)
        XCTAssertTrue(DS3S3Error.signatureDoesNotMatch.isRecoverableAuthError)
        XCTAssertTrue(DS3S3Error.expiredToken.isRecoverableAuthError)
        XCTAssertFalse(DS3S3Error.accessDenied.isRecoverableAuthError)
        XCTAssertFalse(DS3S3Error.noSuchKey.isRecoverableAuthError)
    }

    // MARK: - errorDescription is non-nil for every case

    func testErrorDescriptionsAreNonEmpty() {
        let cases: [DS3S3Error] = [
            .noSuchKey, .noSuchBucket, .accessDenied, .invalidAccessKey,
            .signatureDoesNotMatch, .expiredToken, .entityTooLarge, .slowDown,
            .serviceUnavailable, .internalError, .requestTimeout, .missingUploadId,
            .emptyFileData, .missingETag, .parseError, .unableToOpenFile,
            .thumbnailTooLarge(size: 1, limit: 0),
            .unknown(code: nil, message: "x")
        ]
        for errorCase in cases {
            XCTAssertNotNil(errorCase.errorDescription, "Missing description for \(errorCase)")
            XCTAssertFalse(
                errorCase.errorDescription?.isEmpty ?? true,
                "Empty description for \(errorCase)"
            )
        }
    }
}
