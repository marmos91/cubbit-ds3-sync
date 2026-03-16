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

final class TaskHolder: @unchecked Sendable {
    var task: Task<Void, Never>?
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
    private let hostname: String

    required init(domain: NSFileProviderDomain) {
        self.enabled = false
        self.domain = domain
        self.hostname = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
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
        self.logger.info("Extension invalidating for domain \(self.domain.identifier.rawValue, privacy: .public)")

        do {
            try self.s3Lib?.shutdown()
        } catch {
            self.logger.error("Shutdown failed for domain \(self.domain.identifier.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
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

        self.logger.debug("item(for: \(identifier.rawValue, privacy: .public))")

        switch identifier {
        case .trashContainer:
            // NOTE: Trash disabled
            cb.handler(nil, NSFileProviderError(.noSuchItem))
            return Progress()
        default:
            let progress = Progress(totalUnitCount: 1)
            let guard_ = OnceGuard()

            Task {
                do {
                    let metadata = try await s3Lib.remoteS3Item(for: identifier, drive: drive)
                    guard guard_.tryCall() else { return }
                    cb.handler(metadata, nil)
                } catch let s3Error as S3ErrorType {
                    guard guard_.tryCall() else { return }
                    // Folders in S3 may exist only as common prefixes (no real object).
                    // HeadObject returns NotFound/NoSuchKey for these, but the folder is
                    // valid — return a synthetic S3Item so the system can enumerate it.
                    let isFolder = identifier.rawValue.hasSuffix(String(DefaultSettings.S3.delimiter))

                    if isFolder && s3Error.isNotFound {
                        let folderItem = S3Item(
                            identifier: identifier,
                            drive: drive,
                            objectMetadata: S3Item.Metadata(size: NSNumber(value: 0))
                        )
                        cb.handler(folderItem, nil)
                    } else {
                        cb.handler(nil, s3Error.toFileProviderError())
                    }
                } catch {
                    guard guard_.tryCall() else { return }
                    cb.handler(nil, NSFileProviderError(.cannotSynchronize) as NSError)
                }
                progress.completedUnitCount = 1
            }

            progress.cancellationHandler = {
                guard guard_.tryCall() else { return }
                cb.handler(nil, NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
            }

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

        if (try? SharedData.default().isDrivePaused(drive.id)) == true {
            logger.info("Drive paused, deferring fetchContents operation")
            cb.handler(nil, nil, NSFileProviderError(.serverUnreachable) as NSError)
            return Progress()
        }

        // Folders (keys ending with /) have no downloadable content.
        // Return the folder metadata with nil URL so the system knows the item
        // exists but has no content to download.
        if itemIdentifier.rawValue.hasSuffix(String(DefaultSettings.S3.delimiter)) {
            logger.debug("Skipping fetchContents for folder item: \(itemIdentifier.rawValue, privacy: .public)")
            let folderItem = S3Item(
                identifier: itemIdentifier,
                drive: drive,
                objectMetadata: S3Item.Metadata(size: NSNumber(value: 0))
            )
            cb.handler(nil, folderItem, nil)
            return Progress()
        }

        let progress = Progress(totalUnitCount: 100)
        let metadataStore = self.metadataStore
        let once = OnceGuard()

        let task = Task {
            do {
                nm.sendDriveChangedNotification(status: .sync)

                let (fileURL, s3Item) = try await self.withAPIKeyRecovery {
                    let s3Item = try await self.s3Lib!.remoteS3Item(
                        for: itemIdentifier,
                        drive: drive
                    )

                    // Download with exponential backoff retry
                    let fileURL = try await withExponentialBackoff(maxRetries: 3, baseDelay: 1.0) {
                        try await self.s3Lib!.getS3Item(
                            s3Item,
                            withTemporaryFolder: temporaryDirectory,
                            withProgress: progress
                        )
                    }

                    return (fileURL, s3Item)
                }

                self.logger.info("File \(s3Item.filename, privacy: .public) with size \(s3Item.documentSize ?? 0, privacy: .public) downloaded successfully")

                // Mark as materialized in MetadataStore
                try? await metadataStore?.setMaterialized(s3Key: itemIdentifier.rawValue, driveId: drive.id, isMaterialized: true)

                nm.sendDriveChangedNotificationWithDebounce(status: .idle)
                guard once.tryCall() else { return }
                cb.handler(fileURL, s3Item, nil)
            } catch let s3Error as S3ErrorType {
                self.logger.error("Download failed with S3 error \(s3Error.errorCode, privacy: .public)")
                nm.sendDriveChangedNotificationWithDebounce(status: .error)
                guard once.tryCall() else { return }
                cb.handler(nil, nil, s3Error.toFileProviderError())
            } catch is CancellationError {
                self.logger.debug("Download cancelled for \(itemIdentifier.rawValue, privacy: .public)")
                nm.sendDriveChangedNotificationWithDebounce(status: .idle)
                guard once.tryCall() else { return }
                cb.handler(nil, nil, NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
            } catch {
                self.logger.error("Download failed for \(itemIdentifier.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
                nm.sendDriveChangedNotificationWithDebounce(status: .error)
                guard once.tryCall() else { return }
                cb.handler(nil, nil, NSFileProviderError(.cannotSynchronize) as NSError)
            }
        }

        progress.cancellationHandler = {
            task.cancel()
            guard once.tryCall() else { return }
            cb.handler(nil, nil, NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
        }

        return progress
    }

    // NOTE: gets called when the extension wants to create a new item
    // swiftlint:disable:next function_body_length cyclomatic_complexity
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

        if (try? SharedData.default().isDrivePaused(drive.id)) == true {
            logger.info("Drive paused, deferring createItem operation")
            cb.handler(nil, [], false, NSFileProviderError(.serverUnreachable) as NSError)
            return Progress()
        }

        self.logger.debug("Starting upload for item \(itemTemplate.itemIdentifier.rawValue, privacy: .public)")

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
        let numParts = max(Int64((documentSize + DefaultSettings.S3.multipartUploadPartSize - 1) / DefaultSettings.S3.multipartUploadPartSize), 1)
        let progress = Progress(totalUnitCount: numParts)
        let uploadProgress = Progress(totalUnitCount: numParts)
        progress.addChild(uploadProgress, withPendingUnitCount: numParts)
        let once = OnceGuard()

        let task = Task {
            do {
                nm.sendDriveChangedNotification(status: .sync)

                // --- Conflict detection ---
                if s3Item.contentType != .folder {
                    do {
                        // If HEAD succeeds, the file exists on S3 from another client
                        _ = try await s3Lib.remoteS3Item(
                            for: s3Item.itemIdentifier, drive: drive
                        )

                        self.logger.warning("Create conflict: file already exists on S3 at \(s3Item.itemIdentifier.rawValue, privacy: .public)")

                        let conflictS3Item = try await self.uploadConflictCopy(
                            for: s3Item,
                            fileURL: url,
                            drive: drive,
                            parentKey: parentIdentifier.isEmpty ? nil : parentIdentifier,
                            size: Int64(itemSize),
                            progress: uploadProgress
                        )

                        uploadProgress.completedUnitCount = numParts
                        nm.sendDriveChangedNotificationWithDebounce(status: .idle)
                        self.signalChanges()
                        guard once.tryCall() else { return }
                        cb.handler(conflictS3Item, NSFileProviderItemFields(), false, nil)
                        return
                    } catch is S3ErrorType {
                        // 404/NoSuchKey means file doesn't exist -- proceed with normal create
                        // Any other S3 error also falls through (HEAD is best-effort for createItem)
                    } catch {
                        // Network error during HEAD -- proceed with create (best-effort check)
                        self.logger.debug("Create conflict check failed, proceeding with upload: \(error.localizedDescription, privacy: .public)")
                    }
                }
                // --- End conflict detection ---

                let createETag = try await self.withAPIKeyRecovery {
                    try await s3Lib.putS3Item(s3Item, fileURL: url, withProgress: uploadProgress)
                }

                // Persist item metadata in MetadataStore with ETag
                try? await self.metadataStore?.upsertItem(
                    s3Key: key,
                    driveId: drive.id,
                    etag: ETagUtils.normalize(createETag),
                    lastModified: Date(),
                    syncStatus: .synced,
                    parentKey: parentIdentifier.isEmpty ? nil : parentIdentifier,
                    contentType: s3Item.contentType == .folder ? "folder" : nil,
                    size: Int64(itemSize)
                )

                uploadProgress.completedUnitCount = numParts
                nm.sendDriveChangedNotificationWithDebounce(status: .idle)
                self.signalChanges()
                guard once.tryCall() else { return }
                cb.handler(s3Item, NSFileProviderItemFields(), false, nil)
            } catch let s3Error as S3ErrorType {
                self.logger.error("Upload failed with S3 error \(s3Error.errorCode, privacy: .public)")
                nm.sendDriveChangedNotificationWithDebounce(status: .error)
                guard once.tryCall() else { return }
                cb.handler(nil, NSFileProviderItemFields(), false, s3Error.toFileProviderError())
            } catch is CancellationError {
                self.logger.debug("Upload cancelled for \(key, privacy: .public)")
                nm.sendDriveChangedNotificationWithDebounce(status: .idle)
                guard once.tryCall() else { return }
                cb.handler(nil, NSFileProviderItemFields(), false, NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
            } catch {
                self.logger.error("Upload failed for \(key, privacy: .public): \(error.localizedDescription, privacy: .public)")
                nm.sendDriveChangedNotificationWithDebounce(status: .error)
                guard once.tryCall() else { return }
                cb.handler(nil, NSFileProviderItemFields(), false, NSFileProviderError(.cannotSynchronize) as NSError)
            }
        }

        progress.cancellationHandler = {
            task.cancel()
            guard once.tryCall() else { return }
            cb.handler(nil, NSFileProviderItemFields(), false, NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
        }

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

        if (try? SharedData.default().isDrivePaused(drive.id)) == true {
            logger.info("Drive paused, deferring modifyItem operation")
            cb.handler(nil, [], false, NSFileProviderError(.serverUnreachable) as NSError)
            return Progress()
        }

        let progress = Progress()
        let once = OnceGuard()

        let s3Item = S3Item(
            from: item,
            drive: drive
        )

        // TODO: Handle versioning

        let taskHolder = TaskHolder()

        if changedFields.contains(.contents) {
            // Modified
            switch s3Item.contentType {
            case .symbolicLink:
                self.logger.warning("Skipping symbolic link modify for \(s3Item.itemIdentifier.rawValue, privacy: .public)")
                cb.handler(nil, [], false, NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError, userInfo: [:]))
                return Progress()
            case .folder:
                self.logger.error("Modify with contents requested for folder \(s3Item.itemIdentifier.rawValue, privacy: .public)")
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
                let numParts = max(Int64((documentSize + DefaultSettings.S3.multipartUploadPartSize - 1) / DefaultSettings.S3.multipartUploadPartSize), 1)

                let putProgress = Progress(totalUnitCount: numParts)
                progress.addChild(putProgress, withPendingUnitCount: numParts)

                taskHolder.task = Task {
                    do {
                        nm.sendDriveChangedNotification(status: .sync)

                        // --- Conflict detection ---
                        if s3Item.contentType != .folder {
                            do {
                                let remoteItem = try await s3Lib.remoteS3Item(for: s3Item.itemIdentifier, drive: drive)
                                let remoteETag = remoteItem.metadata.etag
                                let storedETag: String?
                                if let store = self.metadataStore {
                                    storedETag = try? await store.fetchItemEtag(
                                        byKey: s3Item.itemIdentifier.rawValue, driveId: drive.id
                                    )
                                } else {
                                    self.logger.warning("MetadataStore unavailable — skipping modify conflict check for \(s3Item.itemIdentifier.rawValue, privacy: .public)")
                                    storedETag = nil
                                }

                                if let remoteETag, let storedETag, !ETagUtils.areEqual(remoteETag, storedETag) {
                                    self.logger.warning("Modify conflict for \(s3Item.itemIdentifier.rawValue, privacy: .public): remote ETag \(remoteETag, privacy: .public) differs from stored")

                                    let parentKey = s3Item.parentItemIdentifier == .rootContainer ? nil : s3Item.parentItemIdentifier.rawValue
                                    let conflictS3Item = try await self.uploadConflictCopy(
                                        for: s3Item,
                                        fileURL: contents,
                                        drive: drive,
                                        parentKey: parentKey,
                                        size: Int64(documentSize),
                                        progress: putProgress
                                    )

                                    putProgress.completedUnitCount = numParts
                                    nm.sendDriveChangedNotificationWithDebounce(status: .idle)
                                    self.signalChanges()
                                    guard once.tryCall() else { return }
                                    cb.handler(conflictS3Item, NSFileProviderItemFields(), false, nil)
                                    return
                                }
                            } catch let s3Error as S3ErrorType where s3Error.errorCode == "NoSuchKey" || s3Error.errorCode == "NotFound" {
                                // Remote file was deleted -- proceed with normal upload (re-create)
                                self.logger.debug("Conflict check: remote file deleted, proceeding with upload for \(s3Item.itemIdentifier.rawValue, privacy: .public)")
                            } catch let s3Error as S3ErrorType {
                                // Any other S3 error — conflict check is best-effort, proceed with upload
                                self.logger.warning("Conflict check HEAD failed (best-effort, proceeding): \(s3Error.errorCode, privacy: .public)")
                            } catch {
                                // Network error during HEAD — conflict check is best-effort, proceed with upload
                                self.logger.warning("Conflict check failed (best-effort, proceeding) for \(s3Item.itemIdentifier.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
                            }
                        }
                        // --- End conflict detection ---

                        let uploadETag = try await self.withAPIKeyRecovery {
                            try await self.s3Lib!.putS3Item(s3Item, fileURL: contents, withProgress: putProgress)
                        }

                        // Persist updated metadata with ETag
                        try? await self.metadataStore?.upsertItem(
                            s3Key: s3Item.itemIdentifier.rawValue,
                            driveId: drive.id,
                            etag: ETagUtils.normalize(uploadETag),
                            lastModified: Date(),
                            syncStatus: .synced,
                            size: Int64(documentSize)
                        )

                        putProgress.completedUnitCount = numParts
                        nm.sendDriveChangedNotificationWithDebounce(status: .idle)
                        self.signalChanges()
                        guard once.tryCall() else { return }
                        cb.handler(s3Item, NSFileProviderItemFields(), false, nil)
                    } catch let s3Error as S3ErrorType {
                        self.logger.error("Upload failed with S3 error \(s3Error.errorCode, privacy: .public)")
                        nm.sendDriveChangedNotificationWithDebounce(status: .error)
                        guard once.tryCall() else { return }
                        cb.handler(nil, NSFileProviderItemFields(), false, s3Error.toFileProviderError())
                    } catch is CancellationError {
                        self.logger.debug("Modify upload cancelled for \(s3Item.itemIdentifier.rawValue, privacy: .public)")
                        nm.sendDriveChangedNotificationWithDebounce(status: .idle)
                        guard once.tryCall() else { return }
                        cb.handler(nil, NSFileProviderItemFields(), false, NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
                    } catch {
                        self.logger.error("Modify upload failed for \(s3Item.itemIdentifier.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
                        nm.sendDriveChangedNotificationWithDebounce(status: .error)
                        guard once.tryCall() else { return }
                        cb.handler(nil, NSFileProviderItemFields(), false, NSFileProviderError(.cannotSynchronize) as NSError)
                    }
                }
            }
        } else if changedFields.contains(.filename) {
            // Renamed
            switch s3Item.contentType {
            case .symbolicLink:
                self.logger.warning("Skipping symbolic link rename for \(s3Item.itemIdentifier.rawValue, privacy: .public)")
                cb.handler(nil, [], false, NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError, userInfo: [:]))
                return progress
            default:
                // File/Folder rename
                let newName = item.filename
                self.logger.info("Rename detected for \(s3Item.itemIdentifier.rawValue, privacy: .public) with name \(newName, privacy: .public)")

                let oldKey = s3Item.itemIdentifier.rawValue
                taskHolder.task = Task {
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
                        guard once.tryCall() else { return }
                        cb.handler(newS3Item, NSFileProviderItemFields(), false, nil)
                    } catch let s3Error as S3ErrorType {
                        self.logger.error("Rename failed with S3 error \(s3Error.errorCode, privacy: .public)")
                        nm.sendDriveChangedNotificationWithDebounce(status: .error)
                        guard once.tryCall() else { return }
                        cb.handler(nil, NSFileProviderItemFields(), false, s3Error.toFileProviderError())
                    } catch is CancellationError {
                        self.logger.debug("Rename cancelled for \(s3Item.itemIdentifier.rawValue, privacy: .public)")
                        nm.sendDriveChangedNotificationWithDebounce(status: .idle)
                        guard once.tryCall() else { return }
                        cb.handler(nil, NSFileProviderItemFields(), false, NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
                    } catch {
                        self.logger.error("Rename failed for \(oldKey, privacy: .public): \(error.localizedDescription, privacy: .public)")
                        nm.sendDriveChangedNotificationWithDebounce(status: .error)
                        guard once.tryCall() else { return }
                        cb.handler(nil, NSFileProviderItemFields(), false, NSFileProviderError(.cannotSynchronize) as NSError)
                    }
                }
            }
        } else if changedFields.contains(.parentItemIdentifier) {
            // Move file/folder
            let destinationParent = item.parentItemIdentifier == .rootContainer ? "" : item.parentItemIdentifier.rawValue
            self.logger.info("Move detected for key \(s3Item.itemIdentifier.rawValue, privacy: .public) from \(s3Item.parentItemIdentifier.rawValue, privacy: .public) to \(destinationParent, privacy: .public)")

//            if options.contains(.mayAlreadyExist) {
//                // TODO: Handle move with overwrite
//                cb.handler(nil, [], false, NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError, userInfo: [:]))
//            }

            let moveOldKey = s3Item.itemIdentifier.rawValue
            taskHolder.task = Task {
                do {
                    nm.sendDriveChangedNotification(status: .sync)

                    var newKey = destinationParent + s3Item.filename

                    // Preserve trailing slash for folders
                    if s3Item.isFolder && !newKey.hasSuffix(String(DefaultSettings.S3.delimiter)) {
                        newKey += String(DefaultSettings.S3.delimiter)
                    }

                    // Apply drive prefix if needed
                    if let prefix = drive.syncAnchor.prefix, !newKey.starts(with: prefix) {
                        newKey = prefix + newKey
                    }

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
                    guard once.tryCall() else { return }
                    cb.handler(movedS3Item, NSFileProviderItemFields(), false, nil)
                } catch let s3Error as S3ErrorType {
                    // TODO: Check why this sometimes fails with NoSuchKey
                    self.logger.error("Move failed with S3 error code \(s3Error.errorCode, privacy: .public)")
                    nm.sendDriveChangedNotificationWithDebounce(status: .error)
                    guard once.tryCall() else { return }
                    cb.handler(nil, NSFileProviderItemFields(), false, s3Error.toFileProviderError())
                } catch is CancellationError {
                    self.logger.debug("Move cancelled for \(s3Item.itemIdentifier.rawValue, privacy: .public)")
                    nm.sendDriveChangedNotificationWithDebounce(status: .idle)
                    guard once.tryCall() else { return }
                    cb.handler(nil, NSFileProviderItemFields(), false, NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
                } catch {
                    self.logger.error("Move failed for \(moveOldKey, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    nm.sendDriveChangedNotificationWithDebounce(status: .error)
                    guard once.tryCall() else { return }
                    cb.handler(nil, NSFileProviderItemFields(), false, NSFileProviderError(.cannotSynchronize) as NSError)
                }
            }
        } else {
            // Metadata changed
            self.logger.debug("Metadata change detected for \(s3Item.filename, privacy: .public). Skipping...")
            cb.handler(s3Item, NSFileProviderItemFields(), false, nil)
            return progress
        }

        progress.cancellationHandler = {
            taskHolder.task?.cancel()
            guard once.tryCall() else { return }
            cb.handler(nil, NSFileProviderItemFields(), false, NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
        }

        return progress
    }

    // NOTE: gets called when the extension wants to delete an item
    // swiftlint:disable:next function_body_length cyclomatic_complexity
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
            let once = OnceGuard()

            let task = Task {
                do {
                    let s3Item = S3Item(
                        identifier: identifier,
                        drive: drive,
                        objectMetadata: S3Item.Metadata(size: 0)
                    )

                    // Skip conflict check for folder keys (ending with "/")
                    let isFolder = identifier.rawValue.hasSuffix(String(DefaultSettings.S3.delimiter))

                    if !isFolder {
                        // --- Conflict detection ---
                        do {
                            let remoteItem = try await s3Lib.remoteS3Item(for: identifier, drive: drive)
                            let remoteETag = remoteItem.metadata.etag
                            let storedETag: String?
                            if let store = self.metadataStore {
                                storedETag = try? await store.fetchItemEtag(
                                    byKey: identifier.rawValue, driveId: drive.id
                                )
                            } else {
                                self.logger.warning("MetadataStore unavailable — skipping delete conflict check for \(identifier.rawValue, privacy: .public)")
                                storedETag = nil
                            }

                            if let remoteETag, let storedETag, !ETagUtils.areEqual(remoteETag, storedETag) {
                                // Remote was modified since last sync -- cancel delete
                                self.logger.warning("Delete cancelled: remote ETag changed for \(identifier.rawValue, privacy: .public)")
                                nm.sendDriveChangedNotificationWithDebounce(status: .idle)
                                self.signalChanges()
                                guard once.tryCall() else { return }
                                cb.handler(NSFileProviderError(.cannotSynchronize) as NSError)
                                return
                            }
                        } catch let s3Error as S3ErrorType where s3Error.errorCode == "NoSuchKey" || s3Error.errorCode == "NotFound" {
                            // Both sides deleted -- treat as success
                            self.logger.debug("File already deleted remotely: \(identifier.rawValue, privacy: .public)")
                            try? await self.metadataStore?.deleteItem(byKey: identifier.rawValue, driveId: drive.id)
                            progress.completedUnitCount = 1
                            nm.sendDriveChangedNotificationWithDebounce(status: .idle)
                            self.signalChanges()
                            guard once.tryCall() else { return }
                            cb.handler(nil)
                            return
                        } catch {
                            // HEAD failed (network) -- return transient error for retry
                            self.logger.error("Delete conflict check HEAD failed for \(identifier.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
                            nm.sendDriveChangedNotificationWithDebounce(status: .error)
                            guard once.tryCall() else { return }
                            cb.handler(NSFileProviderError(.serverUnreachable) as NSError)
                            return
                        }
                        // --- End conflict detection ---
                    }

                    nm.sendDriveChangedNotification(status: .sync)
                    try await self.withAPIKeyRecovery {
                        try await self.s3Lib!.deleteS3Item(s3Item, withProgress: progress)
                    }
                    self.logger.info("S3Item with identifier \(identifier.rawValue, privacy: .public) deleted successfully")

                    // Remove from MetadataStore
                    try? await self.metadataStore?.deleteItem(byKey: identifier.rawValue, driveId: drive.id)

                    progress.completedUnitCount = 1
                    nm.sendDriveChangedNotificationWithDebounce(status: .idle)
                    self.signalChanges()
                    guard once.tryCall() else { return }
                    cb.handler(nil)
                } catch let s3Error as S3ErrorType where s3Error.errorCode == "NoSuchKey" || s3Error.errorCode == "NotFound" {
                    // Both sides deleted during the race -- treat as success
                    self.logger.debug("File deleted remotely during our delete: \(identifier.rawValue, privacy: .public)")
                    try? await self.metadataStore?.deleteItem(byKey: identifier.rawValue, driveId: drive.id)
                    progress.completedUnitCount = 1
                    nm.sendDriveChangedNotificationWithDebounce(status: .idle)
                    self.signalChanges()
                    guard once.tryCall() else { return }
                    cb.handler(nil)
                } catch let s3Error as S3ErrorType {
                    self.logger.error("An error occurred while deleting file \(identifier.rawValue, privacy: .public): \(s3Error.errorCode, privacy: .public)")
                    nm.sendDriveChangedNotificationWithDebounce(status: .error)
                    guard once.tryCall() else { return }
                    cb.handler(s3Error.toFileProviderError())
                } catch is CancellationError {
                    self.logger.debug("Delete cancelled for \(identifier.rawValue, privacy: .public)")
                    nm.sendDriveChangedNotificationWithDebounce(status: .idle)
                    guard once.tryCall() else { return }
                    cb.handler(NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
                } catch {
                    self.logger.error("An error occurred while deleting file \(identifier.rawValue, privacy: .public): \(error, privacy: .public)")
                    nm.sendDriveChangedNotificationWithDebounce(status: .error)
                    guard once.tryCall() else { return }
                    cb.handler(NSFileProviderError(.cannotSynchronize) as NSError)
                }
            }

            progress.cancellationHandler = {
                task.cancel()
                guard once.tryCall() else { return }
                cb.handler(NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
            }

            return progress
        }
    }

    /// Uploads a local file as a conflict copy, records metadata, and sends a user notification.
    ///
    /// - Parameters:
    ///   - s3Item: The original item that triggered the conflict
    ///   - fileURL: The local file to upload as the conflict copy
    ///   - drive: The drive where the conflict occurred
    ///   - parentKey: The parent key for MetadataStore, or `nil` for root items
    ///   - size: The file size in bytes
    ///   - progress: Progress object for tracking the upload
    /// - Returns: The conflict copy S3Item with its conflict key
    private func uploadConflictCopy(
        for s3Item: S3Item,
        fileURL: URL?,
        drive: DS3Drive,
        parentKey: String?,
        size: Int64,
        progress: Progress
    ) async throws -> S3Item {
        guard let s3Lib, let nm = notificationManager else {
            throw NSFileProviderError(.cannotSynchronize) as NSError
        }

        let conflictKey = ConflictNaming.conflictKey(
            originalKey: s3Item.itemIdentifier.rawValue,
            hostname: self.hostname,
            date: Date()
        )
        let conflictS3Item = S3Item(
            identifier: NSFileProviderItemIdentifier(conflictKey),
            drive: drive,
            objectMetadata: s3Item.metadata
        )

        let conflictETag = try await withRetries(retries: 3) {
            try await s3Lib.putS3Item(conflictS3Item, fileURL: fileURL, withProgress: progress)
        }

        try? await self.metadataStore?.upsertItem(
            s3Key: conflictKey,
            driveId: drive.id,
            etag: ETagUtils.normalize(conflictETag),
            lastModified: Date(),
            syncStatus: .conflict,
            parentKey: parentKey,
            size: size
        )

        nm.sendConflictNotification(filename: s3Item.filename, conflictKey: conflictKey)

        return conflictS3Item
    }

    /// Signals the system to re-enumerate changes after a local CRUD operation.
    private func signalChanges() {
        guard let manager = NSFileProviderManager(for: self.domain) else {
            logger.warning("Cannot signal enumerator: no manager for domain \(self.domain.identifier.rawValue, privacy: .public)")
            return
        }

        manager.signalEnumerator(for: .workingSet) { error in
            if let error {
                self.logger.error("Failed to signal working set: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - S3 Credential Reload

    /// Re-reads the API key from SharedData and reinitializes the S3 client if the key has changed.
    /// This handles the case where the main app has already fixed/rotated the credentials.
    /// - Returns: `true` if credentials were reloaded, `false` if unchanged or unavailable.
    @discardableResult
    private func reloadS3CredentialsIfNeeded() -> Bool {
        guard let drive = self.drive else { return false }

        guard let freshKey = try? SharedData.default().loadDS3APIKeyFromPersistence(
            forUser: drive.syncAnchor.IAMUser,
            projectName: drive.syncAnchor.project.name
        ) else { return false }

        // Only reload if the key actually changed
        guard freshKey.apiKey != self.apiKeys?.apiKey, let secretKey = freshKey.secretKey else {
            return false
        }

        try? self.s3Lib?.shutdown()

        let client = AWSClient(
            credentialProvider: .static(accessKeyId: freshKey.apiKey, secretAccessKey: secretKey),
            httpClientProvider: .createNew
        )
        let s3 = S3(client: client, endpoint: self.endpoint, timeout: .seconds(DefaultSettings.S3.timeoutInSeconds))

        self.s3 = s3
        self.apiKeys = freshKey
        if let nm = self.notificationManager {
            self.s3Lib = S3Lib(withS3: s3, withNotificationManager: nm)
        }

        self.logger.info("S3 credentials reloaded from SharedData")
        return true
    }

    // MARK: - S3 Auth Error Recovery

    /// Wraps an S3 operation with credential reload and retry on auth errors.
    /// On recoverable S3 auth errors (InvalidAccessKeyId, SignatureDoesNotMatch),
    /// attempts to reload credentials from SharedData (in case the main app already fixed them).
    /// If reload doesn't help, notifies the main app and returns `.notAuthenticated`.
    private func withAPIKeyRecovery<T>(
        operation: @escaping () async throws -> T
    ) async throws -> T {
        // Check if main app has updated credentials since our last load
        _ = reloadS3CredentialsIfNeeded()

        do {
            return try await operation()
        } catch let s3Error as S3ErrorType where S3ErrorRecovery.isRecoverableAuthError(s3Error.errorCode) {
            // Try reloading one more time in case main app just fixed them
            if reloadS3CredentialsIfNeeded() {
                self.logger.info("Retrying after credential reload")
                return try await operation()
            }

            self.logger.error("S3 auth error: \(s3Error.errorCode, privacy: .public). Notifying main app.")
            self.notificationManager?.sendAuthFailureNotification(
                domainId: self.domain.identifier.rawValue,
                reason: "s3AuthError"
            )
            throw NSFileProviderError(.notAuthenticated) as NSError
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

        self.logger.debug("enumerator(for: \(containerItemIdentifier.rawValue, privacy: .public))")

        guard let drive = self.drive, let s3Lib = self.s3Lib, let nm = self.notificationManager else {
            throw NSFileProviderError(.cannotSynchronize)
        }

        switch containerItemIdentifier {
        case .trashContainer:
            // Trash not supported — return an empty enumerator to avoid FP -1005 errors
            return EmptyEnumerator()

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

                self.logger.info("Partial download complete for \(s3Item.filename, privacy: .public) range \(rangeHeader, privacy: .public)")

                nm.sendDriveChangedNotificationWithDebounce(status: .idle)
                guard once.tryCall() else { return }
                cb.handler(fileURL, s3Item, alignedRange, [], nil)
            } catch let s3Error as S3ErrorType {
                self.logger.error("Partial download failed with S3 error \(s3Error.errorCode, privacy: .public)")
                nm.sendDriveChangedNotificationWithDebounce(status: .error)
                guard once.tryCall() else { return }
                cb.handler(nil, nil, NSRange(location: 0, length: 0), [], s3Error.toFileProviderError())
            } catch {
                self.logger.error("Partial download failed for \(itemIdentifier.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
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
