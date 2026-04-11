import Foundation
import Testing

@testable import DS3Lib

@Suite("DS3S3Client Presign URL Tests")
struct DS3S3ClientPresignTests {
    // MARK: - Expiry Validation

    @Test("Zero expiry throws invalidPresignExpiry")
    func testInvalidExpiryZero() async {
        let client = DS3S3Client(
            accessKeyId: "test",
            secretAccessKey: "test",
            endpoint: "https://s3.example.com"
        )
        defer { try? client.shutdown() }

        await #expect(throws: PresignError.invalidPresignExpiry) {
            _ = try await client.presignedGetURL(bucket: "b", key: "k", expiresIn: 0)
        }
    }

    @Test("Negative expiry throws invalidPresignExpiry")
    func testInvalidExpiryNegative() async {
        let client = DS3S3Client(
            accessKeyId: "test",
            secretAccessKey: "test",
            endpoint: "https://s3.example.com"
        )
        defer { try? client.shutdown() }

        await #expect(throws: PresignError.invalidPresignExpiry) {
            _ = try await client.presignedGetURL(bucket: "b", key: "k", expiresIn: -1)
        }
    }

    @Test("Expiry exceeding 7 days throws invalidPresignExpiry")
    func testInvalidExpiryTooLarge() async {
        let client = DS3S3Client(
            accessKeyId: "test",
            secretAccessKey: "test",
            endpoint: "https://s3.example.com"
        )
        defer { try? client.shutdown() }

        await #expect(throws: PresignError.invalidPresignExpiry) {
            _ = try await client.presignedGetURL(bucket: "b", key: "k", expiresIn: 604_801)
        }
    }

    @Test("Expiry at 7-day boundary does not throw invalidPresignExpiry")
    func testValidExpiryBoundary() async {
        let client = DS3S3Client(
            accessKeyId: "test",
            secretAccessKey: "test",
            endpoint: "https://s3.example.com"
        )
        defer { try? client.shutdown() }

        do {
            _ = try await client.presignedGetURL(bucket: "b", key: "k", expiresIn: 604_800)
        } catch let error as PresignError where error == .invalidPresignExpiry {
            Issue.record("Should not throw invalidPresignExpiry for valid 7-day boundary expiry")
        } catch {
            // Other errors (e.g., signer errors with fake creds) are expected in test environment
        }
    }

    @Test("1-hour expiry does not throw invalidPresignExpiry")
    func testValidExpiry1Hour() async {
        let client = DS3S3Client(
            accessKeyId: "test",
            secretAccessKey: "test",
            endpoint: "https://s3.example.com"
        )
        defer { try? client.shutdown() }

        do {
            _ = try await client.presignedGetURL(bucket: "b", key: "k", expiresIn: 3600)
        } catch let error as PresignError where error == .invalidPresignExpiry {
            Issue.record("Should not throw invalidPresignExpiry for valid 1-hour expiry")
        } catch {
            // Other errors (e.g., signer errors with fake creds) are expected in test environment
        }
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

    @Test("Handles special characters in key")
    func testURLEncodingSpecialChars() throws {
        let url = try DS3S3Client.buildObjectURL(
            endpoint: "https://s3.example.com",
            bucket: "b",
            key: "path/file+name#2.txt"
        )
        // Should not be nil — URL must be valid
        #expect(url.absoluteString.contains("path/"))
    }

    @Test("Nil endpoint throws invalidObjectURL")
    func testInvalidEndpointThrows() async {
        let client = DS3S3Client(
            accessKeyId: "test",
            secretAccessKey: "test",
            endpoint: nil
        )
        defer { try? client.shutdown() }

        await #expect(throws: PresignError.invalidObjectURL) {
            _ = try await client.presignedGetURL(bucket: "b", key: "k", expiresIn: 3600)
        }
    }
}
