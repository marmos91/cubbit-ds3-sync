import Foundation
import Testing

@testable import DS3Lib

@Suite("DS3S3Client Presign URL Tests")
struct DS3S3ClientPresignTests {
    private static func makeClient(endpoint: String? = "https://s3.example.com") -> DS3S3Client {
        DS3S3Client(accessKeyId: "test", secretAccessKey: "test", endpoint: endpoint)
    }

    /// Runs `presignedGetURL` and fails the test only if `invalidPresignExpiry` is thrown.
    /// Other errors (e.g., Soto signer errors with fake credentials) are expected in the test env.
    private static func expectExpiryAccepted(
        _ client: DS3S3Client, expiresIn: Int
    ) async {
        do {
            _ = try await client.presignedGetURL(bucket: "b", key: "k", expiresIn: expiresIn)
        } catch PresignError.invalidPresignExpiry {
            Issue.record("Should not throw invalidPresignExpiry for expiresIn=\(expiresIn)")
        } catch {
            // ignored — not an expiry-validation failure
        }
    }

    // MARK: - Expiry Validation

    @Test("Zero expiry throws invalidPresignExpiry")
    func testInvalidExpiryZero() async {
        let client = Self.makeClient()
        defer { try? client.shutdown() }

        await #expect(throws: PresignError.invalidPresignExpiry) {
            _ = try await client.presignedGetURL(bucket: "b", key: "k", expiresIn: 0)
        }
    }

    @Test("Negative expiry throws invalidPresignExpiry")
    func testInvalidExpiryNegative() async {
        let client = Self.makeClient()
        defer { try? client.shutdown() }

        await #expect(throws: PresignError.invalidPresignExpiry) {
            _ = try await client.presignedGetURL(bucket: "b", key: "k", expiresIn: -1)
        }
    }

    @Test("Expiry exceeding 7 days throws invalidPresignExpiry")
    func testInvalidExpiryTooLarge() async {
        let client = Self.makeClient()
        defer { try? client.shutdown() }

        await #expect(throws: PresignError.invalidPresignExpiry) {
            _ = try await client.presignedGetURL(bucket: "b", key: "k", expiresIn: 604_801)
        }
    }

    @Test("Expiry at 7-day boundary does not throw invalidPresignExpiry")
    func testValidExpiryBoundary() async {
        let client = Self.makeClient()
        defer { try? client.shutdown() }
        await Self.expectExpiryAccepted(client, expiresIn: 604_800)
    }

    @Test("1-hour expiry does not throw invalidPresignExpiry")
    func testValidExpiry1Hour() async {
        let client = Self.makeClient()
        defer { try? client.shutdown() }
        await Self.expectExpiryAccepted(client, expiresIn: 3_600)
    }

    // MARK: - URL Construction

    @Test("Builds path-style URL from endpoint, bucket, and key")
    func testURLConstruction() throws {
        let url = try DS3S3Client.buildObjectURL(
            endpoint: "https://s3.example.com",
            bucket: "mybucket",
            key: "path/to/file.txt"
        )
        #expect(url == URL(string: "https://s3.example.com/mybucket/path/to/file.txt"))
    }

    @Test("Percent-encodes spaces in key")
    func testURLEncodingSpaces() throws {
        let url = try DS3S3Client.buildObjectURL(
            endpoint: "https://s3.example.com",
            bucket: "b",
            key: "my file.txt"
        )
        #expect(url.absoluteString.contains("my%20file.txt"))
    }

    @Test("Encodes '#' as %23 but preserves '+' in key")
    func testURLEncodingSpecialChars() throws {
        let url = try DS3S3Client.buildObjectURL(
            endpoint: "https://s3.example.com",
            bucket: "b",
            key: "path/file+name#2.txt"
        )
        // '#' is a URL fragment delimiter and must be encoded, otherwise the
        // key is silently truncated at the fragment boundary. '+' is valid in
        // URL paths and should survive unchanged.
        #expect(url.absoluteString == "https://s3.example.com/b/path/file+name%232.txt")
    }

    @Test("Percent-encodes bucket name with spaces")
    func testURLEncodingBucketSpaces() throws {
        let url = try DS3S3Client.buildObjectURL(
            endpoint: "https://s3.example.com",
            bucket: "my bucket",
            key: "k"
        )
        #expect(url.absoluteString.contains("my%20bucket"))
    }

    @Test("Encodes literal '%' as %25 in key")
    func testURLEncodingLiteralPercent() throws {
        let url = try DS3S3Client.buildObjectURL(
            endpoint: "https://s3.example.com",
            bucket: "b",
            key: "files/100%done.txt"
        )
        // A literal '%' in the key must become '%25' — otherwise '%do' is
        // parsed as a malformed percent-escape and the URL is invalid.
        #expect(url.absoluteString == "https://s3.example.com/b/files/100%25done.txt")
    }

    @Test("Nil endpoint throws invalidObjectURL")
    func testInvalidEndpointThrows() async {
        let client = Self.makeClient(endpoint: nil)
        defer { try? client.shutdown() }

        await #expect(throws: PresignError.invalidObjectURL) {
            _ = try await client.presignedGetURL(bucket: "b", key: "k", expiresIn: 3_600)
        }
    }
}
