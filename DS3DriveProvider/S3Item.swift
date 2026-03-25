import DS3Lib
import FileProvider
import Foundation
import UniformTypeIdentifiers

class S3Item: NSObject, NSFileProviderItem, NSFileProviderItemDecorating, @unchecked Sendable {
    static let decorationPrefix = "io.cubbit.DS3Drive.DS3DriveProvider"

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
    static let decorationTrashed = NSFileProviderItemDecorationIdentifier(
        rawValue: "\(decorationPrefix).trashed"
    )

    let identifier: NSFileProviderItemIdentifier

    private let separator = DefaultSettings.S3.delimiter

    let metadata: S3Item.Metadata
    let drive: DS3Drive
    private let isPinned: Bool

    /// When `true`, the item is treated as trashed regardless of its identifier.
    /// Used when the system-facing identifier is the original key but the object
    /// lives under the `.trash/` prefix on S3.
    let forcedTrashed: Bool

    init(
        identifier: NSFileProviderItemIdentifier,
        drive: DS3Drive,
        objectMetadata: S3Item.Metadata,
        isPinned: Bool = false,
        forcedTrashed: Bool = false
    ) {
        self.metadata = objectMetadata
        self.drive = drive
        self.isPinned = isPinned
        self.forcedTrashed = forcedTrashed

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
        self.forcedTrashed = false
        #if os(macOS)
            self.isPinned = item.contentPolicy == .downloadEagerlyAndKeepDownloaded
        #else
            self.isPinned = false
        #endif
        self.metadata = S3Item.Metadata(
            lastModified: item.contentModificationDate as? Date,
            size: (item.documentSize ?? 0) ?? 0
        )
    }

    var itemIdentifier: NSFileProviderItemIdentifier {
        identifier
    }

    /// Whether this item lives inside the `.trash/` prefix or has been explicitly
    /// marked as trashed (when the system-facing identifier is the original key).
    var isInTrash: Bool {
        forcedTrashed || S3Lib.isTrashedKey(identifier.rawValue, drive: drive)
    }

    /// The actual S3 key where the object's data lives. For `forcedTrashed` items
    /// the data is under the `.trash/` prefix even though the identifier is the
    /// original key.
    var s3Key: String {
        if forcedTrashed, !S3Lib.isTrashedKey(identifier.rawValue, drive: drive) {
            return S3Lib.trashKey(forKey: identifier.rawValue, drive: drive)
        }
        return identifier.rawValue
    }

    var parentItemIdentifier: NSFileProviderItemIdentifier {
        if identifier == .trashContainer {
            return .rootContainer
        }

        // forcedTrashed items use the original key as identifier but belong to
        // .trashContainer. Only top-level trashed items are surfaced to the
        // system (no nested trash hierarchy with original identifiers).
        if forcedTrashed {
            return .trashContainer
        }

        if isInTrash {
            let trashPrefix = S3Lib.fullTrashPrefix(forDrive: drive)
            let relativePath = String(identifier.rawValue.dropFirst(trashPrefix.count))
            let segments = relativePath.split(separator: separator)
            if segments.count <= 1 {
                return .trashContainer
            }
            var pathSegments = identifier.rawValue.split(separator: separator)
            _ = pathSegments.popLast()
            let parentIdentifier = pathSegments.joined(separator: String(separator))
            return NSFileProviderItemIdentifier(parentIdentifier + String(separator))
        }

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
        if identifier == .trashContainer {
            return "Trash"
        }
        return String(identifier.rawValue.split(separator: separator).last ?? "")
    }

    var contentModificationDate: Date? {
        if isFolder {
            // Always nil for folders. Some code paths carry a real lastModified
            // (S3 marker objects, HeadObject) while others don't (common prefixes,
            // virtual folders). Returning a date only when available makes the
            // system see property changes each enumeration, breaking Finder icons.
            return nil
        }
        return metadata.lastModified
    }

    // NOTE: isTrashed and trashingDate deliberately NOT implemented.
    // isTrashed is a V2 property — setting it alongside .trashContainer parent (V3)
    // confuses the system. trashingDate doesn't exist in Apple SDK headers.
    // V3 infers trash state from parentItemIdentifier == .trashContainer.

    var documentSize: NSNumber? {
        // Folders have no document size — returning nil lets the system
        // compute the total from children and avoids confusing a folder
        // with a 0-byte file.
        isFolder ? nil : metadata.size
    }

    var itemVersion: NSFileProviderItemVersion {
        let versionData: Data = if isFolder {
            // Folders MUST use a stable, identifier-based version regardless
            // of whether an etag is available. Different code paths (per-folder
            // enumeration, working set, item(for:), materializeFolderItem)
            // produce folders with or without etags. Inconsistent versions
            // cause the system to re-process items, breaking folder icons.
            identifier.rawValue.data(using: .utf8) ?? Data()
        } else if let etag = self.metadata.etag, let data = etag.data(using: .utf8) {
            data
        } else {
            Data()
        }
        return NSFileProviderItemVersion(
            contentVersion: versionData,
            metadataVersion: versionData
        )
    }

    var contentType: UTType {
        if identifier == .rootContainer || identifier == .trashContainer
            || identifier.rawValue.last == separator {
            return .folder
        }

        if let ext = filename.split(separator: ".").last,
           let utType = UTType(filenameExtension: String(ext)) {
            return utType
        }

        return .item
    }

    var isFolder: Bool {
        contentType == .folder
    }

    #if os(macOS)
        var contentPolicy: NSFileProviderContentPolicy {
            isPinned ? .downloadEagerlyAndKeepDownloaded : .inherited
        }
    #endif

    var capabilities: NSFileProviderItemCapabilities {
        if identifier == .trashContainer {
            return [.allowsDeleting, .allowsReading, .allowsContentEnumerating]
        }

        if isInTrash {
            return [.allowsDeleting, .allowsReading, .allowsContentEnumerating, .allowsReparenting]
        }

        var caps: NSFileProviderItemCapabilities = [
            .allowsAddingSubItems,
            .allowsContentEnumerating,
            .allowsDeleting,
            .allowsReading,
            .allowsRenaming,
            .allowsReparenting,
            .allowsTrashing,
            .allowsWriting
        ]
        #if os(macOS)
            caps.insert(.allowsExcludingFromSync)
        #endif
        return caps
    }

    // MARK: - Decorations

    var decorations: [NSFileProviderItemDecorationIdentifier]? {
        #if os(iOS)
            // On iOS, return nil to avoid badge decorations interfering with the
            // default file/folder icon rendering in the Files app. The cloudOnly
            // decoration (cloud.fill) on first-load items suppresses icons;
            // iOS already shows its own download-cloud indicator natively.
            return nil
        #else
            if isInTrash {
                return [Self.decorationTrashed]
            }
            // Only show decorations for transient/actionable states.
            // The "synced" and "cloudOnly" states must NOT produce
            // decorations: items from the working set S3 listing have
            // syncStatus=nil while the same items from MetadataStore
            // have syncStatus="synced". Any decoration difference
            // between these code paths causes Finder to re-process
            // items in icon view, replacing their icons with blank
            // documents. macOS natively shows cloud/download badges
            // for non-materialized File Provider items.
            switch metadata.syncStatus {
            case "syncing":
                return [Self.decorationSyncing]
            case "error":
                return [Self.decorationError]
            case "conflict":
                return [Self.decorationConflict]
            default:
                return nil
            }
        #endif
    }
}

// MARK: - MetadataStore Convenience

extension MetadataStore.ItemUpsertData {
    /// Creates upsert data from an S3Item, mapping parent identifiers and metadata.
    init(from item: S3Item) {
        self.init(
            s3Key: item.itemIdentifier.rawValue,
            driveId: item.drive.id,
            etag: ETagUtils.normalize(item.metadata.etag),
            lastModified: item.metadata.lastModified,
            syncStatus: .synced,
            parentKey: item.parentItemIdentifier == .rootContainer ? nil : item.parentItemIdentifier.rawValue,
            contentType: item.metadata.contentType,
            size: Int64(truncating: item.metadata.size)
        )
    }
}
