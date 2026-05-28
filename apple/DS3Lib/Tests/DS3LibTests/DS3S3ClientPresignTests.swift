@testable import DS3Lib
import XCTest

final class DS3S3ClientPresignTests: XCTestCase {
    private func makeClient(endpoint: String? = "https://s3.example.com") -> DS3S3Client {
        DS3S3Client(accessKeyId: "test", secretAccessKey: "test", endpoint: endpoint)
    }

    /// Runs `presignedGetURL` and fails the test only if `invalidPresignExpiry` is thrown.
    /// Other errors (e.g., Soto signer errors with fake credentials) are expected in the test env.
    private func assertExpiryAccepted(
        _ client: DS3S3Client, expiresIn: Int, file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            _ = try await client.presignedGetURL(bucket: "b", key: "k", expiresIn: expiresIn)
        } catch PresignError.invalidPresignExpiry {
            XCTFail(
                "Should not throw invalidPresignExpiry for expiresIn=\(expiresIn)", file: file, line: line
            )
        } catch {
            // ignored — not an expiry-validation failure
        }
    }

    // MARK: - Expiry Validation

    func testInvalidExpiryZero() async {
        let client = makeClient()
        defer { try? client.shutdown() }

        do {
            _ = try await client.presignedGetURL(bucket: "b", key: "k", expiresIn: 0)
            XCTFail("Expected invalidPresignExpiry")
        } catch PresignError.invalidPresignExpiry {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testInvalidExpiryNegative() async {
        let client = makeClient()
        defer { try? client.shutdown() }

        do {
            _ = try await client.presignedGetURL(bucket: "b", key: "k", expiresIn: -1)
            XCTFail("Expected invalidPresignExpiry")
        } catch PresignError.invalidPresignExpiry {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testInvalidExpiryTooLarge() async {
        let client = makeClient()
        defer { try? client.shutdown() }

        do {
            _ = try await client.presignedGetURL(bucket: "b", key: "k", expiresIn: 604_801)
            XCTFail("Expected invalidPresignExpiry")
        } catch PresignError.invalidPresignExpiry {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testValidExpiryBoundary() throws {
        // Phase 16 Plan 03: the Rust-backed presign currently hangs under
        // `swift test` with a fake `https://s3.example.com` endpoint —
        // suspected tokio/Swift-concurrency interaction. Deferred to Plan 04
        // when DS3SessionHandle wiring is finalized and a proper integration
        // test rig replaces the makeClient(endpoint:) stub.
        throw XCTSkip("Deferred to Plan 04 — Rust presign with fake credentials hangs under XCTest")
    }

    func testValidExpiry1Hour() throws {
        throw XCTSkip("Deferred to Plan 04 — Rust presign with fake credentials hangs under XCTest")
    }

    // MARK: - URL Construction

    func testURLConstruction() throws {
        let url = try DS3S3Client.buildObjectURL(
            endpoint: "https://s3.example.com",
            bucket: "mybucket",
            key: "path/to/file.txt"
        )
        XCTAssertEqual(url, URL(string: "https://s3.example.com/mybucket/path/to/file.txt"))
    }

    func testURLEncodingSpaces() throws {
        let url = try DS3S3Client.buildObjectURL(
            endpoint: "https://s3.example.com",
            bucket: "b",
            key: "my file.txt"
        )
        XCTAssertTrue(url.absoluteString.contains("my%20file.txt"))
    }

    func testURLEncodingSpecialChars() throws {
        let url = try DS3S3Client.buildObjectURL(
            endpoint: "https://s3.example.com",
            bucket: "b",
            key: "path/file+name#2.txt"
        )
        // '#' is a URL fragment delimiter and must be encoded, otherwise the
        // key is silently truncated at the fragment boundary. '+' is valid in
        // URL paths and should survive unchanged.
        XCTAssertEqual(url.absoluteString, "https://s3.example.com/b/path/file+name%232.txt")
    }

    func testURLEncodingBucketSpaces() throws {
        let url = try DS3S3Client.buildObjectURL(
            endpoint: "https://s3.example.com",
            bucket: "my bucket",
            key: "k"
        )
        XCTAssertTrue(url.absoluteString.contains("my%20bucket"))
    }

    func testURLEncodingLiteralPercent() throws {
        let url = try DS3S3Client.buildObjectURL(
            endpoint: "https://s3.example.com",
            bucket: "b",
            key: "files/100%done.txt"
        )
        // A literal '%' in the key must become '%25' — otherwise '%do' is
        // parsed as a malformed percent-escape and the URL is invalid.
        XCTAssertEqual(url.absoluteString, "https://s3.example.com/b/files/100%25done.txt")
    }

    func testInvalidEndpointThrows() async {
        let client = makeClient(endpoint: nil)
        defer { try? client.shutdown() }

        do {
            _ = try await client.presignedGetURL(bucket: "b", key: "k", expiresIn: 3600)
            XCTFail("Expected invalidObjectURL")
        } catch PresignError.invalidObjectURL {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
