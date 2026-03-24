import DS3Lib

@preconcurrency import FileProvider
import os.log
import SotoS3
import SwiftData

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

class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension,
    NSFileProviderCustomAction, NSFileProviderThumbnailing, @unchecked Sendable {
    typealias Logger = os.Logger

    let logger: Logger = .init(subsystem: LogSubsystem.provider, category: LogCategory.extension.rawValue)

    let domain: NSFileProviderDomain
    var enabled: Bool

    var s3Client: DS3S3Client?
    var s3Lib: S3Lib?

    var apiKeys: DS3ApiKey?
    var endpoint: String?
    var notificationManager: NotificationManager?
    var metadataStore: MetadataStore?
    private var syncEngine: SyncEngine?
    private var networkMonitor: NetworkMonitor?
    var pollingTask: Task<Void, Never>?
    var purgeTask: Task<Void, Never>?

    /// Proactive breadth-first indexer that populates MetadataStore level-by-level.
    var breadthFirstIndexer: BreadthFirstIndexer?

    // Limits concurrent fetchContents/fetchPartialContents calls to prevent
    // HTTP/2 stream exhaustion (NIOHTTP2.StreamClosed errors).
    #if os(iOS)
        let fetchSemaphore = AsyncSemaphore(value: 4)
    #else
        let fetchSemaphore = AsyncSemaphore(value: 20)
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

            let client = DS3S3Client(
                accessKeyId: apiKeys.apiKey,
                secretAccessKey: secretKey,
                endpoint: endpoint
            )
            self.s3Client = client

            // swiftlint:disable:next force_unwrapping
            self.s3Lib = S3Lib(withClient: client, withNotificationManager: self.notificationManager!)

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
                logger
                    .warning(
                        "Failed to initialize MetadataStore/SyncEngine: \(error.localizedDescription, privacy: .public). Extension will work without sync engine."
                    )
            }

            self.enabled = true
            logger.info("Extension initialized successfully for domain \(domain.identifier.rawValue, privacy: .public)")
        } catch {
            logger
                .error(
                    "Extension init failed for domain \(domain.identifier.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            super.init()
            self.notifyInitFailure(reason: error.localizedDescription)
            return
        }

        super.init()
        self.startPolling()
        self.warmCacheThenStartBFS()
        self.startAutoPurge()

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
        self.purgeTask?.cancel()
        self.purgeTask = nil
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

    /// Resolves the `.trash/` key for an item, checking MetadataStore first, then falling back
    /// to the flat trash key (just the filename under `.trash/`).
    func resolveTrashKey(
        forOriginalKey key: String,
        drive: DS3Drive,
        metadataStore: MetadataStore?
    ) async -> String {
        if let stored = try? await metadataStore?.fetchTrashKey(
            forOriginalKey: key, driveId: drive.id
        ) {
            return stored
        }
        let filename = key.split(separator: "/").last.map(String.init) ?? key
        return S3Lib.fullTrashPrefix(forDrive: drive) + filename
    }

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
        do {
            return try await s3Lib.remoteS3Item(for: identifier, drive: drive)
        } catch {
            // If the original key 404s, check whether the item lives in .trash/.
            let trashKey = await resolveTrashKey(
                forOriginalKey: identifier.rawValue, drive: drive, metadataStore: metadataStore
            )
            let trashIdentifier = NSFileProviderItemIdentifier(trashKey)
            if let trashedItem = try? await s3Lib.remoteS3Item(for: trashIdentifier, drive: drive) {
                self.logger.info("item(for:) found in trash: \(trashKey, privacy: .public)")
                return S3Item(
                    identifier: identifier,
                    drive: drive,
                    objectMetadata: trashedItem.metadata,
                    forcedTrashed: true
                )
            }
            throw error
        }
    }

    // MARK: - Protocol methods

    /// Note: gets called when the extension wants to retrieve metadata for a specific item
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

        if identifier == .trashContainer || identifier == .rootContainer {
            let item = S3Item(
                identifier: identifier,
                drive: drive,
                objectMetadata: S3Item.Metadata(size: NSNumber(value: 0))
            )
            completionHandler(item, nil)
            return Progress()
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
                if identifier.rawValue.hasSuffix(String(DefaultSettings.S3.delimiter)), s3Error.isNotFound {
                    let folderSyncStatus = try? await metadataStore?.fetchItemSyncStatus(
                        byKey: identifier.rawValue,
                        driveId: drive.id
                    )
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

    /// Marks a failed item and its parent folder with error status in MetadataStore,
    /// then signals the system to re-enumerate so error decorations show in Finder.
    func markItemAndParentAsError(itemKey: String, driveId: UUID, metadataStore: MetadataStore?) async {
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
    func materializeFolderItem(
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
            Task { try? await store?.setMaterialized(
                s3Key: itemIdentifier.rawValue,
                driveId: drive.id,
                isMaterialized: true
            ) }
        } catch {
            completionHandler(nil, nil, NSFileProviderError(.cannotSynchronize) as NSError)
        }
        progress.completedUnitCount = 1
        breadthFirstIndexer?.prioritize(prefix: itemIdentifier.rawValue)

        return progress
    }

    /// Returns true when the drive is paused, logging the deferred operation name.
    func isDrivePaused(_ driveId: UUID, operation: String) -> Bool {
        guard (try? SharedData.default().isDrivePaused(driveId)) == true else { return false }
        logger.info("Drive paused, deferring \(operation, privacy: .public) operation")
        return true
    }

    /// Signals the system to re-enumerate changes after a local CRUD operation.
    func signalChanges() {
        guard let manager = NSFileProviderManager(for: self.domain) else {
            logger
                .warning(
                    "Cannot signal enumerator: no manager for domain \(self.domain.identifier.rawValue, privacy: .public)"
                )
            return
        }

        manager.signalEnumerator(for: .workingSet) { error in
            if let error {
                self.logger.error("Failed to signal working set: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// NOTE: gets called when the extension wants to get an enumerator for a folder
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
            return TrashS3Enumerator(s3Lib: s3Lib, drive: drive, metadataStore: self.metadataStore)

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
