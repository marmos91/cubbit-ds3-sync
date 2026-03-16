import Foundation

/// Result of a reconciliation cycle comparing S3 remote state to local MetadataStore.
public struct ReconciliationResult: Sendable {
    /// S3 keys present remotely but not in MetadataStore.
    public let newKeys: Set<String>

    /// S3 keys present in both but with different ETags.
    public let modifiedKeys: Set<String>

    /// S3 keys present in MetadataStore (synced) but not found remotely.
    public let deletedKeys: Set<String>

    /// Remote items that were new or modified, indexed by S3 key.
    /// Note: does not contain unchanged items — only those that triggered a MetadataStore update.
    public let remoteItems: [String: S3ObjectInfo]

    /// True if more than 50% of local items were detected as deleted in one cycle.
    public let massDeletionDetected: Bool

    public init(
        newKeys: Set<String>,
        modifiedKeys: Set<String>,
        deletedKeys: Set<String>,
        remoteItems: [String: S3ObjectInfo],
        massDeletionDetected: Bool
    ) {
        self.newKeys = newKeys
        self.modifiedKeys = modifiedKeys
        self.deletedKeys = deletedKeys
        self.remoteItems = remoteItems
        self.massDeletionDetected = massDeletionDetected
    }
}

/// Lightweight Sendable representation of an S3 object from a listing response.
public struct S3ObjectInfo: Sendable {
    public let etag: String?
    public let lastModified: Date?
    public let size: Int64
    public let contentType: String?
    public let parentKey: String?
    public let isFolder: Bool

    public init(
        etag: String? = nil,
        lastModified: Date? = nil,
        size: Int64 = 0,
        contentType: String? = nil,
        parentKey: String? = nil,
        isFolder: Bool = false
    ) {
        self.etag = etag
        self.lastModified = lastModified
        self.size = size
        self.contentType = contentType
        self.parentKey = parentKey
        self.isFolder = isFolder
    }
}

/// A single page of S3 listing results.
public struct S3ListingPage: Sendable {
    public let items: [String: S3ObjectInfo]
    public let continuationToken: String?

    public init(items: [String: S3ObjectInfo], continuationToken: String?) {
        self.items = items
        self.continuationToken = continuationToken
    }
}

/// Abstraction over S3 listing operations for dependency injection.
/// The real implementation wraps SotoS3 ListObjectsV2; tests provide mock data.
public protocol S3ListingProvider: Sendable {
    /// Lists all objects in the given bucket/prefix, returning a dictionary keyed by S3 key.
    func listAllItems(bucket: String, prefix: String?) async throws -> [String: S3ObjectInfo]

    /// Lists a single page of objects. Returns items and an optional continuation token for the next page.
    func listItemsPage(bucket: String, prefix: String?, continuationToken: String?) async throws -> S3ListingPage
}
