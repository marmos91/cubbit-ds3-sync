import Foundation
import SotoS3

/// Errors related to presigned URL generation.
public enum PresignError: Error, Equatable {
    /// The expiry value is out of the valid range (0, 604800].
    case invalidPresignExpiry
    /// The object URL could not be constructed (e.g., no custom endpoint configured).
    case invalidObjectURL
}

public extension DS3S3Client {
    /// Builds a path-style S3 object URL from endpoint, bucket, and key.
    /// Key components are percent-encoded for URL safety.
    /// - Parameters:
    ///   - endpoint: The S3 endpoint base URL (e.g., "https://s3.cubbit.eu")
    ///   - bucket: The bucket name
    ///   - key: The S3 object key
    /// - Returns: A valid URL in path-style format: endpoint/bucket/key
    /// - Throws: `PresignError.invalidObjectURL` if the resulting string is not a valid URL
    static func buildObjectURL(endpoint: String, bucket: String, key: String) throws -> URL {
        let encodedBucket = bucket.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? bucket
        let encodedKey = key.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? key
        let urlString = "\(endpoint)/\(encodedBucket)/\(encodedKey)"
        guard let url = URL(string: urlString) else {
            throw PresignError.invalidObjectURL
        }
        return url
    }

    /// Generates a presigned GET URL for an S3 object.
    ///
    /// The URL allows unauthenticated HTTP GET access to the object for the specified duration.
    /// Uses SigV4 query-string signing via Soto.
    ///
    /// - Parameters:
    ///   - bucket: The bucket name
    ///   - key: The S3 object key (typically `NSFileProviderItemIdentifier.rawValue`)
    ///   - expiresIn: Seconds until expiry; must be in (0, 604800] (max 7 days per SigV4 spec)
    /// - Returns: A signed URL allowing unauthenticated GET for the duration
    /// - Throws: `PresignError.invalidPresignExpiry` if expiresIn is out of range,
    ///           `PresignError.invalidObjectURL` if the endpoint is not configured or the URL is invalid
    func presignedGetURL(bucket: String, key: String, expiresIn: Int) async throws -> URL {
        guard expiresIn > 0, expiresIn <= 604_800 else {
            throw PresignError.invalidPresignExpiry
        }

        // Require a custom endpoint — Cubbit DS3 always uses a dedicated S3 gateway.
        // When DS3S3Client is created with endpoint: nil, presigning is not meaningful.
        guard let endpoint = customEndpoint else {
            throw PresignError.invalidObjectURL
        }

        let objectURL = try Self.buildObjectURL(endpoint: endpoint, bucket: bucket, key: key)

        return try await s3.signURL(
            url: objectURL,
            httpMethod: .GET,
            expires: .seconds(Int64(expiresIn))
        )
    }
}
