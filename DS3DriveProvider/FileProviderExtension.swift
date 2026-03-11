import FileProvider
import os.log
import SotoS3

class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension /* TODO: handle thumbnails NSFileProviderThumbnailing (check FruitBasket project) */
/* TODO: Handle suppression NSFileProviderUserInteractionSuppressing*/
{
    typealias Logger = os.Logger

    let logger: Logger = Logger(subsystem: LogSubsystem.provider, category: LogCategory.extension.rawValue)

    private let domain: NSFileProviderDomain
    private var enabled: Bool

    private var s3: S3? = nil
    private var s3Lib: S3Lib? = nil

    private var apiKeys: DS3ApiKey? = nil
    private var endpoint: String? = nil
    private var notificationManager: NotificationManager? = nil

    var drive: DS3Drive? = nil
    let temporaryDirectory: URL?

    required init(domain: NSFileProviderDomain) {
        self.enabled = false
        self.domain = domain
        self.temporaryDirectory = try? NSFileProviderManager(for: domain)?.temporaryDirectoryURL()

        do {
            let sharedData = try SharedData.default()

            guard let drive = try sharedData.loadDS3DriveFromPersistence(
                withDomainIdentifier: domain.identifier
            ) else {
                logger.error("No drive found for domain \(domain.identifier.rawValue, privacy: .public)")
                super.init()
                return
            }
            self.drive = drive
            self.notificationManager = NotificationManager(drive: drive)

            let account = try sharedData.loadAccountFromPersistence()
            guard let endpoint = account.endpointGateway else {
                logger.error("No endpoint gateway in account for domain \(domain.identifier.rawValue, privacy: .public)")
                super.init()
                self.notifyInitFailure(reason: "No endpoint gateway configured")
                return
            }
            self.endpoint = endpoint

            let apiKeys = try sharedData.loadDS3APIKeyFromPersistence(
                forUser: drive.syncAnchor.IAMUser,
                projectName: drive.syncAnchor.project.name
            )
            self.apiKeys = apiKeys

            guard let secretKey = apiKeys.secretKey else {
                logger.error("API key has no secret key for domain \(domain.identifier.rawValue, privacy: .public)")
                super.init()
                self.notifyInitFailure(reason: "API key missing secret")
                return
            }

            let client = AWSClient(
                credentialProvider: .static(
                    accessKeyId: apiKeys.apiKey,
                    secretAccessKey: secretKey
                ),
                httpClientProvider: .createNew
            )

            self.s3 = S3(
                client: client,
                endpoint: endpoint,
                timeout: .seconds(DefaultSettings.S3.timeoutInSeconds)
            )

            guard let s3 = self.s3, let notificationManager = self.notificationManager else {
                logger.error("Failed to create S3 client for domain \(domain.identifier.rawValue, privacy: .public)")
                super.init()
                self.notifyInitFailure(reason: "S3 client creation failed")
                return
            }

            self.s3Lib = S3Lib(withS3: s3, withNotificationManager: notificationManager)
            self.enabled = true
            logger.info("Extension initialized successfully for domain \(domain.identifier.rawValue, privacy: .public)")
        } catch {
            logger.error("Extension init failed for domain \(domain.identifier.rawValue, privacy: .public): \(error.localizedDescription)")
            self.notifyInitFailure(reason: error.localizedDescription)
        }

        super.init()
    }

    /// Notifies the main app that the extension failed to initialize
    private func notifyInitFailure(reason: String) {
        DistributedNotificationCenter.default().postNotificationName(
            NSNotification.Name(DefaultSettings.Notifications.extensionInitFailed),
            object: domain.identifier.rawValue,
            userInfo: ["reason": reason],
            deliverImmediately: true
        )
    }

    func invalidate() {
        do {
            if let s3Lib = self.s3Lib {
                try s3Lib.shutdown()
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

        guard let drive = self.drive, let s3Lib = self.s3Lib else {
            completionHandler(nil, NSFileProviderError(.cannotSynchronize) as NSError)
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
                    let metadata = try await s3Lib.remoteS3Item(for: identifier, drive: drive)
                    completionHandler(metadata, nil)
                } catch let s3Error as S3ErrorType {
                    completionHandler(nil, s3Error.toFileProviderError())
                } catch {
                    completionHandler(nil, NSFileProviderError(.cannotSynchronize) as NSError)
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
        guard
            self.enabled,
            let temporaryDirectory = self.temporaryDirectory
        else {
            completionHandler(nil, nil, FileProviderExtensionError.disabled)
            return Progress()
        }

        guard let drive = self.drive, let s3Lib = self.s3Lib, let nm = self.notificationManager else {
            completionHandler(nil, nil, NSFileProviderError(.cannotSynchronize) as NSError)
            return Progress()
        }

        // TODO: The retrieved content at `fileContents` URL must be a regular file on the same volume as the user-visible URL.
        // A suitable location can be retrieved using -[NSFileProviderManager temporaryDirectoryURLWithError:].

        // TODO: Is it handling folders?
        // TODO: Check fetchContents in FruitBasket to check if a fork is better. Also check about incremental fetching
        // TODO: Check fetchPartialContents in FruitBasket

        let progress = Progress(totalUnitCount: 100)

        Task {
            do {
                nm.sendDriveChangedNotification(status: .sync)
                let s3Item = try await s3Lib.remoteS3Item(
                    for: itemIdentifier,
                    drive: drive
                )
                let fileURL = try await s3Lib.getS3Item(
                    s3Item,
                    withTemporaryFolder: temporaryDirectory,
                    withProgress: progress
                )

                self.logger.debug("File \(s3Item.filename, privacy: .public) with size \(s3Item.documentSize, privacy: .public) downloaded successfully at \(fileURL, privacy: .public)")

                nm.sendDriveChangedNotificationWithDebounce(status: .idle)
                completionHandler(fileURL, s3Item, nil)
            } catch let s3Error as S3ErrorType {
                self.logger.error("Download failed with S3 error \(s3Error.errorCode, privacy: .public)")
                nm.sendDriveChangedNotificationWithDebounce(status: .error)
                completionHandler(nil, nil, s3Error.toFileProviderError())
            } catch {
                self.logger.error("Download failed with error \(error)")
                nm.sendDriveChangedNotificationWithDebounce(status: .error)
                completionHandler(nil, nil, NSFileProviderError(.cannotSynchronize) as NSError)
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

        guard let drive = self.drive, let s3Lib = self.s3Lib, let nm = self.notificationManager else {
            completionHandler(nil, [], false, NSFileProviderError(.cannotSynchronize) as NSError)
            return Progress()
        }

        self.logger.debug("Starting upload for item \(itemTemplate.itemIdentifier.rawValue)")

        if options.contains(.mayAlreadyExist) {
            // TODO: Handle create with overwrite
            self.logger.warning("Skipping upload for item \(itemTemplate.itemIdentifier.rawValue, privacy: .public)")
            completionHandler(itemTemplate, NSFileProviderItemFields(), false, NSFileProviderError(.noSuchItem))
            return Progress()
        }

        // TODO: Further improve this
        // TODO: Handle symlinks and aliasFiles (check FruitBasket)
        // Symlinks store their payload in the symlinkTargetPath property of
        // the item. Upload them as item data here (even though they are more
        // similar to an item property), so the server reports them
        // as part of the userInfo on the way back. See DomainService.Entry's
        // database initializer.

        guard itemTemplate.contentType != .symbolicLink else {
            self.logger.warning("Skipping symbolic link \(itemTemplate.itemIdentifier.rawValue, privacy: .public) upload. Feature not supported")
            completionHandler(itemTemplate, NSFileProviderItemFields(), false, NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError, userInfo: [:]))
            return Progress()
        }

        let parentIdentifier = itemTemplate.parentItemIdentifier == .rootContainer ? "" : itemTemplate.parentItemIdentifier.rawValue

        var key = parentIdentifier + itemTemplate.filename

        if let prefix = drive.syncAnchor.prefix {
            if !key.starts(with: prefix) {
                key = prefix + key
            }
        }

        var itemSize = itemTemplate.documentSize ?? 0

        if itemTemplate.contentType == .folder || itemTemplate.contentType == .directory {
            key += String(DefaultSettings.S3.delimiter)
            itemSize = 0
        }

        let s3Item = S3Item(
            identifier: NSFileProviderItemIdentifier(key),
            drive: drive,
            objectMetadata: S3Item.Metadata(size: itemSize ?? 0)
        )

        let numParts = max(Int64(s3Item.documentSize! as! Int / DefaultSettings.S3.multipartUploadPartSize), 1)
        let progress = Progress(totalUnitCount: numParts)

        Task {
            do {
                nm.sendDriveChangedNotification(status: .sync)
                try await s3Lib.putS3Item(s3Item, fileURL: url, withProgress: progress)

                progress.completedUnitCount = numParts
                nm.sendDriveChangedNotificationWithDebounce(status: .idle)
                completionHandler(s3Item, NSFileProviderItemFields(), false, nil)
            } catch let s3Error as S3ErrorType {
                self.logger.error("Upload failed with S3 error \(s3Error.errorCode, privacy: .public)")
                nm.sendDriveChangedNotificationWithDebounce(status: .error)
                completionHandler(nil, NSFileProviderItemFields(), false, s3Error.toFileProviderError())
            } catch {
                self.logger.error("Upload failed with error \(error)")
                nm.sendDriveChangedNotificationWithDebounce(status: .error)
                completionHandler(nil, NSFileProviderItemFields(), false, NSFileProviderError(.cannotSynchronize) as NSError)
            }
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

        guard let drive = self.drive, let s3Lib = self.s3Lib, let nm = self.notificationManager else {
            completionHandler(nil, [], false, NSFileProviderError(.cannotSynchronize) as NSError)
            return Progress()
        }

        let progress = Progress()

        let s3Item = S3Item(
            from: item,
            drive: drive
        )

        // TODO: Handle versioning

        if changedFields.contains(.contents) {
            // Modified
            switch s3Item.contentType {
            case .symbolicLink:
                // TODO: Handle symbolic links
                self.logger.warning("Skipping symbolic link")
                completionHandler(nil, [], false, FileProviderExtensionError.notImplemented)
                return Progress()
            case .folder:
                // NOTE: This should never happen. You can't edit a folder content
                self.logger.error("The system requested to modify a folder with contents. This is impossible!")
                completionHandler(nil, [], false, FileProviderExtensionError.fatal)
                return progress
            default:
                guard let contents = newContents else {
                    completionHandler(nil, [], false, FileProviderExtensionError.fatal)
                    return progress
                }

                // TODO: If the upload succeeds, but the server shouldn't accept new contents (remote timestamp > local timestamp),
                // inform the completion handler that the system no longer needs to apply the contents,
                // but that it needs to refetch them.
                // Report all remaining changes as pending.

                let numParts = Int64(s3Item.documentSize! as! Int / DefaultSettings.S3.multipartUploadPartSize)

                let putProgress = Progress(totalUnitCount: numParts)
                progress.addChild(putProgress, withPendingUnitCount: numParts)

                Task {
                    do {
                        nm.sendDriveChangedNotification(status: .sync)
                        try await s3Lib.putS3Item(s3Item, fileURL: contents, withProgress: putProgress)
                        putProgress.completedUnitCount = numParts
                        nm.sendDriveChangedNotificationWithDebounce(status: .idle)
                        completionHandler(s3Item, NSFileProviderItemFields(), false, nil)
                    } catch let s3Error as S3ErrorType {
                        self.logger.error("Upload failed with S3 error \(s3Error.errorCode, privacy: .public)")
                        nm.sendDriveChangedNotificationWithDebounce(status: .error)
                        completionHandler(nil, NSFileProviderItemFields(), false, s3Error.toFileProviderError())
                    } catch {
                        self.logger.error("Upload failed with error \(error)")
                        nm.sendDriveChangedNotificationWithDebounce(status: .error)
                        completionHandler(nil, NSFileProviderItemFields(), false, NSFileProviderError(.cannotSynchronize) as NSError)
                    }
                }
            }
        } else if changedFields.contains(.filename) {
            // Renamed
            switch s3Item.contentType {
            case .symbolicLink:
                // TODO: Handle symbolic links
                self.logger.warning("Skipping symbolic link")
                completionHandler(nil, [], false, FileProviderExtensionError.notImplemented)
                return progress
            default:
                // File/Folder rename
                self.logger.debug("Rename detected for \(s3Item.itemIdentifier.rawValue) with name \(item.filename, privacy: .public)")

                Task {
                    do {
                        nm.sendDriveChangedNotification(status: .sync)
                        let s3Item = try await s3Lib.renameS3Item(s3Item, newName: item.filename, withProgress: progress)

                        nm.sendDriveChangedNotificationWithDebounce(status: .idle)
                        completionHandler(s3Item, NSFileProviderItemFields(), false, nil)
                    } catch let s3Error as S3ErrorType {
                        self.logger.error("Rename failed with S3 error \(s3Error.errorCode, privacy: .public)")
                        nm.sendDriveChangedNotificationWithDebounce(status: .error)
                        completionHandler(nil, NSFileProviderItemFields(), false, s3Error.toFileProviderError())
                    } catch {
                        self.logger.error("Rename failed with error \(error)")
                        nm.sendDriveChangedNotificationWithDebounce(status: .error)
                        completionHandler(nil, NSFileProviderItemFields(), false, NSFileProviderError(.cannotSynchronize) as NSError)
                    }
                }
            }
        } else if changedFields.contains(.parentItemIdentifier) {
            // Move file/folder
            self.logger.debug("Move detected for key \(s3Item.itemIdentifier.rawValue) from \(s3Item.parentItemIdentifier.rawValue) to \(item.parentItemIdentifier.rawValue)")

//            if options.contains(.mayAlreadyExist) {
//                // TODO: Handle move with overwrite
//                completionHandler(nil, [], false, FileProviderExtensionError.notImplemented)
//            }

            Task {
                do {
                    nm.sendDriveChangedNotification(status: .sync)
                    let newKey = item.parentItemIdentifier.rawValue + s3Item.filename

                    let s3Item = try await s3Lib.moveS3Item(s3Item, toKey: newKey, withProgress: progress)

                    nm.sendDriveChangedNotificationWithDebounce(status: .idle)
                    completionHandler(s3Item, NSFileProviderItemFields(), false, nil)
                } catch let s3Error as S3ErrorType {
                    // TODO: Check why this sometimes fails with NoSuchKey
                    self.logger.error("Move failed with S3 error code \(s3Error.errorCode, privacy: .public)")
                    nm.sendDriveChangedNotificationWithDebounce(status: .error)
                    completionHandler(nil, NSFileProviderItemFields(), false, s3Error.toFileProviderError())
                } catch {
                    self.logger.error("Move failed with error \(error)")
                    nm.sendDriveChangedNotificationWithDebounce(status: .error)
                    completionHandler(nil, NSFileProviderItemFields(), false, NSFileProviderError(.cannotSynchronize) as NSError)
                }
            }
        } else {
            // Metadata changed
            self.logger.debug("Metadata change detected for \(s3Item.filename, privacy: .public). Skipping...")
            completionHandler(s3Item, NSFileProviderItemFields(), false, nil)
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

        guard let drive = self.drive, let s3Lib = self.s3Lib, let nm = self.notificationManager else {
            completionHandler(NSFileProviderError(.cannotSynchronize) as NSError)
            return Progress()
        }

        switch identifier {
        case .trashContainer, .rootContainer:
            self.logger.debug("Skipping deletion of container \(identifier.rawValue, privacy: .public)")
            completionHandler(nil)
            return Progress()
        default:
            // TODO: Handle versioning

            let progress = Progress(totalUnitCount: 1)

            Task {
                do {
                    let s3Item = S3Item(
                        identifier: identifier,
                        drive: drive,
                        objectMetadata: S3Item.Metadata(size: 0)
                    )

                    nm.sendDriveChangedNotification(status: .sync)
                    try await s3Lib.deleteS3Item(s3Item, withProgress: progress)
                    self.logger.debug("S3Item with identifier \(identifier.rawValue, privacy: .public) deleted successfully")

                    progress.completedUnitCount = 1
                    nm.sendDriveChangedNotificationWithDebounce(status: .idle)
                    completionHandler(nil)
                } catch let s3Error as S3ErrorType {
                    self.logger.error("An error occurred while deleting file \(identifier.rawValue, privacy: .public): \(s3Error.errorCode, privacy: .public)")
                    nm.sendDriveChangedNotificationWithDebounce(status: .error)
                    completionHandler(s3Error.toFileProviderError())
                } catch {
                    self.logger.error("An error occurred while deleting file \(identifier.rawValue, privacy: .public): \(error, privacy: .public)")
                    nm.sendDriveChangedNotificationWithDebounce(status: .error)
                    completionHandler(NSFileProviderError(.cannotSynchronize) as NSError)
                }
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
            throw EnumeratorError.unsupported
        }

        guard let drive = self.drive, let s3Lib = self.s3Lib, let nm = self.notificationManager else {
            throw NSFileProviderError(.cannotSynchronize)
        }

        switch containerItemIdentifier {
        case .trashContainer:
            // NOTE: ignoring trash container
            break

        case .workingSet:
            // NOTE: The system is requesting the whole working set (probably to index it via spotlight
            return WorkingSetS3Enumerator(
                parent: containerItemIdentifier,
                s3Lib: s3Lib,
                notificationManager: nm,
                drive: drive
            )

        default:
            // NOTE: The user is navigating the finder
            return S3Enumerator(
                parent: containerItemIdentifier,
                s3Lib: s3Lib,
                notificationManager: nm,
                drive: drive
            )
        }

        throw EnumeratorError.unsupported
    }
}
