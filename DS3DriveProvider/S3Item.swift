import Foundation
import FileProvider
import UniformTypeIdentifiers
import DS3Lib

class S3Item: NSObject, NSFileProviderItem, NSFileProviderItemDecorating, @unchecked Sendable {
    static let decorationPrefix = Bundle.main.bundleIdentifier!

    // MARK: - Decoration Identifiers

    static let decorationSynced = NSFileProviderItemDecorationIdentifier(
        rawValue: "\(decorationPrefix).synced"
    )
    static let decorationSyncing = NSFileProviderItemDecorationIdentifier(
        rawValue: "\(decorationPrefix).syncing"
    )
    static let decorationError = NSFileProviderItemDecorationIdentifier(
        rawValue: "\(decorationPrefix).error"
    )
    static let decorationCloudOnly = NSFileProviderItemDecorationIdentifier(
        rawValue: "\(decorationPrefix).cloudOnly"
    )
    static let decorationConflict = NSFileProviderItemDecorationIdentifier(
        rawValue: "\(decorationPrefix).conflict"
    )
    
    let identifier: NSFileProviderItemIdentifier

    private let separator = DefaultSettings.S3.delimiter
    
    let metadata: S3Item.Metadata
    let drive: DS3Drive
    private let isPinned: Bool

    init(
        identifier: NSFileProviderItemIdentifier,
        drive: DS3Drive,
        objectMetadata: S3Item.Metadata,
        isPinned: Bool = false
    ) {
        self.metadata = objectMetadata
        self.drive = drive
        self.isPinned = isPinned

        if identifier.rawValue == String(DefaultSettings.S3.delimiter) {
            self.identifier = .rootContainer
        } else {
            self.identifier = identifier
        }
    }

    init(
        from item: NSFileProviderItem,
        drive: DS3Drive
    ) {
        self.identifier = item.itemIdentifier
        self.drive = drive
        self.isPinned = item.contentPolicy == .downloadEagerlyAndKeepDownloaded
        self.metadata = S3Item.Metadata(
            lastModified: item.contentModificationDate as? Date,
            size: (item.documentSize ?? 0) ?? 0
        )
    }
    
    var itemIdentifier: NSFileProviderItemIdentifier {
        identifier
    }
    
    var parentItemIdentifier: NSFileProviderItemIdentifier {
        var pathSegments = self.identifier.rawValue.split(separator: self.separator)
        
        let prefixSegmentsCount = (self.drive.syncAnchor.prefix?.split(separator: self.separator) ?? []).count

        if pathSegments.count == prefixSegmentsCount + 1 {
            // NOTE: e.g. parent of prefix/folder/ is prefix/ (remember prefix == .rootContainer)
            return .rootContainer
        }
        
        _ = pathSegments.popLast()
        let parentIdentifier = pathSegments.joined(separator: String(self.separator))
        
        return NSFileProviderItemIdentifier(parentIdentifier + String(self.separator))
    }

    var filename: String {
        String(identifier.rawValue.split(separator: separator).last ?? "")
    }
    
    var contentModificationDate: Date? {
        metadata.lastModified
    }

    var documentSize: NSNumber? {
        metadata.size
    }
    
    var itemVersion: NSFileProviderItemVersion {
        NSFileProviderItemVersion(
            contentVersion: self.metadata.etag?.data(using: .utf8) ?? Data(),
            metadataVersion: self.metadata.etag?.data(using: .utf8) ?? Data()
        )
    }
    
    var contentType: UTType {
        if self.identifier == .rootContainer {
            return .folder
        }

        return self.identifier.rawValue.last == self.separator ? .folder : .item
    }
    
    var isFolder: Bool {
        contentType == .folder
    }
    
    var contentPolicy: NSFileProviderContentPolicy {
        isPinned ? .downloadEagerlyAndKeepDownloaded : .inherited
    }
    
    var capabilities: NSFileProviderItemCapabilities {
        [
            .allowsAddingSubItems,
            .allowsContentEnumerating,
            .allowsDeleting,
            .allowsReading,
            .allowsRenaming,
            .allowsReparenting,
            .allowsWriting,
            .allowsExcludingFromSync
        ]
    }

    // MARK: - Decorations

    var decorations: [NSFileProviderItemDecorationIdentifier]? {
        switch metadata.syncStatus {
        case "synced":
            return [Self.decorationSynced]
        case "syncing":
            return [Self.decorationSyncing]
        case "error":
            return [Self.decorationError]
        case "conflict":
            return [Self.decorationConflict]
        default:
            return [Self.decorationCloudOnly]
        }
    }
}

// MARK: - MetadataStore Convenience

extension MetadataStore.ItemUpsertData {
    /// Creates upsert data from an S3Item, mapping parent identifiers and metadata.
    init(from item: S3Item) {
        self.init(
            s3Key: item.itemIdentifier.rawValue,
            driveId: item.drive.id,
            etag: item.metadata.etag,
            lastModified: item.metadata.lastModified,
            syncStatus: .synced,
            parentKey: item.parentItemIdentifier == .rootContainer ? nil : item.parentItemIdentifier.rawValue,
            contentType: item.metadata.contentType,
            size: Int64(truncating: item.metadata.size)
        )
    }
}
