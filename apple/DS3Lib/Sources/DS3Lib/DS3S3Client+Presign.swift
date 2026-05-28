import DS3CoreFFI
import Foundation

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
    /// Retained for callers that build object URLs without presigning.
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
    /// - Parameters:
    ///   - bucket: The bucket name
    ///   - key: The S3 object key
    ///   - expiresIn: Seconds until expiry; must be in (0, 604800] (7-day SigV4 limit)
    /// - Returns: A signed URL allowing unauthenticated GET for the duration.
    /// - Throws: `PresignError.invalidPresignExpiry` if expiresIn is out of range.
    func presignedGetURL(bucket: String, key: String, expiresIn: Int) async throws -> URL {
        guard expiresIn > 0, expiresIn <= 604_800 else {
            throw PresignError.invalidPresignExpiry
        }
        // Cubbit DS3 always uses a custom S3 gateway; reject nil endpoint
        // early so presign errors are clearly distinguished from network
        // failures (preserves the Soto-era contract).
        guard customEndpoint != nil else {
            throw PresignError.invalidObjectURL
        }
        do {
            let urlString = try handle.presignGet(
                bucket: bucket,
                key: key,
                expiresInSeconds: Int64(expiresIn)
            )
            guard let url = URL(string: urlString) else {
                throw PresignError.invalidObjectURL
            }
            return url
        } catch let error as Ds3Error {
            logS3Error(operation: "presignedGetURL", error: error)
            throw DS3S3Error.translate(error)
        }
    }
}
