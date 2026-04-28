@testable import DS3Lib
import FileProvider
import Foundation
import SotoCore
import XCTest

/// Verifies the `mapThumbnailFetchError` helper maps every below-the-seam
/// error to one of the THREE allowed `NSFileProviderError` codes
/// (Phase 13 D-13). Crucially, Test 13 asserts NO custom error domain
/// ever escapes this chokepoint.
final class FetchThumbnailsErrorMappingTests: XCTestCase {
    // MARK: - Test 7 — 404 → .noSuchItem

    /// NoSuchKey errors should NOT reach the mapper in production
    /// (`getThumbnailBytes` swallows 404 and returns nil, which the consume
    /// path translates to `.noSuchItem` itself). However, if a future call
    /// site routes a `NoSuchKey` through here, the mapper still treats it
    /// as a missing-resource condition and returns `.noSuchItem`.
    func test404MapsToNoSuchItem() async {
        // We exercise this by asserting that `consumeThumbnail` returns
        // .noSuchItem on the nil-data path (which IS the 404 path in
        // production via `getThumbnailBytes`'s silent contract).
        let drive = ProviderTestFixtures.makeDrive()
        let identifier = NSFileProviderItemIdentifier("prefix/photo.jpg")
        let recorder = ResultRecorder()

        let fetchBytes: ThumbnailByteFetcher = { _, _ in nil }
        let markPending: ThumbnailPendingMarker = { _, _ in
            // No-op: this test only inspects the error path; pending writes are
            // verified in FetchThumbnailsTests.testFetchThumbnailsRasterMissReturnsNoSuchItemAndMarksPending.
        }

        await consumeThumbnail(
            identifier: identifier,
            drive: drive,
            fetchBytes: fetchBytes,
            markPending: markPending,
            perItemHandler: { id, data, error in
                Task { await recorder.record(id: id, data: data, error: error) }
            }
        )
        try? await Task.sleep(nanoseconds: 30_000_000)

        let nsError = await recorder.results.first?.error as NSError?
        XCTAssertEqual(nsError?.domain, NSFileProviderErrorDomain)
        XCTAssertEqual(nsError?.code, NSFileProviderError(.noSuchItem).code.rawValue)
    }

    // MARK: - Test 8 — 5xx (InternalError) → .serverUnreachable

    func test5xxMapsToServerUnreachable() {
        let error = makeS3Error(code: "InternalError", message: "Server error")
        let mapped = mapThumbnailFetchError(error)
        XCTAssertEqual(mapped.domain, NSFileProviderErrorDomain)
        XCTAssertEqual(mapped.code, NSFileProviderError(.serverUnreachable).code.rawValue)
    }

    // MARK: - Test 9 — SlowDown → .serverUnreachable (NO inline retry per D-14)

    func testSlowDownMapsToServerUnreachable() {
        let error = makeS3Error(code: "SlowDown", message: "Reduce request rate")
        let mapped = mapThumbnailFetchError(error)
        XCTAssertEqual(mapped.domain, NSFileProviderErrorDomain)
        XCTAssertEqual(mapped.code, NSFileProviderError(.serverUnreachable).code.rawValue)
    }

    // MARK: - Test 10 — URLError network → .serverUnreachable

    func testNetworkErrorMapsToServerUnreachable() {
        let error = URLError(.notConnectedToInternet)
        let mapped = mapThumbnailFetchError(error)
        XCTAssertEqual(mapped.domain, NSFileProviderErrorDomain)
        XCTAssertEqual(mapped.code, NSFileProviderError(.serverUnreachable).code.rawValue)
    }

    // MARK: - Test 11 — Recoverable auth error → .cannotSynchronize

    func testAuthErrorMapsToCannotSynchronize() {
        // S3ErrorRecovery.recoverableErrorCodes = {InvalidAccessKeyId,
        // SignatureDoesNotMatch, ExpiredToken}. Use one of those.
        let error = makeS3Error(code: "InvalidAccessKeyId", message: "Bad key")
        XCTAssertTrue(
            DS3S3Client.isRecoverableAuthError(error),
            "Sanity: precondition for the auth path of the mapper"
        )
        let mapped = mapThumbnailFetchError(error)
        XCTAssertEqual(mapped.domain, NSFileProviderErrorDomain)
        XCTAssertEqual(mapped.code, NSFileProviderError(.cannotSynchronize).code.rawValue)
    }

    // MARK: - Test 12 — Unknown error → .cannotSynchronize

    func testUnknownErrorMapsToCannotSynchronize() {
        let error = NSError(domain: "io.example.weirdcustom", code: 42, userInfo: nil)
        let mapped = mapThumbnailFetchError(error)
        XCTAssertEqual(mapped.domain, NSFileProviderErrorDomain)
        XCTAssertEqual(mapped.code, NSFileProviderError(.cannotSynchronize).code.rawValue)
    }

    // MARK: - Test 12b — AccessDenied → .notAuthenticated

    /// `AccessDenied` denotes a bucket-policy / IAM denial that credential
    /// rotation can't fix. It MUST map to `.notAuthenticated` so the user sees
    /// the auth-boundary UX rather than retrying indefinitely against
    /// `.cannotSynchronize`.
    func testAccessDeniedMapsToNotAuthenticated() {
        let error = makeS3Error(code: "AccessDenied", message: "Forbidden")
        let mapped = mapThumbnailFetchError(error)
        XCTAssertEqual(mapped.domain, NSFileProviderErrorDomain)
        XCTAssertEqual(
            mapped.code, NSFileProviderError(.notAuthenticated).code.rawValue,
            "AccessDenied must map to .notAuthenticated (bucket-policy denial)"
        )
    }

    /// Same routing for `AllAccessDisabled` (account-level shutdown).
    func testAllAccessDisabledMapsToNotAuthenticated() {
        let error = makeS3Error(code: "AllAccessDisabled", message: "Account disabled")
        let mapped = mapThumbnailFetchError(error)
        XCTAssertEqual(mapped.domain, NSFileProviderErrorDomain)
        XCTAssertEqual(
            mapped.code, NSFileProviderError(.notAuthenticated).code.rawValue
        )
    }

    // MARK: - Test 13 — No custom error domain ever escapes (CRITICAL)

    /// CLAUDE.md mandate: every error crossing the File Provider boundary MUST
    /// have `domain == NSFileProviderErrorDomain` or
    /// `domain == NSCocoaErrorDomain`. This test sweeps every kind of error
    /// the mapper could see in production and asserts the invariant for each.
    func testNoCustomErrorDomainEverEscapes() {
        let allowedDomains: Set<String> = [NSFileProviderErrorDomain, NSCocoaErrorDomain]

        let errorCases: [(label: String, error: Error)] = [
            ("S3 InternalError", makeS3Error(code: "InternalError", message: "5xx")),
            ("S3 SlowDown", makeS3Error(code: "SlowDown", message: "throttle")),
            ("S3 ServiceUnavailable", makeS3Error(code: "ServiceUnavailable", message: "503")),
            ("S3 RequestTimeout", makeS3Error(code: "RequestTimeout", message: "timeout")),
            ("S3 InvalidAccessKeyId (auth)", makeS3Error(code: "InvalidAccessKeyId", message: "bad")),
            ("S3 SignatureDoesNotMatch (auth)", makeS3Error(code: "SignatureDoesNotMatch", message: "bad sig")),
            ("S3 ExpiredToken (auth)", makeS3Error(code: "ExpiredToken", message: "expired")),
            ("S3 NoSuchKey", makeS3Error(code: "NoSuchKey", message: "missing")),
            ("S3 AccessDenied (perm denial)", makeS3Error(code: "AccessDenied", message: "denied")),
            ("S3 AllAccessDisabled (perm denial)", makeS3Error(code: "AllAccessDisabled", message: "off")),
            ("S3 unknown code", makeS3Error(code: "WeirdCustomCode", message: "what")),
            ("URLError notConnected", URLError(.notConnectedToInternet)),
            ("URLError timeout", URLError(.timedOut)),
            ("URLError host", URLError(.cannotFindHost)),
            ("URLError dns", URLError(.dnsLookupFailed)),
            ("Custom NSError", NSError(domain: "io.example.weirdcustom", code: 99)),
            ("CocoaError fileNotFound", NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError)),
            ("Generic Swift error", GenericTestError())
        ]

        for testCase in errorCases {
            let mapped = mapThumbnailFetchError(testCase.error)
            XCTAssertTrue(
                allowedDomains.contains(mapped.domain),
                "Custom domain leaked for \(testCase.label): got '\(mapped.domain)'"
            )
            // Additional safety: the code must be a known NSFileProviderError code.
            let validCodes: Set<Int> = [
                NSFileProviderError(.noSuchItem).code.rawValue,
                NSFileProviderError(.serverUnreachable).code.rawValue,
                NSFileProviderError(.cannotSynchronize).code.rawValue,
                NSFileProviderError(.notAuthenticated).code.rawValue
            ]
            XCTAssertTrue(
                validCodes.contains(mapped.code),
                "Unknown NSFileProviderError code \(mapped.code) for \(testCase.label)"
            )
        }
    }

    // MARK: - S3 error fixture

    /// Builds an `AWSErrorType`-conforming error with the given error code.
    /// `DS3S3Client.s3ErrorCode(from:)` uses `error as? AWSErrorType` and
    /// reads `errorCode` — we don't need a real Soto error type, only the
    /// protocol conformance. `AWSErrorContext.init` is internal in SotoCore
    /// so we can't use the real `AWSResponseError` from outside the module;
    /// our `TestAWSError` provides the surface the mapper actually inspects.
    private func makeS3Error(code: String, message: String) -> Error {
        TestAWSError(code: code, message: message)
    }
}

/// Generic Swift error for the "Test 13" sweep — pure Swift type, no
/// NSError ancestry. Must still get bridged to an allowed domain.
private struct GenericTestError: Error {}

/// Test-only `AWSErrorType` conformance. `DS3S3Client.s3ErrorCode(from:)`
/// reads `errorCode` after an `as? AWSErrorType` cast — that's the only
/// surface the mapper inspects, so this minimal stub is sufficient to drive
/// every branch in `mapThumbnailFetchError`.
private struct TestAWSError: AWSErrorType {
    let errorCode: String
    let messageText: String

    init(code: String, message: String) {
        self.errorCode = code
        self.messageText = message
    }

    init?(errorCode _: String, context _: AWSErrorContext) {
        nil
    }

    var context: AWSErrorContext? {
        nil
    }

    var description: String {
        "TestAWSError(\(errorCode)): \(messageText)"
    }
}
