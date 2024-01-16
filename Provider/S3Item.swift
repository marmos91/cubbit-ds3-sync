import Foundation
import FileProvider
import UniformTypeIdentifiers
import DS3Lib
import os.log

class S3Item: NSObject, NSFileProviderItem {
    static let decorationPrefix = Bundle.main.bundleIdentifier!
    
    let identifier: NSFileProviderItemIdentifier
    
    private let logger = Logger(subsystem: "io.cubbit.CubbitDS3Sync.provider", category: "S3Item")
    private let metadata: S3Item.Metadata
    private let separator = DefaultSettings.S3.delimiter
    
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
    
    var itemIdentifier: NSFileProviderItemIdentifier {
        return identifier
    }
    
    var parentItemIdentifier: NSFileProviderItemIdentifier {
        var pathSegments = self.identifier.rawValue.split(separator: self.separator)
        
        if pathSegments.count == 2 {
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
            .allowsWriting
        ]
        
        return capabilities
    }
}
