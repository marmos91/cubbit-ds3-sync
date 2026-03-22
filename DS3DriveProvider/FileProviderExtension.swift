// swiftlint:disable file_length
@preconcurrency import FileProvider
import os.log
import SotoS3
import DS3Lib
import SwiftData
import ImageIO
import UniformTypeIdentifiers

/// Wraps a non-Sendable value for use in `sending` closures where thread safety is
/// guaranteed by the call-site structure (e.g. completion handlers called exactly once).
struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
}

/// Simple actor-based counting semaphore for limiting concurrent async operations.
actor AsyncSemaphore {
    private var permits: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(value: Int) {
        self.permits = value
    }

    func wait() async {
        if permits > 0 {
            permits -= 1
        } else {
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }
    }

    func signal() {
        if waiters.isEmpty {
            permits += 1
        } else {
            let continuation = waiters.removeFirst()
            continuation.resume()
        }
    }
}

// swiftlint:disable:next type_body_length
class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension, NSFileProviderCustomAction, NSFileProviderThumbnailing, @unchecked Sendable {
    typealias Logger = os.Logger

    let logger: Logger = Logger(subsystem: LogSubsystem.provider, category: LogCategory.extension.rawValue)

    let domain: NSFileProviderDomain
    private var enabled: Bool

    private var s3: S3?
    private var s3Lib: S3Lib?

    private var apiKeys: DS3ApiKey?
    private var endpoint: String?
    private var notificationManager: NotificationManager?
    var metadataStore: MetadataStore?
    private var syncEngine: SyncEngine?
    private var networkMonitor: NetworkMonitor?
    private var pollingTask: Task<Void, Never>?

    /// Proactive breadth-first indexer that populates MetadataStore level-by-level.
    private var breadthFirstIndexer: BreadthFirstIndexer?

    /// Limits concurrent fetchContents/fetchPartialContents calls to prevent
    /// HTTP/2 stream exhaustion (NIOHTTP2.StreamClosed errors).
    #if os(iOS)
    private let fetchSemaphore = AsyncSemaphore(value: 4)
    #else
    private let fetchSemaphore = AsyncSemaphore(value: 20)
    #endif

    var drive: DS3Drive?
    let temporaryDirectory: URL?
    let systemService: any SystemService
    let ipcService: any IPCService

    required init(domain: NSFileProviderDomain) {
        self.enabled = false
        self.domain = domain
        self.systemService = makeDefaultSystemService()
        self.ipcService = makeDefaultIPCService()
        self.temporaryDirectory = try? NSFileProviderManager(for: domain)?.temporaryDirectoryURL()

        do {
            let sharedData = SharedData.default()

            let drive = try sharedData.loadDS3DriveFromPersistence(
                withDomainIdentifier: domain.identifier
            )
            self.drive = drive
            self.notificationManager = NotificationManager(drive: drive, ipcService: self.ipcService)

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
        self.startPolling()
        self.warmCacheThenStartBFS()

        // If drive is paused, notify the main app so UI reflects the state
        if let driveId = self.drive?.id,
           (try? SharedData.default().isDrivePaused(driveId)) == true {
            Task { await self.notificationManager?.sendDriveChangedNotification(status: .paused) }
        }

        logMemoryUsage(label: "init-complete", logger: logger)
    }

    /// Notifies the main app that the extension failed to initialize
    private func notifyInitFailure(reason: String) {
        Task { [ipcService, domain] in
            await ipcService.postExtensionInitFailure(domainId: domain.identifier.rawValue, reason: reason)
        }
    }

    func invalidate() {
        self.logger.info("Extension invalidating for domain \(self.domain.identifier.rawValue, privacy: .public)")
        self.logger.debug("Stopping periodic polling task")
        self.pollingTask?.cancel()
        self.pollingTask = nil
        self.breadthFirstIndexer?.stop()
        self.breadthFirstIndexer = nil

        if let s3Lib = self.s3Lib {
            Task { try? await s3Lib.shutdown() }
        }

        if let monitor = networkMonitor {
            Task { await monitor.stopMonitoring() }
        }
    }

    // MARK: - Pure async business logic

    /// Resolves item metadata: checks MetadataStore cache first, then falls back to S3 HEAD.
    private func resolveItem(
        for identifier: NSFileProviderItemIdentifier,
        drive: DS3Drive,
        s3Lib: S3Lib,
        metadataStore: MetadataStore?
    ) async throws -> S3Item {
        let isFolder = identifier.rawValue.hasSuffix(String(DefaultSettings.S3.delimiter))

        // Try MetadataStore first
        if let cached = try? await metadataStore?.fetchItemMetadata(byKey: identifier.rawValue, driveId: drive.id),
           cached.etag != nil || cached.syncStatus == SyncStatus.error.rawValue || isFolder {
            self.logger.info("item(for:) cache hit for \(identifier.rawValue, privacy: .public) isFolder=\(isFolder)")
            return S3Item(
                identifier: identifier,
                drive: drive,
                objectMetadata: S3Item.Metadata(
                    etag: ETagUtils.normalize(cached.etag),
                    contentType: cached.contentType,
                    lastModified: cached.lastModified,
                    size: NSNumber(value: cached.size),
                    syncStatus: cached.syncStatus
                )
            )
        }

        // Folders are virtual S3 entries — avoid the S3 HEAD request which
        // can hang when the iOS networking grace period is exhausted, causing
        // Files to show folder items without icons while waiting for a response.
        if isFolder {
            self.logger.info("item(for:) folder shortcut for \(identifier.rawValue, privacy: .public)")
            return S3Item(
                identifier: identifier,
                drive: drive,
                objectMetadata: S3Item.Metadata(size: NSNumber(value: 0))
            )
        }

        self.logger.info("item(for:) S3 HEAD for \(identifier.rawValue, privacy: .public)")
        return try await s3Lib.remoteS3Item(for: identifier, drive: drive)
    }

    // MARK: - Protocol methods

    // Note: gets called when the extension wants to retrieve metadata for a specific item
    func item(
        for identifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        guard self.enabled else {
            completionHandler(nil, NSFileProviderError(.notAuthenticated) as NSError)
            return Progress()
        }

        guard let drive = self.drive, let s3Lib = self.s3Lib else {
            completionHandler(nil, NSFileProviderError(.cannotSynchronize) as NSError)
            return Progress()
        }

        self.logger.debug("item(for: \(identifier.rawValue, privacy: .public))")

        switch identifier {
        case .trashContainer:
            completionHandler(nil, NSFileProviderError(.noSuchItem))
            return Progress()
        case .rootContainer:
            let rootItem = S3Item(
                identifier: identifier,
                drive: drive,
                objectMetadata: S3Item.Metadata(size: NSNumber(value: 0))
            )
            completionHandler(rootItem, nil)
            return Progress()
        default:
            break
        }

        let metadataStore = self.metadataStore
        let boxedCb = UncheckedBox(value: completionHandler)
        Task {
            let completionHandler = boxedCb.value
            do {
                let item = try await self.resolveItem(
                    for: identifier, drive: drive, s3Lib: s3Lib, metadataStore: metadataStore
                )
                completionHandler(item, nil)
            } catch let s3Error as S3ErrorType {
                if identifier.rawValue.hasSuffix(String(DefaultSettings.S3.delimiter)) && s3Error.isNotFound {
                    let folderSyncStatus = try? await metadataStore?.fetchItemSyncStatus(byKey: identifier.rawValue, driveId: drive.id)
                    let folderItem = S3Item(
                        identifier: identifier,
                        drive: drive,
                        objectMetadata: S3Item.Metadata(size: NSNumber(value: 0), syncStatus: folderSyncStatus)
                    )
                    completionHandler(folderItem, nil)
                } else {
                    completionHandler(nil, s3Error.toFileProviderError())
                }
            } catch {
                completionHandler(nil, NSFileProviderError(.cannotSynchronize) as NSError)
            }
        }

        return Progress()
    }

    // NOTE: gets called when the extension wants to retrieve the contents of a specific item
    func fetchContents(
        for itemIdentifier: NSFileProviderItemIdentifier,
        version requestedVersion: NSFileProviderItemVersion?,
        request: NSFileProviderRequest,
        completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        guard
            self.enabled,
            let temporaryDirectory = self.temporaryDirectory
        else {
            completionHandler(nil, nil, NSFileProviderError(.notAuthenticated) as NSError)
            return Progress()
        }

        guard let drive = self.drive, let s3Lib = self.s3Lib, let nm = self.notificationManager else {
            completionHandler(nil, nil, NSFileProviderError(.cannotSynchronize) as NSError)
            return Progress()
        }

        // Folders have no downloadable content — materialise with an empty file.
        // Check BEFORE pause gate: folder materialization is local-only and triggers
        // BFS prioritization, allowing folder navigation even when paused.
        if itemIdentifier.rawValue.hasSuffix(String(DefaultSettings.S3.delimiter)) {
            return materializeFolderItem(itemIdentifier, drive: drive, temporaryDirectory: temporaryDirectory, completionHandler: completionHandler)
        }

        if isDrivePaused(drive.id, operation: "fetchContents") {
            completionHandler(nil, nil, NSFileProviderError(.serverUnreachable) as NSError)
            return Progress()
        }

        let progress = Progress(totalUnitCount: 100)
        let metadataStore = self.metadataStore
        let completed = OSAllocatedUnfairLock(initialState: false)
        let boxedCb = UncheckedBox(value: completionHandler)

        @Sendable func complete(_ url: URL?, _ item: NSFileProviderItem?, _ error: Error?) {
            let shouldCall = completed.withLock { flag -> Bool in
                guard !flag else { return false }
                flag = true
                return true
            }
            guard shouldCall else { return }
            boxedCb.value(url, item, error)
        }

        let fetchSemaphore = self.fetchSemaphore
        let task = Task {
            await fetchSemaphore.wait()
            defer { Task { await fetchSemaphore.signal() } }

            do {
                await nm.sendDriveChangedNotification(status: .sync)
                logMemoryUsage(label: "fetch-start:\(itemIdentifier.rawValue)", logger: self.logger)

                let (fileURL, s3Item) = try await self.withAPIKeyRecovery {
                    try await withExponentialBackoff(maxRetries: 3, baseDelay: 1.0) {
                        try await s3Lib.downloadS3Item(
                            identifier: itemIdentifier,
                            drive: drive,
                            temporaryFolder: temporaryDirectory,
                            progress: progress
                        )
                    }
                }

                logMemoryUsage(label: "fetch-complete:\(s3Item.filename)", logger: self.logger)
                self.logger.info("File \(s3Item.filename, privacy: .public) with size \(s3Item.documentSize ?? 0, privacy: .public) downloaded successfully")

                try? await metadataStore?.setMaterialized(s3Key: itemIdentifier.rawValue, driveId: drive.id, isMaterialized: true)
                try? await metadataStore?.setSyncStatus(s3Key: itemIdentifier.rawValue, driveId: drive.id, status: .synced)

                await nm.sendDriveChangedNotificationWithDebounce(status: .idle)
                complete(fileURL, s3Item, nil)
            } catch let s3Error as S3ErrorType {
                self.logger.error("Download failed for \(itemIdentifier.rawValue, privacy: .public) with S3 error \(s3Error.errorCode, privacy: .public)")
                await self.markItemAndParentAsError(itemKey: itemIdentifier.rawValue, driveId: drive.id, metadataStore: metadataStore)
                await nm.sendDriveChangedNotificationWithDebounce(status: .error)
                complete(nil, nil, s3Error.toFileProviderError())
            } catch is CancellationError {
                self.logger.debug("Download cancelled for \(itemIdentifier.rawValue, privacy: .public)")
                await nm.sendDriveChangedNotificationWithDebounce(status: .idle)
                complete(nil, nil, NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
            } catch {
                self.logger.error("Download failed for \(itemIdentifier.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
                await self.markItemAndParentAsError(itemKey: itemIdentifier.rawValue, driveId: drive.id, metadataStore: metadataStore)
                await nm.sendDriveChangedNotificationWithDebounce(status: .error)
                complete(nil, nil, NSFileProviderError(.cannotSynchronize) as NSError)
            }
        }

        progress.cancellationHandler = {
            task.cancel()
            complete(nil, nil, NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
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
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        guard self.enabled else {
            completionHandler(nil, [], false, NSFileProviderError(.notAuthenticated) as NSError)
            return Progress()
        }

        guard let drive = self.drive, let s3Lib = self.s3Lib, let nm = self.notificationManager else {
            completionHandler(nil, [], false, NSFileProviderError(.cannotSynchronize) as NSError)
            return Progress()
        }

        if isDrivePaused(drive.id, operation: "createItem") {
            completionHandler(nil, [], false, NSFileProviderError(.serverUnreachable) as NSError)
            return Progress()
        }

        self.logger.debug("Starting upload for item \(itemTemplate.itemIdentifier.rawValue, privacy: .public)")

        guard itemTemplate.contentType != .symbolicLink else {
            self.logger.warning("Skipping symbolic link \(itemTemplate.itemIdentifier.rawValue, privacy: .public) upload. Feature not supported")
            completionHandler(itemTemplate, NSFileProviderItemFields(), false, NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError, userInfo: [:]))
            return Progress()
        }

        let parentKey: String? = itemTemplate.parentItemIdentifier == .rootContainer ? nil : itemTemplate.parentItemIdentifier.rawValue

        var key = (parentKey ?? "") + itemTemplate.filename

        if let prefix = drive.syncAnchor.prefix, !key.starts(with: prefix) {
            key = prefix + key
        }

        // documentSize is NSNumber?? (double optional from Obj-C protocol property)
        var itemSize = (itemTemplate.documentSize ?? nil)?.intValue ?? 0

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

        // Item may already exist on the server (e.g., after domain reimport). Check via HEAD first.
        if options.contains(.mayAlreadyExist) {
            self.logger.debug("createItem with .mayAlreadyExist for key \(key, privacy: .public)")

            let boxedCb = UncheckedBox(value: completionHandler)
            Task {
                let completionHandler = boxedCb.value
                do {
                    let existingItem = try await s3Lib.remoteS3Item(
                        for: s3Item.itemIdentifier, drive: drive
                    )

                    try? await self.metadataStore?.upsertItem(
                        s3Key: key,
                        driveId: drive.id,
                        etag: existingItem.metadata.etag,
                        lastModified: existingItem.metadata.lastModified,
                        syncStatus: .synced,
                        parentKey: parentKey,
                        contentType: existingItem.isFolder ? "folder" : nil,
                        size: Int64(truncating: existingItem.metadata.size)
                    )

                    progress.completedUnitCount = numParts
                    completionHandler(existingItem, NSFileProviderItemFields(), false, nil)
                } catch let s3Error as S3ErrorType where s3Error.errorCode == "NotFound" || s3Error.errorCode == "NoSuchKey" {
                    // Item doesn't exist remotely — proceed with normal upload
                    self.logger.debug("Item not found remotely (.mayAlreadyExist), proceeding with upload")
                    do {
                        await nm.sendDriveChangedNotification(status: .sync)
                        let createETag = try await self.withAPIKeyRecovery {
                            try await s3Lib.putS3Item(s3Item, fileURL: url, withProgress: progress)
                        }

                        try? await self.metadataStore?.upsertItem(
                            s3Key: key,
                            driveId: drive.id,
                            etag: ETagUtils.normalize(createETag),
                            lastModified: Date(),
                            syncStatus: .synced,
                            parentKey: parentKey,
                            contentType: s3Item.isFolder ? "folder" : nil,
                            size: Int64(itemSize)
                        )

                        progress.completedUnitCount = numParts
                        await nm.sendDriveChangedNotificationWithDebounce(status: .idle)
                        self.signalChanges()
                        completionHandler(s3Item, NSFileProviderItemFields(), false, nil)
                    } catch let s3Error as S3ErrorType {
                        await nm.sendDriveChangedNotificationWithDebounce(status: .error)
                        completionHandler(nil, NSFileProviderItemFields(), false, s3Error.toFileProviderError())
                    } catch {
                        await nm.sendDriveChangedNotificationWithDebounce(status: .error)
                        completionHandler(nil, NSFileProviderItemFields(), false, NSFileProviderError(.cannotSynchronize) as NSError)
                    }
                } catch let s3Error as S3ErrorType {
                    self.logger.error("HEAD failed for .mayAlreadyExist check: \(s3Error.errorCode, privacy: .public)")
                    await nm.sendDriveChangedNotificationWithDebounce(status: .error)
                    completionHandler(nil, NSFileProviderItemFields(), false, s3Error.toFileProviderError())
                } catch {
                    // Network/unknown error — return transient error for retry
                    self.logger.error("HEAD failed for .mayAlreadyExist check: \(error)")
                    await nm.sendDriveChangedNotificationWithDebounce(status: .error)
                    completionHandler(nil, NSFileProviderItemFields(), false, NSFileProviderError(.serverUnreachable) as NSError)
                }
            }

            return progress
        }

        let boxedCb = UncheckedBox(value: completionHandler)
        Task {
            let completionHandler = boxedCb.value
            do {
                await nm.sendDriveChangedNotification(status: .sync)
                logMemoryUsage(label: "upload-start:\(key)", logger: self.logger)

                // --- Conflict detection ---
                if !s3Item.isFolder {
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
                            parentKey: parentKey,
                            size: Int64(itemSize),
                            progress: uploadProgress
                        )

                        uploadProgress.completedUnitCount = numParts
                        await nm.sendDriveChangedNotificationWithDebounce(status: .idle)
                        self.signalChanges()
                        completionHandler(conflictS3Item, NSFileProviderItemFields(), false, nil)
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
                    parentKey: parentKey,
                    contentType: s3Item.isFolder ? "folder" : nil,
                    size: Int64(itemSize)
                )

                logMemoryUsage(label: "upload-complete:\(key)", logger: self.logger)
                uploadProgress.completedUnitCount = numParts
                await nm.sendDriveChangedNotificationWithDebounce(status: .idle)
                self.signalChanges()
                completionHandler(s3Item, NSFileProviderItemFields(), false, nil)
            } catch let s3Error as S3ErrorType {
                self.logger.error("Upload failed with S3 error \(s3Error.errorCode, privacy: .public)")
                await nm.sendDriveChangedNotificationWithDebounce(status: .error)
                completionHandler(nil, NSFileProviderItemFields(), false, s3Error.toFileProviderError())
            } catch is CancellationError {
                self.logger.debug("Upload cancelled for \(key, privacy: .public)")
                await nm.sendDriveChangedNotificationWithDebounce(status: .idle)
                completionHandler(nil, NSFileProviderItemFields(), false, NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
            } catch {
                self.logger.error("Upload failed for \(key, privacy: .public): \(error.localizedDescription, privacy: .public)")
                await nm.sendDriveChangedNotificationWithDebounce(status: .error)
                completionHandler(nil, NSFileProviderItemFields(), false, NSFileProviderError(.cannotSynchronize) as NSError)
            }
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
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        guard self.enabled else {
            completionHandler(nil, [], false, NSFileProviderError(.notAuthenticated) as NSError)
            return Progress()
        }

        guard let drive = self.drive, let s3Lib = self.s3Lib, let nm = self.notificationManager else {
            completionHandler(nil, [], false, NSFileProviderError(.cannotSynchronize) as NSError)
            return Progress()
        }

        if isDrivePaused(drive.id, operation: "modifyItem") {
            completionHandler(nil, [], false, NSFileProviderError(.serverUnreachable) as NSError)
            return Progress()
        }

        let progress = Progress()
        let boxedCb = UncheckedBox(value: completionHandler)

        let s3Item = S3Item(
            from: item,
            drive: drive
        )

        // TODO: Handle versioning

        // When multiple fields change at once (e.g., content + rename), handle
        // content first and return remaining fields as still-pending.
        var remainingFields = NSFileProviderItemFields()
        if changedFields.contains(.contents) {
            if changedFields.contains(.filename) { remainingFields.insert(.filename) }
            if changedFields.contains(.parentItemIdentifier) { remainingFields.insert(.parentItemIdentifier) }
        }

        if changedFields.contains(.contents) {
            // Modified
            switch s3Item.contentType {
            case .symbolicLink:
                self.logger.warning("Skipping symbolic link modify for \(s3Item.itemIdentifier.rawValue, privacy: .public)")
                completionHandler(nil, [], false, NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError, userInfo: [:]))
                return Progress()
            case .folder:
                self.logger.error("Modify with contents requested for folder \(s3Item.itemIdentifier.rawValue, privacy: .public)")
                completionHandler(nil, [], false, NSFileProviderError(.cannotSynchronize) as NSError)
                return progress
            default:
                guard let contents = newContents else {
                    completionHandler(nil, [], false, NSFileProviderError(.cannotSynchronize) as NSError)
                    return progress
                }

                let documentSize = s3Item.documentSize?.intValue ?? 0
                let numParts = max(Int64((documentSize + DefaultSettings.S3.multipartUploadPartSize - 1) / DefaultSettings.S3.multipartUploadPartSize), 1)

                let putProgress = Progress(totalUnitCount: numParts)
                progress.addChild(putProgress, withPendingUnitCount: numParts)

                Task {
                    let completionHandler = boxedCb.value
                    do {
                        await nm.sendDriveChangedNotification(status: .sync)

                        // --- Conflict detection ---
                        if !s3Item.isFolder {
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
                                    await nm.sendDriveChangedNotificationWithDebounce(status: .idle)
                                    self.signalChanges()
                                    // Return empty remaining fields: the conflict copy already has the correct name/location
                                    completionHandler(conflictS3Item, NSFileProviderItemFields(), false, nil)
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
                            try await s3Lib.putS3Item(s3Item, fileURL: contents, withProgress: putProgress)
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
                        await nm.sendDriveChangedNotificationWithDebounce(status: .idle)
                        self.signalChanges()
                        completionHandler(s3Item, remainingFields, false, nil)
                    } catch let s3Error as S3ErrorType {
                        self.logger.error("Upload failed with S3 error \(s3Error.errorCode, privacy: .public)")
                        await nm.sendDriveChangedNotificationWithDebounce(status: .error)
                        completionHandler(nil, NSFileProviderItemFields(), false, s3Error.toFileProviderError())
                    } catch is CancellationError {
                        self.logger.debug("Modify upload cancelled for \(s3Item.itemIdentifier.rawValue, privacy: .public)")
                        await nm.sendDriveChangedNotificationWithDebounce(status: .idle)
                        completionHandler(nil, NSFileProviderItemFields(), false, NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
                    } catch {
                        self.logger.error("Modify upload failed for \(s3Item.itemIdentifier.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
                        await nm.sendDriveChangedNotificationWithDebounce(status: .error)
                        completionHandler(nil, NSFileProviderItemFields(), false, NSFileProviderError(.cannotSynchronize) as NSError)
                    }
                }
            }
        } else if changedFields.contains(.filename) && changedFields.contains(.parentItemIdentifier) {
            // Renamed + moved
            let newName = item.filename
            let destinationParent = item.parentItemIdentifier == .rootContainer ? "" : item.parentItemIdentifier.rawValue
            self.logger.debug("Rename+move detected for \(s3Item.itemIdentifier.rawValue, privacy: .public) to \(destinationParent, privacy: .public)\(newName, privacy: .public)")

            let oldKey = s3Item.itemIdentifier.rawValue
            Task {
                let completionHandler = boxedCb.value
                do {
                    await nm.sendDriveChangedNotification(status: .sync)

                    let delimiter = String(DefaultSettings.S3.delimiter)
                    var newKey = destinationParent + newName
                    if s3Item.isFolder && !newKey.hasSuffix(delimiter) {
                        newKey += delimiter
                    }

                    // Apply drive prefix if needed
                    if let prefix = drive.syncAnchor.prefix, !newKey.starts(with: prefix) {
                        newKey = prefix + newKey
                    }

                    let movedS3Item = try await s3Lib.moveS3Item(s3Item, toKey: newKey, withProgress: progress)

                    try? await self.metadataStore?.deleteItem(byKey: oldKey, driveId: drive.id)
                    try? await self.metadataStore?.upsertItem(
                        s3Key: movedS3Item.itemIdentifier.rawValue,
                        driveId: drive.id,
                        syncStatus: .synced
                    )

                    await nm.sendDriveChangedNotificationWithDebounce(status: .idle)
                    self.signalChanges()
                    completionHandler(movedS3Item, NSFileProviderItemFields(), false, nil)
                } catch let s3Error as S3ErrorType {
                    self.logger.error("Rename+move failed with S3 error \(s3Error.errorCode, privacy: .public)")
                    await nm.sendDriveChangedNotificationWithDebounce(status: .error)
                    completionHandler(nil, NSFileProviderItemFields(), false, s3Error.toFileProviderError())
                } catch {
                    self.logger.error("Rename+move failed with error \(error)")
                    await nm.sendDriveChangedNotificationWithDebounce(status: .error)
                    completionHandler(nil, NSFileProviderItemFields(), false, NSFileProviderError(.cannotSynchronize) as NSError)
                }
            }
        } else if changedFields.contains(.filename) {
            // Renamed
            switch s3Item.contentType {
            case .symbolicLink:
                self.logger.warning("Skipping symbolic link rename for \(s3Item.itemIdentifier.rawValue, privacy: .public)")
                completionHandler(nil, [], false, NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError, userInfo: [:]))
                return progress
            default:
                // File/Folder rename
                let newName = item.filename
                self.logger.info("Rename detected for \(s3Item.itemIdentifier.rawValue, privacy: .public) with name \(newName, privacy: .public)")

                let oldKey = s3Item.itemIdentifier.rawValue
                Task {
                    let completionHandler = boxedCb.value
                    do {
                        await nm.sendDriveChangedNotification(status: .sync)
                        let newS3Item = try await s3Lib.renameS3Item(s3Item, newName: newName, withProgress: progress)

                        // Delete old key and upsert new key in MetadataStore
                        try? await self.metadataStore?.deleteItem(byKey: oldKey, driveId: drive.id)
                        try? await self.metadataStore?.upsertItem(
                            s3Key: newS3Item.itemIdentifier.rawValue,
                            driveId: drive.id,
                            syncStatus: .synced
                        )

                        await nm.sendDriveChangedNotificationWithDebounce(status: .idle)
                        self.signalChanges()
                        completionHandler(newS3Item, NSFileProviderItemFields(), false, nil)
                    } catch let s3Error as S3ErrorType {
                        self.logger.error("Rename failed with S3 error \(s3Error.errorCode, privacy: .public)")
                        await nm.sendDriveChangedNotificationWithDebounce(status: .error)
                        completionHandler(nil, NSFileProviderItemFields(), false, s3Error.toFileProviderError())
                    } catch is CancellationError {
                        self.logger.debug("Rename cancelled for \(s3Item.itemIdentifier.rawValue, privacy: .public)")
                        await nm.sendDriveChangedNotificationWithDebounce(status: .idle)
                        completionHandler(nil, NSFileProviderItemFields(), false, NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
                    } catch {
                        self.logger.error("Rename failed for \(oldKey, privacy: .public): \(error.localizedDescription, privacy: .public)")
                        await nm.sendDriveChangedNotificationWithDebounce(status: .error)
                        completionHandler(nil, NSFileProviderItemFields(), false, NSFileProviderError(.cannotSynchronize) as NSError)
                    }
                }
            }
        } else if changedFields.contains(.parentItemIdentifier) {
            // Move file/folder
            let destinationParent = item.parentItemIdentifier == .rootContainer ? "" : item.parentItemIdentifier.rawValue
            self.logger.info("Move detected for key \(s3Item.itemIdentifier.rawValue, privacy: .public) from \(s3Item.parentItemIdentifier.rawValue, privacy: .public) to \(destinationParent, privacy: .public)")

            let moveOldKey = s3Item.itemIdentifier.rawValue
            Task {
                let completionHandler = boxedCb.value
                do {
                    await nm.sendDriveChangedNotification(status: .sync)

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

                    await nm.sendDriveChangedNotificationWithDebounce(status: .idle)
                    self.signalChanges()
                    completionHandler(movedS3Item, NSFileProviderItemFields(), false, nil)
                } catch let s3Error as S3ErrorType {
                    self.logger.error("Move failed with S3 error code \(s3Error.errorCode, privacy: .public)")
                    await nm.sendDriveChangedNotificationWithDebounce(status: .error)
                    completionHandler(nil, NSFileProviderItemFields(), false, s3Error.toFileProviderError())
                } catch is CancellationError {
                    self.logger.debug("Move cancelled for \(s3Item.itemIdentifier.rawValue, privacy: .public)")
                    await nm.sendDriveChangedNotificationWithDebounce(status: .idle)
                    completionHandler(nil, NSFileProviderItemFields(), false, NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
                } catch {
                    self.logger.error("Move failed for \(moveOldKey, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    await nm.sendDriveChangedNotificationWithDebounce(status: .error)
                    completionHandler(nil, NSFileProviderItemFields(), false, NSFileProviderError(.cannotSynchronize) as NSError)
                }
            }
        } else {
            // Metadata changed
            self.logger.debug("Metadata change detected for \(s3Item.filename, privacy: .public). Skipping...")
            completionHandler(s3Item, NSFileProviderItemFields(), false, nil)
            return progress
        }

        return progress
    }

    // NOTE: gets called when the extension wants to delete an item
    // swiftlint:disable:next function_body_length
    func deleteItem(
        identifier: NSFileProviderItemIdentifier,
        baseVersion version: NSFileProviderItemVersion,
        options: NSFileProviderDeleteItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        guard self.enabled else {
            completionHandler(NSFileProviderError(.notAuthenticated) as NSError)
            return Progress()
        }

        guard let drive = self.drive, let s3Lib = self.s3Lib, let nm = self.notificationManager else {
            completionHandler(NSFileProviderError(.cannotSynchronize) as NSError)
            return Progress()
        }

        if isDrivePaused(drive.id, operation: "deleteItem") {
            completionHandler(NSFileProviderError(.serverUnreachable) as NSError)
            return Progress()
        }

        switch identifier {
        case .trashContainer, .rootContainer:
            self.logger.debug("Skipping deletion of container \(identifier.rawValue, privacy: .public)")
            completionHandler(nil)
            return Progress()
        default:
            break
        }

        // TODO: Handle versioning

        let progress = Progress(totalUnitCount: 1)

        let boxedCb = UncheckedBox(value: completionHandler)
        Task {
            let completionHandler = boxedCb.value
            do {
                let s3Item = S3Item(
                    identifier: identifier,
                    drive: drive,
                    objectMetadata: S3Item.Metadata(size: NSNumber(value: 0))
                )

                if !s3Item.isFolder {
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
                            await nm.sendDriveChangedNotificationWithDebounce(status: .idle)
                            self.signalChanges()
                            completionHandler(NSFileProviderError(.cannotSynchronize) as NSError)
                            return
                        }
                    } catch let s3Error as S3ErrorType where s3Error.errorCode == "NoSuchKey" || s3Error.errorCode == "NotFound" {
                        // Both sides deleted -- treat as success
                        self.logger.debug("File already deleted remotely: \(identifier.rawValue, privacy: .public)")
                        try? await self.metadataStore?.deleteItem(byKey: identifier.rawValue, driveId: drive.id)
                        progress.completedUnitCount = 1
                        await nm.sendDriveChangedNotificationWithDebounce(status: .idle)
                        self.signalChanges()
                        completionHandler(nil)
                        return
                    } catch {
                        // HEAD failed (network) -- return transient error for retry
                        self.logger.error("Delete conflict check HEAD failed for \(identifier.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
                        await nm.sendDriveChangedNotificationWithDebounce(status: .error)
                        completionHandler(NSFileProviderError(.serverUnreachable) as NSError)
                        return
                    }
                    // --- End conflict detection ---
                }

                await nm.sendDriveChangedNotification(status: .sync)
                try await self.withAPIKeyRecovery {
                    try await s3Lib.deleteS3Item(s3Item, withProgress: progress)
                }
                self.logger.info("S3Item with identifier \(identifier.rawValue, privacy: .public) deleted successfully")

                // Remove from MetadataStore
                try? await self.metadataStore?.deleteItem(byKey: identifier.rawValue, driveId: drive.id)

                progress.completedUnitCount = 1
                await nm.sendDriveChangedNotificationWithDebounce(status: .idle)
                self.signalChanges()
                completionHandler(nil)
            } catch let s3Error as S3ErrorType where s3Error.errorCode == "NoSuchKey" || s3Error.errorCode == "NotFound" {
                // Both sides deleted during the race -- treat as success
                self.logger.debug("File deleted remotely during our delete: \(identifier.rawValue, privacy: .public)")
                try? await self.metadataStore?.deleteItem(byKey: identifier.rawValue, driveId: drive.id)
                progress.completedUnitCount = 1
                await nm.sendDriveChangedNotificationWithDebounce(status: .idle)
                self.signalChanges()
                completionHandler(nil)
            } catch let s3Error as S3ErrorType {
                self.logger.error("An error occurred while deleting file \(identifier.rawValue, privacy: .public): \(s3Error.errorCode, privacy: .public)")
                await nm.sendDriveChangedNotificationWithDebounce(status: .error)
                completionHandler(s3Error.toFileProviderError())
            } catch is CancellationError {
                self.logger.debug("Delete cancelled for \(identifier.rawValue, privacy: .public)")
                await nm.sendDriveChangedNotificationWithDebounce(status: .idle)
                completionHandler(NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
            } catch {
                self.logger.error("An error occurred while deleting file \(identifier.rawValue, privacy: .public): \(error, privacy: .public)")
                await nm.sendDriveChangedNotificationWithDebounce(status: .error)
                completionHandler(NSFileProviderError(.cannotSynchronize) as NSError)
            }
        }

        return progress
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
            hostname: self.systemService.deviceName,
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

        await nm.sendConflictNotification(filename: s3Item.filename, conflictKey: conflictKey)

        return conflictS3Item
    }

    /// Marks a failed item and its parent folder with error status in MetadataStore,
    /// then signals the system to re-enumerate so error decorations show in Finder.
    private func markItemAndParentAsError(itemKey: String, driveId: UUID, metadataStore: MetadataStore?) async {
        guard let metadataStore else { return }

        // Mark the item itself as error
        try? await metadataStore.setSyncStatus(s3Key: itemKey, driveId: driveId, status: .error)

        // Derive the parent folder key and mark it as error too,
        // so the parent folder shows an error icon instead of staying stuck in progress.
        let delimiter = String(DefaultSettings.S3.delimiter)
        let trimmed = itemKey.hasSuffix(delimiter) ? String(itemKey.dropLast()) : itemKey
        if let lastSlash = trimmed.lastIndex(of: Character(delimiter)) {
            let parentKey = String(trimmed[...lastSlash])
            try? await metadataStore.setSyncStatus(s3Key: parentKey, driveId: driveId, status: .error)
        }

        self.signalChanges()
    }

    /// Materialises a folder item by providing an empty temp file and marking it in MetadataStore.
    /// Bumps the folder to the front of the BFS indexer queue so its children are discovered quickly.
    private func materializeFolderItem(
        _ itemIdentifier: NSFileProviderItemIdentifier,
        drive: DS3Drive,
        temporaryDirectory: URL,
        completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        logger.debug("Materializing folder item: \(itemIdentifier.rawValue, privacy: .public)")

        // Notify the tray immediately so the user sees feedback
        if let nm = self.notificationManager {
            Task { await nm.sendDriveChangedNotification(status: .indexing) }
        }

        let progress = Progress(totalUnitCount: 1)
        let folderItem = S3Item(
            identifier: itemIdentifier,
            drive: drive,
            objectMetadata: S3Item.Metadata(size: NSNumber(value: 0))
        )
        do {
            let emptyFileURL = temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try Data().write(to: emptyFileURL)
            completionHandler(emptyFileURL, folderItem, nil)
            let store = self.metadataStore
            Task { try? await store?.setMaterialized(s3Key: itemIdentifier.rawValue, driveId: drive.id, isMaterialized: true) }
        } catch {
            completionHandler(nil, nil, NSFileProviderError(.cannotSynchronize) as NSError)
        }
        progress.completedUnitCount = 1
        breadthFirstIndexer?.prioritize(prefix: itemIdentifier.rawValue)

        return progress
    }

    /// Returns true when the drive is paused, logging the deferred operation name.
    private func isDrivePaused(_ driveId: UUID, operation: String) -> Bool {
        guard (try? SharedData.default().isDrivePaused(driveId)) == true else { return false }
        logger.info("Drive paused, deferring \(operation, privacy: .public) operation")
        return true
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

    // MARK: - Cache Warm-up

    /// Performs a single recursive S3 listing on startup to populate MetadataStore
    /// before BFS starts. This turns all subsequent enumerateItems calls into
    /// instant cache hits, avoiding the enumeration waterfall when the user
    /// downloads a large folder tree.
    private func warmCacheThenStartBFS() {
        #if os(iOS)
        // On iOS, skip warm-up — recursive listings spike memory and burn
        // the networking grace period. Per-folder enumeration handles discovery.
        return
        #else
        guard self.enabled,
              let drive = self.drive,
              let s3Lib = self.s3Lib,
              let metadataStore = self.metadataStore else {
            self.startBFSIndexer()
            return
        }

        // Skip warm-up when drive is paused
        if (try? SharedData.default().isDrivePaused(drive.id)) == true {
            self.startBFSIndexer()
            return
        }

        Task.detached(priority: .utility) { [weak self] in
            let prefix = drive.syncAnchor.prefix
            self?.logger.info("Cache warm-up: starting recursive listing for prefix \(prefix ?? "<root>", privacy: .public)")

            do {
                var continuationToken: String?
                var allItems: [S3Item] = []

                repeat {
                    let (items, nextToken) = try await s3Lib.listS3Items(
                        forDrive: drive,
                        withPrefix: prefix,
                        recursively: true,
                        withContinuationToken: continuationToken
                    )
                    continuationToken = nextToken
                    allItems.append(contentsOf: items)

                    // Upsert each page incrementally so enumerateItems can
                    // start serving partial results while we're still listing.
                    let upsertData = items.map { MetadataStore.ItemUpsertData(from: $0) }
                    try await metadataStore.batchUpsertItems(upsertData)
                } while continuationToken != nil

                // Synthesize virtual folders (recursive listing omits directory-only prefixes)
                let virtualFolders = S3Enumerator.synthesizeVirtualFolders(
                    from: allItems, drive: drive, prefix: prefix
                )
                if !virtualFolders.isEmpty {
                    let folderData = virtualFolders.map { MetadataStore.ItemUpsertData(from: $0) }
                    try await metadataStore.batchUpsertItems(folderData)
                }

                self?.logger.info("Cache warm-up complete: \(allItems.count) items + \(virtualFolders.count) virtual folders")

                // Signal working set so fileproviderd picks up the warm cache
                self?.signalChanges()
            } catch {
                self?.logger.error("Cache warm-up failed: \(error.localizedDescription, privacy: .public). Falling back to BFS.")
            }

            // Start BFS for ongoing cache maintenance after warm-up completes (or fails)
            self?.startBFSIndexer()
        }
        #endif
    }

    // MARK: - BFS Indexer

    private func startBFSIndexer() {
        #if os(iOS)
        // BFS disabled on iOS. iOS kills the extension every few seconds,
        // so BFS never completes a pass and each restart burns the limited
        // networking grace period. Per-folder enumeration (cache-first with
        // background S3 refresh) handles content discovery as the user navigates.
        return
        #else
        guard self.enabled,
              let drive = self.drive,
              let s3Lib = self.s3Lib else { return }

        let indexer = BreadthFirstIndexer(
            s3Lib: s3Lib,
            drive: drive,
            metadataStore: self.metadataStore,
            manager: NSFileProviderManager(for: self.domain)
        )
        indexer.start()
        self.breadthFirstIndexer = indexer
        #endif
    }

    // MARK: - Periodic Polling

    /// Starts a background task that periodically signals the system to re-enumerate
    /// changes from the remote, ensuring local state stays up to date even when no
    /// local modifications trigger a sync.
    private func startPolling() {
        guard self.enabled else { return }

        #if os(iOS)
        // Polling disabled on iOS. enumerateChanges is skipped entirely on iOS
        // (SyncEngine.reconcile does full recursive S3 listings that spike memory
        // and burn the networking grace period), so signaling does nothing useful.
        // Changes are discovered via per-folder enumerateItems when the user navigates.
        return
        #endif

        let pollingInterval = DefaultSettings.Extension.pollingIntervalSeconds

        // Signal immediately on startup so enumerateChanges/reconciliation
        // runs right away — don't wait for the first polling interval.
        self.signalChanges()

        self.pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(pollingInterval))
                guard !Task.isCancelled, let self else { break }

                // Skip polling when drive is paused
                if let driveId = self.drive?.id,
                   (try? SharedData.default().isDrivePaused(driveId)) == true {
                    continue
                }

                self.signalChanges()
            }
        }

        self.logger.debug("Periodic polling started with interval \(pollingInterval)s")
    }

    // MARK: - Materialized Items Tracking

    func materializedItemsDidChange(completionHandler: @escaping () -> Void) {
        guard let manager = NSFileProviderManager(for: self.domain),
              let drive = self.drive,
              let metadataStore = self.metadataStore else {
            completionHandler()
            return
        }

        let driveId = drive.id

        let boxedCb = UncheckedBox(value: completionHandler)
        Task {
            let completionHandler = boxedCb.value
            defer { completionHandler() }

            do {
                let enumerator = manager.enumeratorForMaterializedItems()
                let materializedKeys = try await self.collectMaterializedKeys(from: enumerator)

                try await metadataStore.updateMaterializedState(
                    driveId: driveId,
                    materializedKeys: materializedKeys
                )

                self.logger.debug("Updated materialized state for \(materializedKeys.count) items")
            } catch {
                self.logger.error("Failed to update materialized items: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Collects all item identifiers from the materialized items enumerator, following pagination.
    private func collectMaterializedKeys(from enumerator: NSFileProviderEnumerator) async throws -> Set<String> {
        var allKeys = Set<String>()
        var currentPage = NSFileProviderPage.initialPageSortedByName as NSFileProviderPage

        while true {
            let (keys, nextPage): (Set<String>, NSFileProviderPage?) = try await withCheckedThrowingContinuation { continuation in
                let observer = MaterializedItemObserver()
                observer.onFinish = { keys, next in
                    continuation.resume(returning: (keys, next))
                }
                observer.onError = { error in
                    continuation.resume(throwing: error)
                }
                enumerator.enumerateItems(for: observer, startingAt: currentPage)
            }

            allKeys.formUnion(keys)

            guard let nextPage else { break }
            currentPage = nextPage
        }

        return allKeys
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

        if let s3Lib = self.s3Lib {
            Task { try? await s3Lib.shutdown() }
        }

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
            if let nm = self.notificationManager {
                await nm.sendAuthFailureNotification(
                    domainId: self.domain.identifier.rawValue,
                    reason: "s3AuthError"
                )
            }
            throw NSFileProviderError(.notAuthenticated) as NSError
        }
    }

    // NOTE: gets called when the extension wants to get an enumerator for a folder
    func enumerator(
        for containerItemIdentifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest
    ) throws -> NSFileProviderEnumerator {
        guard self.enabled else {
            throw NSFileProviderError(.notAuthenticated)
        }

        self.logger.debug("enumerator(for: \(containerItemIdentifier.rawValue, privacy: .public))")

        guard let drive = self.drive, let s3Lib = self.s3Lib, let nm = self.notificationManager else {
            throw NSFileProviderError(.cannotSynchronize)
        }

        logMemoryUsage(label: "enumerate:\(containerItemIdentifier.rawValue)", logger: self.logger)

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

// MARK: - Thumbnails

extension FileProviderExtension {
    func fetchThumbnails(
        for itemIdentifiers: [NSFileProviderItemIdentifier],
        requestedSize size: CGSize,
        perThumbnailCompletionHandler: @escaping (NSFileProviderItemIdentifier, Data?, Error?) -> Void,
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: Int64(itemIdentifiers.count))
        let completed = OSAllocatedUnfairLock(initialState: false)
        let boxedFinalCb = UncheckedBox(value: completionHandler)

        @Sendable func completeFinal(_ error: Error?) {
            let shouldCall = completed.withLock { flag -> Bool in
                guard !flag else { return false }
                flag = true
                return true
            }
            guard shouldCall else { return }
            boxedFinalCb.value(error)
        }

        guard self.enabled else {
            completeFinal(NSFileProviderError(.notAuthenticated) as NSError)
            return progress
        }

        guard let drive = self.drive,
              let s3Lib = self.s3Lib,
              let temporaryDirectory = self.temporaryDirectory
        else {
            completeFinal(NSFileProviderError(.cannotSynchronize) as NSError)
            return progress
        }

        self.logger.info("fetchThumbnails: starting for \(itemIdentifiers.count) items")

        // When paused, skip all thumbnail downloads — they require S3 network access.
        if isDrivePaused(drive.id, operation: "fetchThumbnails") {
            for identifier in itemIdentifiers {
                perThumbnailCompletionHandler(identifier, nil, nil)
            }
            completeFinal(nil)
            return progress
        }

        let boxedPerItemCb = UncheckedBox(value: perThumbnailCompletionHandler)
        let task = Task {
            let perThumbnailCompletionHandler = boxedPerItemCb.value
            var downloadedFiles: [URL] = []
            defer {
                for file in downloadedFiles {
                    try? FileManager.default.removeItem(at: file)
                }
            }

            for identifier in itemIdentifiers {
                guard !Task.isCancelled, !progress.isCancelled else { break }

                if let fileURL = try await self.downloadThumbnailImage(
                    for: identifier, drive: drive, s3Lib: s3Lib,
                    temporaryDirectory: temporaryDirectory, size: size,
                    perItemHandler: perThumbnailCompletionHandler
                ) {
                    downloadedFiles.append(fileURL)
                }
                progress.completedUnitCount += 1
            }

            completeFinal(nil)
        }

        progress.cancellationHandler = {
            task.cancel()
            completeFinal(NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
        }

        return progress
    }

    /// Downloads and generates a thumbnail for a single item. Returns the temporary file URL if downloaded, nil if skipped.
    private func downloadThumbnailImage(
        for identifier: NSFileProviderItemIdentifier,
        drive: DS3Drive,
        s3Lib: S3Lib,
        temporaryDirectory: URL,
        size: CGSize,
        perItemHandler: @escaping (NSFileProviderItemIdentifier, Data?, Error?) -> Void
    ) async throws -> URL? {
        // Skip folders
        if identifier.rawValue.last == "/" || identifier == .rootContainer {
            perItemHandler(identifier, nil, nil)
            return nil
        }

        do {
            let s3Item = try await self.withAPIKeyRecovery {
                try await s3Lib.remoteS3Item(for: identifier, drive: drive)
            }

            let fileExtension = (s3Item.filename as NSString).pathExtension
            guard let utType = UTType(filenameExtension: fileExtension),
                  utType.conforms(to: .image) else {
                perItemHandler(identifier, nil, nil)
                return nil
            }

            let fileURL = try await self.withAPIKeyRecovery {
                try await s3Lib.getS3Item(s3Item, withTemporaryFolder: temporaryDirectory, withProgress: nil)
            }

            let thumbnailData = Self.generateThumbnail(from: fileURL, fitting: size)
            perItemHandler(identifier, thumbnailData, nil)
            self.logger.debug("fetchThumbnails: generated thumbnail for \(identifier.rawValue, privacy: .public)")
            return fileURL
        } catch let s3Error as S3ErrorType {
            self.logger.error("fetchThumbnails: S3 error for \(identifier.rawValue, privacy: .public): \(s3Error.description, privacy: .public)")
            perItemHandler(identifier, nil, s3Error.toFileProviderError())
            return nil
        } catch {
            self.logger.error("fetchThumbnails: error for \(identifier.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
            perItemHandler(identifier, nil, NSFileProviderError(.cannotSynchronize) as NSError)
            return nil
        }
    }

    /// Thread-safe thumbnail generation using ImageIO.
    private static func generateThumbnail(from fileURL: URL, fitting maxSize: CGSize) -> Data? {
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else { return nil }

        let maxDimension = max(maxSize.width, maxSize.height)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }

        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cgImage, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}

// MARK: - Materialized Item Observer

/// Collects item identifiers from the materialized items enumerator.
private class MaterializedItemObserver: NSObject, NSFileProviderEnumerationObserver, @unchecked Sendable {
    private var keys = Set<String>()
    var onFinish: ((Set<String>, NSFileProviderPage?) -> Void)?
    var onError: ((Error) -> Void)?

    func didEnumerate(_ updatedItems: [NSFileProviderItemProtocol]) {
        keys.formUnion(updatedItems.map(\.itemIdentifier.rawValue))
    }

    func finishEnumerating(upTo nextPage: NSFileProviderPage?) {
        onFinish?(keys, nextPage)
    }

    func finishEnumeratingWithError(_ error: Error) {
        onError?(error)
    }
}

// MARK: - Partial Content Fetching

#if os(macOS)
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
        guard
            self.enabled,
            let temporaryDirectory = self.temporaryDirectory
        else {
            completionHandler(nil, nil, NSRange(location: 0, length: 0), [], NSFileProviderError(.notAuthenticated) as NSError)
            return Progress()
        }

        guard let drive = self.drive, let s3Lib = self.s3Lib, let nm = self.notificationManager else {
            completionHandler(nil, nil, NSRange(location: 0, length: 0), [], NSFileProviderError(.cannotSynchronize) as NSError)
            return Progress()
        }

        let progress = Progress(totalUnitCount: 1)
        let completed = OSAllocatedUnfairLock(initialState: false)
        let boxedCb = UncheckedBox(value: completionHandler)

        @Sendable func complete(_ url: URL?, _ item: NSFileProviderItem?, _ range: NSRange, _ flags: NSFileProviderMaterializationFlags, _ error: Error?) {
            let shouldCall = completed.withLock { flag -> Bool in
                guard !flag else { return false }
                flag = true
                return true
            }
            guard shouldCall else { return }
            boxedCb.value(url, item, range, flags, error)
        }

        let fetchSemaphore = self.fetchSemaphore
        let task = Task {
            await fetchSemaphore.wait()
            defer { Task { await fetchSemaphore.signal() } }

            do {
                await nm.sendDriveChangedNotification(status: .sync)

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

                await nm.sendDriveChangedNotificationWithDebounce(status: .idle)
                complete(fileURL, s3Item, alignedRange, [], nil)
            } catch let s3Error as S3ErrorType {
                self.logger.error("Partial download failed with S3 error \(s3Error.errorCode, privacy: .public)")
                await nm.sendDriveChangedNotificationWithDebounce(status: .error)
                complete(nil, nil, NSRange(location: 0, length: 0), [], s3Error.toFileProviderError())
            } catch {
                self.logger.error("Partial download failed for \(itemIdentifier.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
                await nm.sendDriveChangedNotificationWithDebounce(status: .error)
                complete(nil, nil, NSRange(location: 0, length: 0), [], NSFileProviderError(.cannotSynchronize) as NSError)
            }
        }

        progress.cancellationHandler = {
            task.cancel()
            complete(nil, nil, NSRange(location: 0, length: 0), [], NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
        }

        return progress
    }
}
#endif
