import Foundation
import FileProvider
import UniformTypeIdentifiers
import DS3Lib
import os.log

class S3Item: NSObject, NSFileProviderItem {
    static let decorationPrefix = Bundle.main.bundleIdentifier!
    
    let identifier: NSFileProviderItemIdentifier
    
    private let logger = Logger(subsystem: "io.cubbit.CubbitDS3Sync.provider", category: "S3Item")
    private let separator = DefaultSettings.S3.delimiter
    
    let metadata: S3Item.Metadata
    let drive: DS3Drive
    
    init(
        identifier: NSFileProviderItemIdentifier,
        drive: DS3Drive,
        objectMetadata: S3Item.Metadata
    ) {
        self.metadata = objectMetadata
        self.drive = drive
        
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
        self.metadata = S3Item.Metadata(
            lastModified: item.contentModificationDate as? Date,
            size: (item.documentSize ?? 0) ?? 0
        )
    }
    
    var itemIdentifier: NSFileProviderItemIdentifier {
        return identifier
    }
    
    var parentItemIdentifier: NSFileProviderItemIdentifier {
        var pathSegments = self.identifier.rawValue.split(separator: self.separator)
        
        let prefixSegmentsCount = (self.drive.syncAnchor.prefix?.split(separator: self.separator) ?? []).count

        if pathSegments.count == prefixSegmentsCount + 1 {
            // NOTE: e.g. parent of prefix/folder/ is prefix/ (remember prefix == .rootContainer)
            return .rootContainer
        }
        
        let _ = pathSegments.popLast()
        let parentIdentifier = pathSegments.joined(separator: String(self.separator))
        
        return NSFileProviderItemIdentifier(parentIdentifier + String(self.separator))
    }

    var filename: String {
        let components = self.identifier.rawValue.split(separator: self.separator)
        let name = String(components.last ?? "")
        
        return name
    }
    
    var contentModificationDate: Date? {
        return self.metadata.lastModified
    }

    var documentSize: NSNumber? {
        return self.metadata.size
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
        
        let type: UTType = self.identifier.rawValue.last! == self.separator ? .folder : .item
    
        return type
    }
    
    var isFolder: Bool {
        return self.contentType == .folder || self.contentType == .directory
    }
    
    var extendedAttributes: [String: Data] {
        return self.metadata.extendedAttributes?.values ?? [:]
    }
    
    var contentPolicy: NSFileProviderContentPolicy {
        // TODO: Here we can implement a pinning policy
        return .downloadLazily
    }
    
    var capabilities: NSFileProviderItemCapabilities {
        let capabilities: NSFileProviderItemCapabilities = [
            .allowsAddingSubItems,
            .allowsContentEnumerating,
            .allowsDeleting,
            .allowsReading,
            .allowsRenaming,
            .allowsReparenting,
            .allowsWriting,
            .allowsExcludingFromSync
        ]
        
        return capabilities
    }
}
