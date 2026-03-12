import Foundation
import DS3Lib

/// Adapts the existing S3Lib to conform to SyncEngine's S3ListingProvider protocol.
/// Lives in the extension target because S3Lib is only available there.
final class S3LibListingAdapter: S3ListingProvider, @unchecked Sendable {
    private let s3Lib: S3Lib
    private let drive: DS3Drive

    init(s3Lib: S3Lib, drive: DS3Drive) {
        self.s3Lib = s3Lib
        self.drive = drive
    }

    func listAllItems(bucket: String, prefix: String?) async throws -> [String: S3ObjectInfo] {
        var allItems: [String: S3ObjectInfo] = [:]
        var continuationToken: String?

        repeat {
            let (items, nextToken) = try await s3Lib.listS3Items(
                forDrive: drive,
                withPrefix: prefix,
                recursively: true,
                withContinuationToken: continuationToken
            )

            for item in items {
                let key = item.itemIdentifier.rawValue
                allItems[key] = S3ObjectInfo(
                    etag: item.metadata.etag,
                    lastModified: item.metadata.lastModified,
                    size: Int64(truncating: item.metadata.size),
                    contentType: item.metadata.contentType,
                    parentKey: item.parentItemIdentifier == .rootContainer ? nil : item.parentItemIdentifier.rawValue,
                    isFolder: item.isFolder
                )
            }

            continuationToken = nextToken
        } while continuationToken != nil

        return allItems
    }
}
