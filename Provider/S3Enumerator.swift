import Foundation
import FileProvider
import os.log
import SotoS3

enum EnumeratorError: Error {
    case unsopported
    case missingParameters
}

class S3Enumerator: NSObject, NSFileProviderEnumerator {
    typealias Logger = os.Logger
    
    private let logger = Logger(subsystem: "io.cubbit.CubbitDS3Sync.provider", category: "S3Enumerator")
    private let parent: NSFileProviderItemIdentifier
    private let anchor = SharedData.shared.loadSyncAnchorOrCreate()
    
    private let s3: S3
    private var drive: DS3Drive
    
    // TODO: Support skipped files
//    static let untrackedTypes: [UTType] = [
//        "com.apple.iwork.pages.sffpages",
//        "com.apple.iwork.pages.pages-tef"
//    ].compactMap(UTType.init)
    
//    static func shouldTrackPresentationStatus(for type: UTType) -> Bool {
//        for untrackedType in ItemEnumerator.untrackedTypes where type.conforms(to: untrackedType) {
//            return false
//        }
//        return true
//    }
    
    init(
        parent: NSFileProviderItemIdentifier,
        s3: S3,
        drive: DS3Drive
    ) {
        self.parent = parent
        self.s3 = s3
        self.drive = drive
        
        switch self.parent {
        case .rootContainer, .trashContainer, .workingSet:
            break
        default:
            self.drive.syncAnchor.prefix = parent.rawValue
        }
        
        super.init()
    }
    
    func invalidate() {}
    
    // NOTE: gets called when the extension wants to get the last sync point (could be a timestamp)
    func currentSyncAnchor(
        completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void
    ) {
        completionHandler(self.anchor)
    }
    
    func enumerateItems(
        for observer: NSFileProviderEnumerationObserver,
        startingAt page: NSFileProviderPage
    ) {
        // TODO: this can be furtherly improve by only listing one level for the current enumerator.
        // Subsequent calls will be made to enumerateItems for the subfolders. This is crucial to list huge buckets
        
        Task {
            do {
                let prefix: String? = self.drive.syncAnchor.prefix
                
                let (items, continuationToken) = try await self.listS3Items(
                    withS3: self.s3,
                    forDrive: self.drive,
                    withPrefix: prefix,
                    withContinuationToken: page.toContinuationToken()
                )
                
                guard let items = items else {
                    // If no items are returned should finish enumeration
                    return observer.finishEnumerating(upTo: nil)
                }
                
                observer.didEnumerate(items)
                
                var page: NSFileProviderPage?
            
                if continuationToken != nil {
                    page = NSFileProviderPage(continuationToken!)
                }
                
                return observer.finishEnumerating(upTo: page)
            } catch {
                self.logger.error("An error occurred while list objects \(error)")
                observer.finishEnumeratingWithError(error)
            }
        }
    }
    
    func enumerateChanges(
        for observer: NSFileProviderChangeObserver,
        from anchor: NSFileProviderSyncAnchor
    ) {
        Task {
            do {
                let prefix: String? = self.drive.syncAnchor.prefix
                
                if self.parent == .trashContainer {
                    // NOTE: skipping trash
                    return observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
                }
        
                // Fetch changes from the server since the anchor timestamp
                let (changedItems, _) = try await self.listS3Items(
                    withS3: self.s3,
                    forDrive: self.drive,
                    withPrefix: prefix,
                    fromDate: anchor.toDate()
                )
                
                guard let changedItems = changedItems else {
                    return observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
                }
                
                observer.didUpdate(changedItems)
                
                // TODO: process remotely deleted files
                // Notify the observer about deletions
                // observer.didDeleteItems(withIdentifiers: deletions)

                let newAnchor = NSFileProviderSyncAnchor(Date())
                
                SharedData.shared.persistSyncAnchor(newAnchor)

                observer.finishEnumeratingChanges(upTo: newAnchor, moreComing: false)
            } catch {
                self.logger.error("An error occurred while enumerating changes: \(error)")
                observer.finishEnumeratingWithError(error)
            }
        }
    }
}

// TODO: Divide enumerators and handle recursion correctly
//class WorkingSetEnumerator: ItemEnumerator {
//    init(connection: DomainConnection) {
//        // Enumerate everything from the root, recursively.
//        super.init(enumeratedItemIdentifier: .rootContainer, connection: connection, recursive: true)
//    }
//}
//
//class TrashEnumerator: ItemEnumerator {
//    init(connection: DomainConnection) {
//        // Enumerate everything from the trash. This isn't recursive;
//        // the File Provider framework asks for subitems if relevant.
//        super.init(enumeratedItemIdentifier: .trashContainer, connection: connection, recursive: false)
//    }
//}
//
