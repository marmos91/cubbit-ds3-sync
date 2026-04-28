import SotoS3
import XCTest
@testable import DS3Lib

/// Phase 13.1-05 / D-06: pins behavior of `DS3S3Client.describeSotoError`.
///
/// The helper exists to defeat Foundation's `Error`-bridge static-dispatch
/// quirk: `(error as any Error).localizedDescription` on a Soto
/// `AWSErrorType` yields the opaque "SotoS3.S3ErrorType error 1" form,
/// while `String(describing: error)` dispatches through the concrete
/// type's `CustomStringConvertible` and yields, e.g.,
/// "noSuchKey: The specified key does not exist.". When an AWS error code
/// is recoverable via `s3ErrorCode(from:)`, the helper prefixes it for
/// grep-ability.
final class DescribeSotoErrorTests: XCTestCase {

    /// Negative path: a plain Foundation NSError has no AWS error code, so the
    /// helper must NOT add a prefix. The output equals `String(describing:)`.
    func testDescribesNonAWSErrorWithoutPrefix() {
        let err = NSError(domain: "TestDomain", code: 42, userInfo: nil)

        let result = DS3S3Client.describeSotoError(err)

        // No AWS code recovered → no "Code: " prefix.
        XCTAssertNil(DS3S3Client.s3ErrorCode(from: err),
                     "Precondition: NSError must not produce an AWS code")
        XCTAssertEqual(result, String(describing: err),
                       "Non-AWS errors must yield plain String(describing:) output")
    }

    /// Positive path: a real Soto `S3ErrorType.noSuchKey` MUST produce a
    /// readable single-prefix form. Soto's `CustomStringConvertible` already
    /// embeds the code (e.g. "NoSuchKey: ..."), so the helper must NOT
    /// double-prefix to "NoSuchKey: NoSuchKey: ...".
    func testDescribesAWSErrorWithCodePrefix() {
        let err: any Error = S3ErrorType.noSuchKey

        let result = DS3S3Client.describeSotoError(err)

        // AWS code is "NoSuchKey".
        XCTAssertEqual(DS3S3Client.s3ErrorCode(from: err), "NoSuchKey",
                       "Precondition: Soto S3ErrorType.noSuchKey must expose 'NoSuchKey'")
        // Single prefix only.
        XCTAssertTrue(result.hasPrefix("NoSuchKey:"),
                      "Result must carry the AWS code prefix once; got \(result)")
        XCTAssertFalse(result.hasPrefix("NoSuchKey: NoSuchKey"),
                       "Helper must not double-prefix; got \(result)")
        XCTAssertFalse(result.hasPrefix("NoSuchKey: noSuchKey"),
                       "Helper must not double-prefix even with case mismatch; got \(result)")
        // No double-prefix: result must equal the Soto description verbatim.
        XCTAssertEqual(result, String(describing: err),
                       "When Soto already embeds the code, helper must return its description as-is")
        // Must NOT be the Foundation-bridge artifact.
        XCTAssertFalse(result.contains("error 1"),
                       "Result must not be the Foundation-bridge 'error N' form")
    }

    /// A different Soto error code must round-trip through the same single-prefix
    /// path — guards against accidental hard-coding of "NoSuchKey".
    func testDescribesDifferentAWSErrorCode() {
        let err: any Error = S3ErrorType.noSuchBucket

        let result = DS3S3Client.describeSotoError(err)

        XCTAssertEqual(DS3S3Client.s3ErrorCode(from: err), "NoSuchBucket")
        XCTAssertTrue(result.hasPrefix("NoSuchBucket:"),
                      "Result must carry the AWS code prefix once; got \(result)")
        XCTAssertFalse(result.hasPrefix("NoSuchBucket: NoSuchBucket"),
                       "Helper must not double-prefix; got \(result)")
        XCTAssertEqual(result, String(describing: err),
                       "Helper must return Soto description as-is when code is already embedded")
    }
}
