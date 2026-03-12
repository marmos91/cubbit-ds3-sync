// swiftlint:disable file_length
@preconcurrency import FileProvider
import os.log
import SotoS3
import DS3Lib
import SwiftData

/// Wraps a non-Sendable callback for safe use across Task boundaries.
/// Apple's File Provider callbacks predate Swift concurrency and lack @Sendable annotations.
/// The wrapper is safe because the underlying handler is set once at init and never mutated.
final class UnsafeCallback<T>: @unchecked Sendable {
    let handler: T
    init(_ handler: T) { self.handler = handler }
}

/// Thread-safe once-only callback guard. Ensures a completion handler is invoked at most once,
/// even when cancellation and async task completion race.
final class OnceGuard: @unchecked Sendable {
    private var called = false
    private let lock = NSLock()

    /// Returns true only on the first call; all subsequent calls return false.
    func tryCall() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !called else { return false }
        called = true
        return true
    }
}

// swiftlint:disable:next type_body_length
class FileProviderExtension: NSObject, @preconcurrency NSFileProviderReplicatedExtension, @unchecked Sendable { /* TODO: handle thumbnails NSFileProviderThumbnailing (check FruitBasket project) */
    typealias Logger = os.Logger

    let logger: Logger = Logger(subsystem: LogSubsystem.provider, category: LogCategory.extension.rawValue)

    private let domain: NSFileProviderDomain
    private var enabled: Bool

    private var s3: S3?
    private var s3Lib: S3Lib?

    private var apiKeys: DS3ApiKey?
    private var endpoint: String?
    private var notificationManager: NotificationManager?
    private var metadataStore: MetadataStore?
    private var syncEngine: SyncEngine?
    private var networkMonitor: NetworkMonitor?

    var drive: DS3Drive?
    let temporaryDirectory: URL?

    required init(domain: NSFileProviderDomain) {
        self.enabled = false
        self.domain = domain
        self.temporaryDirectory = try? NSFileProviderManager(for: domain)?.temporaryDirectoryURL()

        do {
            let sharedData = SharedData.default()

            let drive = try sharedData.loadDS3DriveFromPersistence(
                withDomainIdentifier: domain.identifier
            )
            self.drive = drive
            self.notificationManager = NotificationManager(drive: drive)

            let account = try sharedData.loadAccountFromPersistence()
            self.endpoint = account.endpointGateway

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

            // Initialize MetadataStore, NetworkMonitor, and SyncEngine
            do {
                let container = try MetadataStore.createContainer()
                let store = MetadataStore(modelContainer: container)
                self.metadataStore = store

                let monitor = NetworkMonitor()
                self.networkMonitor = monitor
                Task { await monitor.startMonitoring() }

                self.syncEngine = SyncEngine(metadataStore: store, networkMonitor: monitor)
            } catch {
                logger.warning("Failed to initialize MetadataStore/SyncEngine: \(error.localizedDescription, privacy: .public). Extension will work without sync engine.")
            }

            self.enabled = true
            logger.info("Extension initialized successfully for domain \(domain.identifier.rawValue, privacy: .public)")
        } catch {
            logger.error("Extension init failed for domain \(domain.identifier.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
            super.init()
            self.notifyInitFailure(reason: error.localizedDescription)
            return
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
            try self.s3Lib?.shutdown()
        } catch {
            self.logger.error("An error occurred while shutting down the main extension: \(error.localizedDescription)")
        }

        if let monitor = networkMonitor {
            Task { await monitor.stopMonitoring() }
        }
    }

    // Note: gets called when the extension wants to retrieve metadata for a specific item
    func item(
        for identifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest, // can be used to detect who made the request (finder, spotlight, etc) and act accordingly
        completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        let cb = UnsafeCallback(completionHandler)

        guard self.enabled else {
            cb.handler(nil, NSFileProviderError(.notAuthenticated) as NSError)
            return Progress()
        }

        guard let drive = self.drive, let s3Lib = self.s3Lib else {
            cb.handler(nil, NSFileProviderError(.cannotSynchronize) as NSError)
            return Progress()
        }

        // TODO: Check makeJSONCall pattern in FruitBasket on how to handle async methods

        switch identifier {
        case .trashContainer:
            // NOTE: Trash disabled
            cb.handler(nil, NSFileProviderError(.noSuchItem))
            return Progress()
        default:
            let progress = Progress(totalUnitCount: 1)

            // TODO: Is it handling folders correctly?

            Task {
                do {
                    let metadata = try await s3Lib.remoteS3Item(for: identifier, drive: drive)
                    cb.handler(metadata, nil)
                } catch let s3Error as S3ErrorType {
                    cb.handler(nil, s3Error.toFileProviderError())
                } catch {
                    cb.handler(nil, NSFileProviderError(.cannotSynchronize) as NSError)
                }
                progress.completedUnitCount = 1
            }

            progress.cancellationHandler = { cb.handler(nil, NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)) }

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
        let cb = UnsafeCallback(completionHandler)

        guard
            self.enabled,
            let temporaryDirectory = self.temporaryDirectory
        else {
            cb.handler(nil, nil, NSFileProviderError(.notAuthenticated) as NSError)
            return Progress()
        }

        guard let drive = self.drive, let s3Lib = self.s3Lib, let nm = self.notificationManager else {
            cb.handler(nil, nil, NSFileProviderError(.cannotSynchronize) as NSError)
            return Progress()
        }

        // TODO: The retrieved content at `fileContents` URL must be a regular file on the same volume as the user-visible URL.
        // A suitable location can be retrieved using -[NSFileProviderManager temporaryDirectoryURLWithError:].

        // TODO: Is it handling folders?
        // TODO: Check fetchContents in FruitBasket to check if a fork is better. Also check about incremental fetching
        // TODO: Check fetchPartialContents in FruitBasket

        let progress = Progress(totalUnitCount: 100)
        let metadataStore = self.metadataStore
        Task {
            do {
                nm.sendDriveChangedNotification(status: .sync)
                let s3Item = try await s3Lib.remoteS3Item(
                    for: itemIdentifier,
                    drive: drive
                )

                // Download with exponential backoff retry
                let fileURL = try await withExponentialBackoff(maxRetries: 3, baseDelay: 1.0) {
                    try await s3Lib.getS3Item(
                        s3Item,
                        withTemporaryFolder: temporaryDirectory,
                        withProgress: progress
                    )
                }

                self.logger.debug("File \(s3Item.filename, privacy: .public) with size \(s3Item.documentSize ?? 0, privacy: .public) downloaded successfully at \(fileURL, privacy: .public)")

                // Mark as materialized in MetadataStore
                try? await metadataStore?.setMaterialized(s3Key: itemIdentifier.rawValue, driveId: drive.id, isMaterialized: true)

                nm.sendDriveChangedNotificationWithDebounce(status: .idle)
                cb.handler(fileURL, s3Item, nil)
            } catch let s3Error as S3ErrorType {
                self.logger.error("Download failed with S3 error \(s3Error.errorCode, privacy: .public)")
                nm.sendDriveChangedNotificationWithDebounce(status: .error)
                cb.handler(nil, nil, s3Error.toFileProviderError())
            } catch {
                self.logger.error("Download failed with error \(error)")
                nm.sendDriveChangedNotificationWithDebounce(status: .error)
                cb.handler(nil, nil, NSFileProviderError(.cannotSynchronize) as NSError)
            }

            progress.completedUnitCount = 100
        }

        progress.cancellationHandler = { cb.handler(nil, nil, NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)) }

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
        let cb = UnsafeCallback(completionHandler)

        guard self.enabled else {
            cb.handler(nil, [], false, NSFileProviderError(.notAuthenticated) as NSError)
            return Progress()
        }

        guard let drive = self.drive, let s3Lib = self.s3Lib, let nm = self.notificationManager else {
            cb.handler(nil, [], false, NSFileProviderError(.cannotSynchronize) as NSError)
            return Progress()
        }

        self.logger.debug("Starting upload for item \(itemTemplate.itemIdentifier.rawValue)")

        if options.contains(.mayAlreadyExist) {
            // TODO: Handle create with overwrite
            self.logger.warning("Skipping upload for item \(itemTemplate.itemIdentifier.rawValue, privacy: .public)")
            cb.handler(itemTemplate, NSFileProviderItemFields(), false, NSFileProviderError(.noSuchItem))
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
            cb.handler(itemTemplate, NSFileProviderItemFields(), false, NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError, userInfo: [:]))
            return Progress()
        }

        let parentIdentifier = itemTemplate.parentItemIdentifier == .rootContainer ? "" : itemTemplate.parentItemIdentifier.rawValue

        var key = parentIdentifier + itemTemplate.filename

        if let prefix = drive.syncAnchor.prefix {
            if !key.starts(with: prefix) {
                key = prefix + key
            }
        }

        // documentSize is NSNumber?? (double optional from Obj-C optional protocol property)
        var itemSize: Int
        if let outer = itemTemplate.documentSize, let docSize = outer {
            itemSize = docSize.intValue
        } else {
            itemSize = 0
        }

        if itemTemplate.contentType == .folder || itemTemplate.contentType == .directory {
            key += String(DefaultSettings.S3.delimiter)
            itemSize = 0
        }

        let s3Item = S3Item(
            identifier: NSFileProviderItemIdentifier(key),
            drive: drive,
            objectMetadata: S3Item.Metadata(size: NSNumber(value: itemSize))
        )

        let documentSize = s3Item.documentSize?.intValue ?? 0
        let numParts = max(Int64(documentSize / DefaultSettings.S3.multipartUploadPartSize), 1)
        let progress = Progress(totalUnitCount: numParts)

        Task {
            do {
                nm.sendDriveChangedNotification(status: .sync)
                try await s3Lib.putS3Item(s3Item, fileURL: url, withProgress: progress)

                // Persist item metadata in MetadataStore
                try? await self.metadataStore?.upsertItem(
                    s3Key: key,
                    driveId: drive.id,
                    lastModified: Date(),
                    syncStatus: .synced,
                    parentKey: parentIdentifier.isEmpty ? nil : parentIdentifier,
                    contentType: s3Item.contentType == .folder ? "folder" : nil,
                    size: Int64(itemSize)
                )

                progress.completedUnitCount = numParts
                nm.sendDriveChangedNotificationWithDebounce(status: .idle)
                self.signalChanges()
                cb.handler(s3Item, NSFileProviderItemFields(), false, nil)
            } catch let s3Error as S3ErrorType {
                self.logger.error("Upload failed with S3 error \(s3Error.errorCode, privacy: .public)")
                nm.sendDriveChangedNotificationWithDebounce(status: .error)
                cb.handler(nil, NSFileProviderItemFields(), false, s3Error.toFileProviderError())
            } catch {
                self.logger.error("Upload failed with error \(error)")
                nm.sendDriveChangedNotificationWithDebounce(status: .error)
                cb.handler(nil, NSFileProviderItemFields(), false, NSFileProviderError(.cannotSynchronize) as NSError)
            }
        }

        progress.cancellationHandler = { cb.handler(nil, NSFileProviderItemFields(), false, NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)) }

        return progress
    }

    // NOTE: gets called when the extension wants to modify an item
    // swiftlint:disable:next function_body_length cyclomatic_complexity
    func modifyItem(
        _ item: NSFileProviderItem,
        baseVersion version: NSFileProviderItemVersion,
        changedFields: NSFileProviderItemFields,
        contents newContents: URL?,
        options: NSFileProviderModifyItemOptions = [],
        request: NSFileProviderRequest, // can be used to detect who made the request (finder, spotlight, etc) and act accordingly
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        let cb = UnsafeCallback(completionHandler)

        guard self.enabled else {
            cb.handler(nil, [], false, NSFileProviderError(.notAuthenticated) as NSError)
            return Progress()
        }

        guard let drive = self.drive, let s3Lib = self.s3Lib, let nm = self.notificationManager else {
            cb.handler(nil, [], false, NSFileProviderError(.cannotSynchronize) as NSError)
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
                cb.handler(nil, [], false, NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError, userInfo: [:]))
                return Progress()
            case .folder:
                // NOTE: This should never happen. You can't edit a folder content
                self.logger.error("The system requested to modify a folder with contents. This is impossible!")
                cb.handler(nil, [], false, NSFileProviderError(.cannotSynchronize) as NSError)
                return progress
            default:
                guard let contents = newContents else {
                    cb.handler(nil, [], false, NSFileProviderError(.cannotSynchronize) as NSError)
                    return progress
                }

                // TODO: If the upload succeeds, but the server shouldn't accept new contents (remote timestamp > local timestamp),
                // inform the completion handler that the system no longer needs to apply the contents,
                // but that it needs to refetch them.
                // Report all remaining changes as pending.

                let documentSize = s3Item.documentSize?.intValue ?? 0
                let numParts = max(Int64(documentSize / DefaultSettings.S3.multipartUploadPartSize), 1)

                let putProgress = Progress(totalUnitCount: numParts)
                progress.addChild(putProgress, withPendingUnitCount: numParts)

                Task {
                    do {
                        nm.sendDriveChangedNotification(status: .sync)
                        try await s3Lib.putS3Item(s3Item, fileURL: contents, withProgress: putProgress)

                        // Persist updated metadata
                        try? await self.metadataStore?.upsertItem(
                            s3Key: s3Item.itemIdentifier.rawValue,
                            driveId: drive.id,
                            lastModified: Date(),
                            syncStatus: .synced,
                            size: Int64(documentSize)
                        )

                        putProgress.completedUnitCount = numParts
                        nm.sendDriveChangedNotificationWithDebounce(status: .idle)
                        self.signalChanges()
                        cb.handler(s3Item, NSFileProviderItemFields(), false, nil)
                    } catch let s3Error as S3ErrorType {
                        self.logger.error("Upload failed with S3 error \(s3Error.errorCode, privacy: .public)")
                        nm.sendDriveChangedNotificationWithDebounce(status: .error)
                        cb.handler(nil, NSFileProviderItemFields(), false, s3Error.toFileProviderError())
                    } catch {
                        self.logger.error("Upload failed with error \(error)")
                        nm.sendDriveChangedNotificationWithDebounce(status: .error)
                        cb.handler(nil, NSFileProviderItemFields(), false, NSFileProviderError(.cannotSynchronize) as NSError)
                    }
                }
            }
        } else if changedFields.contains(.filename) {
            // Renamed
            switch s3Item.contentType {
            case .symbolicLink:
                // TODO: Handle symbolic links
                self.logger.warning("Skipping symbolic link")
                cb.handler(nil, [], false, NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError, userInfo: [:]))
                return progress
            default:
                // File/Folder rename
                let newName = item.filename
                self.logger.debug("Rename detected for \(s3Item.itemIdentifier.rawValue) with name \(newName, privacy: .public)")

                let oldKey = s3Item.itemIdentifier.rawValue
                Task {
                    do {
                        nm.sendDriveChangedNotification(status: .sync)
                        let newS3Item = try await s3Lib.renameS3Item(s3Item, newName: newName, withProgress: progress)

                        // Delete old key and upsert new key in MetadataStore
                        try? await self.metadataStore?.deleteItem(byKey: oldKey, driveId: drive.id)
                        try? await self.metadataStore?.upsertItem(
                            s3Key: newS3Item.itemIdentifier.rawValue,
                            driveId: drive.id,
                            syncStatus: .synced
                        )

                        nm.sendDriveChangedNotificationWithDebounce(status: .idle)
                        self.signalChanges()
                        cb.handler(newS3Item, NSFileProviderItemFields(), false, nil)
                    } catch let s3Error as S3ErrorType {
                        self.logger.error("Rename failed with S3 error \(s3Error.errorCode, privacy: .public)")
                        nm.sendDriveChangedNotificationWithDebounce(status: .error)
                        cb.handler(nil, NSFileProviderItemFields(), false, s3Error.toFileProviderError())
                    } catch {
                        self.logger.error("Rename failed with error \(error)")
                        nm.sendDriveChangedNotificationWithDebounce(status: .error)
                        cb.handler(nil, NSFileProviderItemFields(), false, NSFileProviderError(.cannotSynchronize) as NSError)
                    }
                }
            }
        } else if changedFields.contains(.parentItemIdentifier) {
            // Move file/folder
            let destinationParent = item.parentItemIdentifier.rawValue
            self.logger.debug("Move detected for key \(s3Item.itemIdentifier.rawValue) from \(s3Item.parentItemIdentifier.rawValue) to \(destinationParent, privacy: .public)")

//            if options.contains(.mayAlreadyExist) {
//                // TODO: Handle move with overwrite
//                cb.handler(nil, [], false, NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError, userInfo: [:]))
//            }

            let moveOldKey = s3Item.itemIdentifier.rawValue
            Task {
                do {
                    nm.sendDriveChangedNotification(status: .sync)
                    let newKey = destinationParent + s3Item.filename

                    let movedS3Item = try await s3Lib.moveS3Item(s3Item, toKey: newKey, withProgress: progress)

                    // Delete old key and upsert new key in MetadataStore
                    try? await self.metadataStore?.deleteItem(byKey: moveOldKey, driveId: drive.id)
                    try? await self.metadataStore?.upsertItem(
                        s3Key: movedS3Item.itemIdentifier.rawValue,
                        driveId: drive.id,
                        syncStatus: .synced
                    )

                    nm.sendDriveChangedNotificationWithDebounce(status: .idle)
                    self.signalChanges()
                    cb.handler(movedS3Item, NSFileProviderItemFields(), false, nil)
                } catch let s3Error as S3ErrorType {
                    // TODO: Check why this sometimes fails with NoSuchKey
                    self.logger.error("Move failed with S3 error code \(s3Error.errorCode, privacy: .public)")
                    nm.sendDriveChangedNotificationWithDebounce(status: .error)
                    cb.handler(nil, NSFileProviderItemFields(), false, s3Error.toFileProviderError())
                } catch {
                    self.logger.error("Move failed with error \(error)")
                    nm.sendDriveChangedNotificationWithDebounce(status: .error)
                    cb.handler(nil, NSFileProviderItemFields(), false, NSFileProviderError(.cannotSynchronize) as NSError)
                }
            }
        } else {
            // Metadata changed
            self.logger.debug("Metadata change detected for \(s3Item.filename, privacy: .public). Skipping...")
            cb.handler(s3Item, NSFileProviderItemFields(), false, nil)
        }

        progress.cancellationHandler = { cb.handler(nil, NSFileProviderItemFields(), false, NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)) }

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
        let cb = UnsafeCallback(completionHandler)

        guard self.enabled else {
            cb.handler(NSFileProviderError(.notAuthenticated) as NSError)
            return Progress()
        }

        guard let drive = self.drive, let s3Lib = self.s3Lib, let nm = self.notificationManager else {
            cb.handler(NSFileProviderError(.cannotSynchronize) as NSError)
            return Progress()
        }

        switch identifier {
        case .trashContainer, .rootContainer:
            self.logger.debug("Skipping deletion of container \(identifier.rawValue, privacy: .public)")
            cb.handler(nil)
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

                    // Remove from MetadataStore
                    try? await self.metadataStore?.deleteItem(byKey: identifier.rawValue, driveId: drive.id)

                    progress.completedUnitCount = 1
                    nm.sendDriveChangedNotificationWithDebounce(status: .idle)
                    self.signalChanges()
                    cb.handler(nil)
                } catch let s3Error as S3ErrorType {
                    self.logger.error("An error occurred while deleting file \(identifier.rawValue, privacy: .public): \(s3Error.errorCode, privacy: .public)")
                    nm.sendDriveChangedNotificationWithDebounce(status: .error)
                    cb.handler(s3Error.toFileProviderError())
                } catch {
                    self.logger.error("An error occurred while deleting file \(identifier.rawValue, privacy: .public): \(error, privacy: .public)")
                    nm.sendDriveChangedNotificationWithDebounce(status: .error)
                    cb.handler(NSFileProviderError(.cannotSynchronize) as NSError)
                }
            }

            return progress
        }
    }

    /// Signals the system to re-enumerate changes after a local CRUD operation.
    private func signalChanges() {
        guard let manager = NSFileProviderManager(for: self.domain) else {
            logger.warning("Cannot signal enumerator: no manager for domain")
            return
        }

        manager.signalEnumerator(for: .workingSet) { error in
            if let error {
                self.logger.error("Failed to signal working set: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // NOTE: gets called when the extension wants to get an enumerator for a folder
    func enumerator(
        for containerItemIdentifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest // can be used to detect who made the request (finder, spotlight, etc) and act accordingly
    ) throws -> NSFileProviderEnumerator {
        guard self.enabled else {
            throw NSFileProviderError(.notAuthenticated)
        }

        guard let drive = self.drive, let s3Lib = self.s3Lib, let nm = self.notificationManager else {
            throw NSFileProviderError(.cannotSynchronize)
        }

        switch containerItemIdentifier {
        case .trashContainer:
            // NOTE: Trash not supported — return proper NSFileProviderError
            throw NSFileProviderError(.noSuchItem)

        case .workingSet:
            // NOTE: The system is requesting the whole working set (probably to index it via spotlight
            return WorkingSetS3Enumerator(
                parent: containerItemIdentifier,
                s3Lib: s3Lib,
                notificationManager: nm,
                drive: drive,
                syncEngine: self.syncEngine,
                metadataStore: self.metadataStore
            )

        default:
            // NOTE: The user is navigating the finder
            return S3Enumerator(
                parent: containerItemIdentifier,
                s3Lib: s3Lib,
                notificationManager: nm,
                drive: drive,
                syncEngine: self.syncEngine,
                metadataStore: self.metadataStore
            )
        }
    }
}

// MARK: - Partial Content Fetching

extension FileProviderExtension: NSFileProviderPartialContentFetching {
    // swiftlint:disable:next function_parameter_count
    func fetchPartialContents(
        for itemIdentifier: NSFileProviderItemIdentifier,
        version requestedVersion: NSFileProviderItemVersion,
        request: NSFileProviderRequest,
        minimalRange requestedRange: NSRange,
        aligningTo alignment: Int,
        options: NSFileProviderFetchContentsOptions,
        completionHandler: @escaping (URL?, NSFileProviderItem?, NSRange, NSFileProviderMaterializationFlags, Error?) -> Void
    ) -> Progress {
        let cb = UnsafeCallback(completionHandler)

        guard
            self.enabled,
            let temporaryDirectory = self.temporaryDirectory
        else {
            cb.handler(nil, nil, NSRange(location: 0, length: 0), [], NSFileProviderError(.notAuthenticated) as NSError)
            return Progress()
        }

        guard let drive = self.drive, let s3Lib = self.s3Lib, let nm = self.notificationManager else {
            cb.handler(nil, nil, NSRange(location: 0, length: 0), [], NSFileProviderError(.cannotSynchronize) as NSError)
            return Progress()
        }

        let progress = Progress(totalUnitCount: 1)
        let once = OnceGuard()

        let task = Task {
            do {
                nm.sendDriveChangedNotification(status: .sync)

                // Align the requested range to the alignment boundary
                let alignedStart: Int
                if alignment > 0 {
                    alignedStart = (requestedRange.location / alignment) * alignment
                } else {
                    alignedStart = requestedRange.location
                }

                let requestedEnd = requestedRange.location + requestedRange.length - 1
                let alignedEnd: Int
                if alignment > 0 {
                    alignedEnd = ((requestedEnd / alignment) + 1) * alignment - 1
                } else {
                    alignedEnd = requestedEnd
                }

                let alignedRange = NSRange(location: alignedStart, length: alignedEnd - alignedStart + 1)
                let rangeHeader = "bytes=\(alignedStart)-\(alignedEnd)"

                // Download range with exponential backoff retry
                let fileURL = try await withExponentialBackoff(maxRetries: 3, baseDelay: 1.0) {
                    try await s3Lib.getS3ItemRange(
                        identifier: itemIdentifier,
                        drive: drive,
                        range: rangeHeader,
                        temporaryFolder: temporaryDirectory,
                        progress: progress
                    )
                }

                // Get metadata for the item
                let s3Item = try await s3Lib.remoteS3Item(for: itemIdentifier, drive: drive)

                self.logger.debug("Partial download complete for \(s3Item.filename, privacy: .public) range \(rangeHeader, privacy: .public)")

                nm.sendDriveChangedNotificationWithDebounce(status: .idle)
                guard once.tryCall() else { return }
                cb.handler(fileURL, s3Item, alignedRange, [], nil)
            } catch let s3Error as S3ErrorType {
                self.logger.error("Partial download failed with S3 error \(s3Error.errorCode, privacy: .public)")
                nm.sendDriveChangedNotificationWithDebounce(status: .error)
                guard once.tryCall() else { return }
                cb.handler(nil, nil, NSRange(location: 0, length: 0), [], s3Error.toFileProviderError())
            } catch {
                self.logger.error("Partial download failed with error \(error)")
                nm.sendDriveChangedNotificationWithDebounce(status: .error)
                guard once.tryCall() else { return }
                cb.handler(nil, nil, NSRange(location: 0, length: 0), [], NSFileProviderError(.cannotSynchronize) as NSError)
            }
        }

        progress.cancellationHandler = {
            task.cancel()
            guard once.tryCall() else { return }
            cb.handler(nil, nil, NSRange(location: 0, length: 0), [], NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
        }

        return progress
    }
}
