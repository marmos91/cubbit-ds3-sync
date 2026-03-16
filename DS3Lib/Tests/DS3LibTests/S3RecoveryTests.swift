import XCTest
@testable import DS3Lib

final class S3RecoveryTests: XCTestCase {
    // MARK: - isRecoverableAuthError returns true

    func testInvalidAccessKeyIdIsRecoverable() {
        XCTAssertTrue(S3ErrorRecovery.isRecoverableAuthError("InvalidAccessKeyId"))
    }

    func testSignatureDoesNotMatchIsRecoverable() {
        XCTAssertTrue(S3ErrorRecovery.isRecoverableAuthError("SignatureDoesNotMatch"))
    }

    // MARK: - isRecoverableAuthError returns false

    func testAccessDeniedIsNotRecoverable() {
        XCTAssertFalse(S3ErrorRecovery.isRecoverableAuthError("AccessDenied"))
    }

    func testNoSuchKeyIsNotRecoverable() {
        XCTAssertFalse(S3ErrorRecovery.isRecoverableAuthError("NoSuchKey"))
    }

    func testNoSuchBucketIsNotRecoverable() {
        XCTAssertFalse(S3ErrorRecovery.isRecoverableAuthError("NoSuchBucket"))
    }

    func testEmptyStringIsNotRecoverable() {
        XCTAssertFalse(S3ErrorRecovery.isRecoverableAuthError(""))
    }

    // MARK: - recoverableErrorCodes set

    func testRecoverableErrorCodesContainsExactlyTwoCodes() {
        XCTAssertEqual(S3ErrorRecovery.recoverableErrorCodes.count, 2)
    }

    func testRecoverableErrorCodesContainsExpectedCodes() {
        let expected: Set<String> = ["InvalidAccessKeyId", "SignatureDoesNotMatch"]
        XCTAssertEqual(S3ErrorRecovery.recoverableErrorCodes, expected)
    }
}
