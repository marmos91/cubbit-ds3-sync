@testable import DS3Lib
import FileProvider
import Foundation
import XCTest

/// Verifies the `mapThumbnailFetchError` helper maps every below-the-seam
/// error to one of the THREE allowed `NSFileProviderError` codes
/// (Phase 13 D-13). Crucially, Test 13 asserts NO custom error domain
/// ever escapes this chokepoint. Phase 16 Plan 03: Soto types replaced
/// with `DS3S3Error` cases (and `DS3S3Error.unknown(code:message:)` for
/// non-enum S3 codes like `AllAccessDisabled`).
final class FetchThumbnailsErrorMappingTests: XCTestCase {
    // MARK: - Test 7 — 404 → .noSuchItem

    func test404MapsToNoSuchItem() async {
        let drive = ProviderTestFixtures.makeDrive()
        let identifier = NSFileProviderItemIdentifier("prefix/photo.jpg")
        let recorder = ResultRecorder()

        let fetchBytes: ThumbnailByteFetcher = { _, _ in nil }

        await consumeThumbnail(
            identifier: identifier,
            drive: drive,
            fetchBytes: fetchBytes,
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
        let mapped = mapThumbnailFetchError(DS3S3Error.internalError)
        XCTAssertEqual(mapped.domain, NSFileProviderErrorDomain)
        XCTAssertEqual(mapped.code, NSFileProviderError(.serverUnreachable).code.rawValue)
    }

    // MARK: - Test 9 — SlowDown → .serverUnreachable (NO inline retry per D-14)

    func testSlowDownMapsToServerUnreachable() {
        let mapped = mapThumbnailFetchError(DS3S3Error.slowDown)
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
        let error = DS3S3Error.invalidAccessKey
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

    func testAccessDeniedMapsToNotAuthenticated() {
        let mapped = mapThumbnailFetchError(DS3S3Error.accessDenied)
        XCTAssertEqual(mapped.domain, NSFileProviderErrorDomain)
        XCTAssertEqual(
            mapped.code, NSFileProviderError(.notAuthenticated).code.rawValue,
            "AccessDenied must map to .notAuthenticated (bucket-policy denial)"
        )
    }

    /// Same routing for `AllAccessDisabled` (account-level shutdown). DS3S3Error
    /// has no dedicated case, so the Rust→Swift translator surfaces it via
    /// `.unknown(code: "AllAccessDisabled", ...)`.
    func testAllAccessDisabledMapsToNotAuthenticated() {
        let error = DS3S3Error.unknown(code: "AllAccessDisabled", message: "Account disabled")
        let mapped = mapThumbnailFetchError(error)
        XCTAssertEqual(mapped.domain, NSFileProviderErrorDomain)
        XCTAssertEqual(
            mapped.code, NSFileProviderError(.notAuthenticated).code.rawValue
        )
    }

    // MARK: - Test 13 — No custom error domain ever escapes (CRITICAL)

    func testNoCustomErrorDomainEverEscapes() {
        let allowedDomains: Set<String> = [NSFileProviderErrorDomain, NSCocoaErrorDomain]

        let errorCases: [(label: String, error: Error)] = [
            ("S3 InternalError", DS3S3Error.internalError),
            ("S3 SlowDown", DS3S3Error.slowDown),
            ("S3 ServiceUnavailable", DS3S3Error.serviceUnavailable),
            ("S3 RequestTimeout", DS3S3Error.requestTimeout),
            ("S3 InvalidAccessKeyId (auth)", DS3S3Error.invalidAccessKey),
            ("S3 SignatureDoesNotMatch (auth)", DS3S3Error.signatureDoesNotMatch),
            ("S3 ExpiredToken (auth)", DS3S3Error.expiredToken),
            ("S3 NoSuchKey", DS3S3Error.noSuchKey),
            ("S3 AccessDenied (perm denial)", DS3S3Error.accessDenied),
            (
                "S3 AllAccessDisabled (perm denial)",
                DS3S3Error.unknown(code: "AllAccessDisabled", message: "off")
            ),
            (
                "S3 unknown code",
                DS3S3Error.unknown(code: "WeirdCustomCode", message: "what")
            ),
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
}

/// Generic Swift error for the "Test 13" sweep — pure Swift type, no
/// NSError ancestry. Must still get bridged to an allowed domain.
private struct GenericTestError: Error {}
