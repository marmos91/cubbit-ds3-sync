import FileProvider
import os.log
import SotoS3

// TODO: Add Error to presentable extension (check FruitBasket)
class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension /* TODO: handle thumbnails NSFileProviderThumbnailing (check FruitBasket project) */
/* TODO: Handle suppression NSFileProviderUserInteractionSuppressing*/
{
    typealias Logger = os.Logger
    
    private var logger: Logger = Logger(subsystem: "io.cubbit.CubbitDS3Sync.provider", category: "main")
    private let domain: NSFileProviderDomain
    private var enabled: Bool
    
    private var drive: DS3Drive? = nil
    private var s3: S3? = nil
    
    private var apiKeys: DS3ApiKey? = nil
    private var endpoint: String? = nil
    
    let temporaryDirectory: URL
    
    required init(domain: NSFileProviderDomain) {
        self.enabled = false
        self.domain = domain
        self.temporaryDirectory = temporaryDirectoryURL()
        
        do {
            self.drive = try SharedData.shared.loadDS3DriveFromPersistence(withDomainIdentifier: domain.identifier)
            self.endpoint = try SharedData.shared.loadAccountFromPersistence().endpointGateway
            self.apiKeys = try SharedData.shared.loadDS3APIKeyFromPersistence(
                forUser: self.drive!.syncAnchor.IAMUser,
                projectName: self.drive!.syncAnchor.project.name
            )
            
            let client = AWSClient(
                credentialProvider: .static(
                    accessKeyId: self.apiKeys!.apiKey,
                    secretAccessKey: self.apiKeys!.secretKey!
                ),
                httpClientProvider: .createNew
            )
            
            self.s3 = S3(
                client: client, 
                endpoint: self.endpoint!,
                timeout: .seconds(DefaultSettings.S3.timeoutInSeconds)
            )
            
            // TODO: Look for changes in the sharedDefaults to update
//            observation = observedDefaults.observe(\.blockedProcesses, options: [.initial, .new]) { _, change in
//                UserDefaults().setValue(change.newValue ?? [], forKey: "NSFileProviderExtensionNonMaterializingProcessNames")
//            }
            
            self.enabled = true
        } catch {
            self.logger.error("An error occurred while initializing extension: \(error.localizedDescription)")
        }
        
        super.init()
    }
    
    func invalidate() {
        do {
            if let s3 = self.s3 {
                try s3.client.syncShutdown()
            }
            
        } catch let error {
            self.logger.error("An error occured while shutting down the main extension: \(error.localizedDescription)")
        }
    }
    
    // Note: gets called when the extension wants to retrieve metadata for a specific item
    func item(
        for identifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest, // can be used to detect who made the request (finder, spotlight, etc) and act accordingly
        completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        guard self.enabled else {
            completionHandler(nil, FileProviderExtensionError.disabled)
            return Progress()
        }
        
        // TODO: Check makeJSONCall pattern in FruitBasket on how to handle async methods
        
        switch identifier {
        case .trashContainer:
            // NOTE: Trash disabled
            completionHandler(nil, NSFileProviderError(.noSuchItem))
            return Progress()
        default:
            let progress = Progress(totalUnitCount: 1)
            
            // TODO: Is it handling folders correctly?
            
            Task {
                do {
                    let metadata = try await self.remoteS3Item(for: identifier, withS3: self.s3!, drive: self.drive!)
                    completionHandler(metadata, nil)
                } catch {
                    completionHandler(nil, error)
                }
                progress.completedUnitCount = 1
            }
            
            progress.cancellationHandler = { completionHandler(nil, NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)) }
            
            return progress
        }
    }
    
    // NOTE: gets called when the extension wants to retrieve the contents of a specific item
    func fetchContents(
        for itemIdentifier: NSFileProviderItemIdentifier,
        version requestedVersion: NSFileProviderItemVersion?,
        request: NSFileProviderRequest, // can be used to detect who made the request (finder, spotlight, etc) and act accordingly
        completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        guard self.enabled else {
            completionHandler(nil, nil, FileProviderExtensionError.disabled)
            return Progress()
        }
        
        // TODO: Is it handling folders?
        // TODO: Check fetchContents in FruitBasket to check if a fork is better. Also check about incremental fetching
        // TODO: Check fetchPartialContents in FruitBasket
        
        let progress = Progress(totalUnitCount: 100)
        
        self.logger.debug("Should download item with identifier \(itemIdentifier.rawValue, privacy: .public)")
        
        Task {
            do {
                let s3Item = try await self.remoteS3Item(for: itemIdentifier, withS3: self.s3!, drive: self.drive!)
                let fileURL = try await self.getS3Item(s3Item, withS3: self.s3!, withProgress: progress)
                
                self.logger.debug("File \(s3Item.filename, privacy: .public) with size \(s3Item.documentSize, privacy: .public) downloaded successfully at \(fileURL, privacy: .public)")
                
                completionHandler(fileURL, s3Item, nil)
            } catch {
                self.logger.error("Download failed with error \(error)")
                completionHandler(nil, nil, error)
            }
            
            progress.completedUnitCount = 100
        }
        
        progress.cancellationHandler = { completionHandler(nil, nil, NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)) }
        
        return progress
    }
    
    // NOTE: gets called when the extension wants to create a new item
    func createItem(
        basedOn itemTemplate: NSFileProviderItem,
        fields: NSFileProviderItemFields,
        contents url: URL?,
        options: NSFileProviderCreateItemOptions = [],
        request: NSFileProviderRequest, // can be used to detect who made the request (finder, spotlight, etc) and act accordingly
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        guard self.enabled else {
            completionHandler(nil, [], false, FileProviderExtensionError.disabled)
            return Progress()
        }
        
        // TODO: Further improve this
        // TODO: Handle symlinks and aliasFiles (check FruitBasket)
        // Symlinks store their payload in the symlinkTargetPath property of
        // the item. Upload them as item data here (even though they are more
        // similar to an item property), so the server reports them
        // as part of the userInfo on the way back. See DomainService.Entry's
        // database initializer.
        
        // TODO: Only upload files if they have content (check FruitBasket)
        
        guard itemTemplate.contentType != .symbolicLink else {
            self.logger.warning("Skipping symbolic link \(itemTemplate.itemIdentifier.rawValue, privacy: .public) upload. Feature not supported")
            completionHandler(itemTemplate, NSFileProviderItemFields(), false, NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError, userInfo: [:]))
            return Progress()
        }
    
        let parentIdentifier = itemTemplate.parentItemIdentifier == .rootContainer ? "" : itemTemplate.parentItemIdentifier.rawValue
        
        let itemTemplateIsFolder = itemTemplate.contentType == .folder ||
                                   itemTemplate.contentType == .directory
        
        let key = parentIdentifier + itemTemplate.filename
        
        if itemTemplateIsFolder {
            self.logger.debug("Should create folder for key \(key, privacy: .public)")
            
            let folder = S3Item(
                identifier: NSFileProviderItemIdentifier(key + String(DefaultSettings.S3.delimiter)),
                drive: self.drive!,
                objectMetadata: S3Item.Metadata(size: 0)
            )
           
            Task {
                do {
                    try await self.putS3ItemStandard(folder, withS3: self.s3!, withLogger: self.logger)
                    completionHandler(folder, NSFileProviderItemFields(), false, nil)
                } catch {
                    self.logger.error("Folder creation failed with error \(error)")
                    completionHandler(nil, NSFileProviderItemFields(), false, error)
                }
            }
            
            return Progress()
        }
        
        if options.contains(.mayAlreadyExist) {
            self.logger.warning("Skipping item \(itemTemplate.itemIdentifier.rawValue, privacy: .public)")
            completionHandler(itemTemplate, NSFileProviderItemFields(), false, NSFileProviderError(.noSuchItem))
            return Progress()
        }
        
        let s3Item = S3Item(
            identifier: NSFileProviderItemIdentifier(key),
            drive: self.drive!,
            objectMetadata: S3Item.Metadata(size: itemTemplate.documentSize!!)
        )
        
        self.logger.debug("Should upload item with key \(key), privacy: .public) and filename \(itemTemplate.filename, privacy: .public) with size \(itemTemplate.documentSize!, privacy: .public)")
        
        let numParts = Int64(s3Item.documentSize! as! Int / DefaultSettings.S3.multipartUploadPartSize)
        let progress = Progress(totalUnitCount: numParts)
        
        Task {
            do {
                try await self.putS3Item(s3Item, withS3: self.s3!, fileURL: url, withProgress: progress, withLogger: self.logger)
                completionHandler(s3Item, NSFileProviderItemFields(), false, nil)
            } catch {
                self.logger.error("Upload failed with error \(error)")
                completionHandler(nil, NSFileProviderItemFields(), false, error)
            }
            
            progress.completedUnitCount = numParts
        }
        
        progress.cancellationHandler = { completionHandler(nil, NSFileProviderItemFields(), false, NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)) }
        
        return progress
    }
    
    // NOTE: gets called when the extension wants to modify an item
    func modifyItem(
        _ item: NSFileProviderItem,
        baseVersion version: NSFileProviderItemVersion,
        changedFields: NSFileProviderItemFields,
        contents newContents: URL?,
        options: NSFileProviderModifyItemOptions = [],
        request: NSFileProviderRequest, // can be used to detect who made the request (finder, spotlight, etc) and act accordingly
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        guard self.enabled else {
            completionHandler(nil, [], false, FileProviderExtensionError.disabled)
            return Progress()
        }
        
        if newContents == nil {
            completionHandler(item, NSFileProviderItemFields(), false, nil)
            return Progress()
        }
        
        // TODO: Handle versioning
        // TODO: Handle metadata changes
        // TODO: Is it handling folders?
        
        self.logger.debug("Should upload modified file \(item.filename, privacy: .public)")
        
        let s3Item = S3Item(
            identifier: item.itemIdentifier,
            drive: self.drive!,
            objectMetadata: S3Item.Metadata(size: item.documentSize!!)
        )
        
        let numParts = Int64(s3Item.documentSize! as! Int / DefaultSettings.S3.multipartUploadPartSize)
        let progress = Progress(totalUnitCount: numParts)
        
        Task {
            do {
                try await self.putS3Item(s3Item, withS3: self.s3!, fileURL: newContents, withProgress: progress, withLogger: self.logger)
                completionHandler(s3Item, NSFileProviderItemFields(), false, nil)
            } catch {
                self.logger.error("Upload failed with error \(error)")
                completionHandler(nil, NSFileProviderItemFields(), false, error)
            }
            
            progress.completedUnitCount = numParts
        }
        
        progress.cancellationHandler = { completionHandler(nil, NSFileProviderItemFields(), false, NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)) }
        
        return progress
    }
    
    // NOTE: gets called when the extension wants to delete an item
    func deleteItem(
        identifier: NSFileProviderItemIdentifier,
        baseVersion version: NSFileProviderItemVersion,
        options: NSFileProviderDeleteItemOptions = [],
        request: NSFileProviderRequest, // can be used to detect who made the request (finder, spotlight, etc) and act accordingly
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        guard self.enabled else {
            completionHandler(FileProviderExtensionError.disabled)
            return Progress()
        }
        
        switch identifier {
        case .trashContainer, .rootContainer:
            self.logger.debug("Skipping deletion of container \(identifier.rawValue, privacy: .public)")
            completionHandler(nil)
            return Progress()
        default:
            self.logger.debug("Should delete file \(identifier.rawValue, privacy: .public)")
            
            // TODO: Handle versioning
            // TODO: Is it handling folders?
            
            let progress = Progress(totalUnitCount: 1)
            
            Task {
                do {
                    let s3Item = S3Item(
                        identifier: identifier,
                        drive: self.drive!,
                        objectMetadata: S3Item.Metadata(size: 0)
                    )
                    
                    try await self.deleteS3Item(s3Item, withS3: self.s3!)
                    
                    self.logger.debug("S3Item with identifier \(identifier.rawValue, privacy: .public) deleted successfully")
                    completionHandler(nil)
                } catch {
                    self.logger.error("An error occurred while deleting file \(identifier.rawValue, privacy: .public): \(error, privacy: .public)")
                    completionHandler(error)
                }
                
                progress.completedUnitCount = 1
            }
            
            return progress
        }
    }
    
    // NOTE: gets called when the extension wants to get an enumerator for a folder
    func enumerator(
        for containerItemIdentifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest // can be used to detect who made the request (finder, spotlight, etc) and act accordingly
    ) throws -> NSFileProviderEnumerator {
        guard self.enabled else {
            throw EnumeratorError.unsopported
        }
        
        switch containerItemIdentifier {
        case .trashContainer:
            // NOTE: ignoring trash container
            break
            
        case .workingSet:
            // NOTE: The system is requesting the whole working set (probably to index it via spotlight
            return WorkingSetS3Enumerator(
                parent: containerItemIdentifier,
                s3: self.s3!,
                drive: self.drive!
            )
            
        default:
            // NOTE: The user is navigating the finder
            return S3Enumerator(
                parent: containerItemIdentifier,
                s3: self.s3!,
                drive: self.drive!
            )
        }
        
        throw EnumeratorError.unsopported
    }
}
