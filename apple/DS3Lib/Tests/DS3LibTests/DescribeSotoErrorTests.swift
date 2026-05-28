import DS3CoreFFI
@testable import DS3Lib
import XCTest

/// Phase 13.1-05 / D-06: pins behavior of `DS3S3Client.describeS3Error`
/// (formerly `describeSotoError`).
///
/// The helper exists to defeat Foundation's `Error`-bridge static-dispatch
/// quirk: `(error as any Error).localizedDescription` on a typed error
/// often yields the opaque "Module.Type error N" form. `String(describing:)`
/// dispatches through the concrete type's `CustomStringConvertible` and
/// yields readable text. For `DS3S3Error` cases, the helper prefixes the
/// AWS-style error code for grep-ability.
final class DescribeSotoErrorTests: XCTestCase {
    /// Negative path: a plain Foundation NSError has no S3 error code, so
    /// the helper must NOT add a prefix. Output equals `String(describing:)`.
    func testDescribesNonAWSErrorWithoutPrefix() {
        let err = NSError(domain: "TestDomain", code: 42, userInfo: nil)

        let result = DS3S3Client.describeS3Error(err)

        XCTAssertNil(
            DS3S3Client.s3ErrorCode(from: err),
            "Precondition: NSError must not produce an S3 code"
        )
        XCTAssertEqual(
            result,
            String(describing: err),
            "Non-S3 errors must yield plain String(describing:) output"
        )
    }

    /// Positive path: `DS3S3Error.noSuchKey` MUST produce a readable form
    /// prefixed with its AWS-style code.
    func testDescribesAWSErrorWithCodePrefix() {
        let err: any Error = DS3S3Error.noSuchKey

        let result = DS3S3Client.describeS3Error(err)

        XCTAssertEqual(
            DS3S3Client.s3ErrorCode(from: err),
            "NoSuchKey",
            "Precondition: DS3S3Error.noSuchKey must expose 'NoSuchKey'"
        )
        XCTAssertTrue(
            result.hasPrefix("NoSuchKey:"),
            "Result must carry the AWS code prefix; got \(result)"
        )
    }

    /// A different DS3S3Error case round-trips through the same single-prefix
    /// path — guards against accidental hard-coding of "NoSuchKey".
    func testDescribesDifferentAWSErrorCode() {
        let err: any Error = DS3S3Error.noSuchBucket

        let result = DS3S3Client.describeS3Error(err)

        XCTAssertEqual(DS3S3Client.s3ErrorCode(from: err), "NoSuchBucket")
        XCTAssertTrue(
            result.hasPrefix("NoSuchBucket:"),
            "Result must carry the AWS code prefix; got \(result)"
        )
    }

    /// `describeSotoError` (the legacy alias) must produce the same output as
    /// `describeS3Error` — Plan 03 keeps the alias for source compatibility.
    func testLegacyAliasMatchesNewHelper() {
        let err: any Error = DS3S3Error.accessDenied
        XCTAssertEqual(
            DS3S3Client.describeS3Error(err),
            DS3S3Client.describeSotoError(err),
            "describeSotoError must remain a working alias of describeS3Error"
        )
    }
}
