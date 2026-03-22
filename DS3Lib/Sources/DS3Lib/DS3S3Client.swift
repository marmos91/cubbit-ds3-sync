import Foundation
import SotoS3

/// Lightweight S3 client for bucket and folder listing operations.
/// Wraps Soto S3 so consumers don't need to import SotoS3 directly.
public final class DS3S3Client: @unchecked Sendable {
    private let s3: S3
    private let awsClient: AWSClient

    public init(endpoint: String, accessKeyId: String, secretAccessKey: String) {
        self.awsClient = AWSClient(
            credentialProvider: .static(
                accessKeyId: accessKeyId,
                secretAccessKey: secretAccessKey
            ),
            httpClientProvider: .createNew
        )
        self.s3 = S3(client: awsClient, endpoint: endpoint)
    }

    deinit {
        try? awsClient.syncShutdown()
    }

    /// Lists all buckets accessible with the current credentials.
    public func listBuckets() async throws -> [String] {
        let response = try await s3.listBuckets()
        return response.buckets?.compactMap(\.name) ?? []
    }

    /// Lists immediate subfolders under the given prefix in a bucket.
    /// Returns the full prefix strings (e.g. `["photos/", "documents/"]`).
    public func listFolders(bucket: String, prefix: String? = nil) async throws -> [String] {
        let request = S3.ListObjectsV2Request(
            bucket: bucket,
            delimiter: String(DefaultSettings.S3.delimiter),
            encodingType: .url,
            prefix: prefix
        )
        let response = try await s3.listObjectsV2(request)
        return response.commonPrefixes?.compactMap(\.prefix) ?? []
    }
}
