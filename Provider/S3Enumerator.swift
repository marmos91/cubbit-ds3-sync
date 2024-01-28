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
    
    let logger = Logger(subsystem: "io.cubbit.CubbitDS3Sync.provider", category: "S3Enumerator")
    
    private let parent: NSFileProviderItemIdentifier
    private let anchor = SharedData.shared.loadSyncAnchorOrCreate()
    
    private let s3Lib: S3Lib
    private var drive: DS3Drive
    private let recursively: Bool
    private let notificationManager: NotificationManager
    private var prefix: String?
    
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
        s3Lib: S3Lib,
        notificationManager: NotificationManager,
        drive: DS3Drive,
        recursive: Bool = false
    ) {
        self.parent = parent
        self.s3Lib = s3Lib
        self.drive = drive
        self.recursively = recursive
        self.notificationManager = notificationManager
        self.prefix = self.drive.syncAnchor.prefix
        
        switch self.parent {
        case .rootContainer, .trashContainer, .workingSet:
            break
        default:
            self.prefix = parent.rawValue
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
        Task {
            do {
                self.notificationManager.sendDriveChangedNotification(status: .indexing)
                
                let (items, continuationToken) = try await self.s3Lib.listS3Items(
                    forDrive: self.drive,
                    withPrefix: self.prefix,
                    recursively: self.recursively,
                    withContinuationToken: page.toContinuationToken()
                )
                
                if items.count > 0 {
                    observer.didEnumerate(items)
                }
                
                var page: NSFileProviderPage? = nil
                
                if continuationToken != nil {
                    self.logger.debug("Continuation token found \(continuationToken!). Creating new page for enumeration")
                    page = NSFileProviderPage(continuationToken!)
                }
                
                self.notificationManager.sendDriveChangedNotificationWithDebounce(status: .idle)
                return observer.finishEnumerating(upTo: page)
                
            } catch let error as FileProviderExtensionError {
                self.logger.error("A FileProvider error occurred while list objects \(error)")
                self.notificationManager.sendDriveChangedNotificationWithDebounce(status: .error)
                return observer.finishEnumeratingWithError(error.toPresentableError())
            } catch let error as S3ErrorType {
                self.logger.error("A S3 error occurred while list objects \(error)")
                self.notificationManager.sendDriveChangedNotificationWithDebounce(status: .error)
                return observer.finishEnumeratingWithError(error.toPresentableError())
            } catch {
                self.logger.error("A generic error occurred while list objects \(error)")
                self.notificationManager.sendDriveChangedNotificationWithDebounce(status: .error)
                return observer.finishEnumeratingWithError(error)
            }
        }
    }
    
    func enumerateChanges(
        for observer: NSFileProviderChangeObserver,
        from anchor: NSFileProviderSyncAnchor
    ) {
        Task {
            self.notificationManager.sendDriveChangedNotification(status: .indexing)
            
            do {
                self.logger.debug("Enumerating changes for prefix \(self.prefix ?? "nil")")
                
                if self.parent == .trashContainer {
                    // NOTE: skipping trash
                    return observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
                }
                 
                // Fetch changes from the server since the anchor timestamp
                let (changedItems, _) = try await self.s3Lib.listS3Items(
                    forDrive: self.drive,
                    withPrefix: self.prefix,
                    recursively: self.recursively,
                    fromDate: anchor.toDate()
                )

                var newAnchor = anchor
                
                if changedItems.count > 0 {
                    self.logger.debug("Found \(changedItems.count) changes")
                    
                    observer.didUpdate(changedItems)
                    newAnchor = NSFileProviderSyncAnchor(Date())
                    
                    SharedData.shared.persistSyncAnchor(newAnchor)
                }
                
                self.logger.debug("Anchor is \(newAnchor.toDate())")
                
                // TODO: process remotely deleted files
                // Notify the observer about deletions
                // observer.didDeleteItems(withIdentifiers: deletions)

                self.notificationManager.sendDriveChangedNotificationWithDebounce(status: .idle)
                return observer.finishEnumeratingChanges(upTo: newAnchor, moreComing: false)
            } catch {
                self.logger.error("An error occurred while enumerating changes: \(error)")
                self.notificationManager.sendDriveChangedNotificationWithDebounce(status: .error)
                return observer.finishEnumeratingWithError(error)
            }
        }
    }
}

class WorkingSetS3Enumerator: S3Enumerator {
    init(
        parent: NSFileProviderItemIdentifier,
        s3Lib: S3Lib,
        notificationManager: NotificationManager,
        drive: DS3Drive
    ) {
        // Enumerate everything from the root, recursively.
        super.init(
            parent: parent,
            s3Lib: s3Lib,
            notificationManager: notificationManager,
            drive: drive,
            recursive: true
        )
    }
}
