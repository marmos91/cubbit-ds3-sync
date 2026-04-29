import DS3Lib

@preconcurrency import FileProvider
import os.log
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

    var ds3Client: DS3Client?
    var s3Client: DS3S3Client?
    var s3Lib: S3Lib?

    var apiKeys: DS3ApiKey?
    var endpoint: String?
    var notificationManager: NotificationManager?
    var metadataStore: MetadataStore?
    var purgeTask: Task<Void, Never>?
    var commandListenerTask: Task<Void, Never>?
    var workingSetSignallerTask: Task<Void, Never>?

    // Limits concurrent fetchContents/fetchPartialContents calls to prevent
    // HTTP/2 stream exhaustion (NIOHTTP2.StreamClosed errors).
    #if os(iOS)
        let fetchSemaphore = AsyncSemaphore(value: 4)
    #else
        let fetchSemaphore = AsyncSemaphore(value: 20)
    #endif

    /// Bounds concurrent thumbnail GETs from `fetchThumbnails` (Phase 13 D-12,
    /// THUMB-14). macOS=4. Mirror of `BucketListingLimiter` for the consume
    /// path. Upload generator and backfill coordinator do NOT route through
    /// this limiter (Pitfall 4).
    let thumbnailFetchLimiter = ThumbnailFetchLimiter(maxSlots: 4)

    /// Phase 13.2 D-02: 2-slot limiter for the cache-miss fallback render path.
    /// Strict separation from the 4-slot `thumbnailFetchLimiter` (cached-thumb
    /// GETs) prevents heavy fallbacks (full-original download + render) from
    /// starving the cheap hot path. Also holds the in-memory strike counter
    /// + poison-key set for THUMB-20 reframed (D-19, D-20, D-21).
    let thumbnailFallbackLimiter = ThumbnailFallbackLimiter()

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

            let ds3Client = try DS3Client(drive: drive)
            self.ds3Client = ds3Client
            self.s3Client = ds3Client.driveS3Client
            self.endpoint = ds3Client.endpoint
            self.apiKeys = ds3Client.apiKeys

            // swiftlint:disable:next force_unwrapping
            self.s3Lib = S3Lib(withClient: self.s3Client!, withNotificationManager: self.notificationManager!)

            do {
                let container = try MetadataStore.createContainer()
                self.metadataStore = MetadataStore(modelContainer: container)
            } catch {
                logger
                    .warning(
                        "Failed to initialize MetadataStore: \(error.localizedDescription, privacy: .public). Extension will work without offline cache."
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
        self.startAutoPurge()
        self.startCommandListener()
        self.startWorkingSetSignaller()

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
        self.purgeTask?.cancel()
        self.purgeTask = nil
        self.commandListenerTask?.cancel()
        self.commandListenerTask = nil
        self.workingSetSignallerTask?.cancel()
        self.workingSetSignallerTask = nil

        if let nm = self.notificationManager {
            Task { await nm.shutdown() }
        }

        if let s3Lib = self.s3Lib {
            Task { try? await s3Lib.shutdown() }
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
        let filename = key.split(separator: DefaultSettings.S3.delimiter).last.map(String.init) ?? key
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
            self.logger.debug("item(for:) cache hit for \(identifier.rawValue, privacy: .public) isFolder=\(isFolder)")
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
            self.logger.debug("item(for:) folder shortcut for \(identifier.rawValue, privacy: .public)")
            return S3Item(
                identifier: identifier,
                drive: drive,
                objectMetadata: S3Item.Metadata(size: NSNumber(value: 0))
            )
        }

        self.logger.debug("item(for:) S3 HEAD for \(identifier.rawValue, privacy: .public)")
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
            } catch let s3Error as AWSErrorType {
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
    /// Discovery of the folder's children is driven reactively by Apple's
    /// `enumerateItems`, so no proactive indexer call is needed here.
    func materializeFolderItem(
        _ itemIdentifier: NSFileProviderItemIdentifier,
        drive: DS3Drive,
        temporaryDirectory: URL,
        completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        logger.debug("Materializing folder item: \(itemIdentifier.rawValue, privacy: .public)")

        // Notify the tray immediately so the user sees feedback (Phase 13.2 D-16:
        // transient indexing pulses now collapse to `.sync` via the existing
        // active-operations counter — no dedicated `.indexing` state).
        if let nm = self.notificationManager {
            Task { await nm.sendDriveChangedNotification(status: .sync) }
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
            // The folder is now "downloaded" from Apple's POV; flag it as a
            // working-set member so it participates in drift detection.
            let store = self.metadataStore
            let key = itemIdentifier.rawValue
            let driveId = drive.id
            let logger = self.logger
            Task {
                do {
                    try await store?.setMaterialized(
                        s3Key: key, driveId: driveId, isMaterialized: true
                    )
                } catch {
                    logger.warning(
                        "materializeFolderItem: setMaterialized failed for \(key, privacy: .public): \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
        } catch {
            completionHandler(nil, nil, NSFileProviderError(.cannotSynchronize) as NSError)
        }
        progress.completedUnitCount = 1

        return progress
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

        manager.signalEnumerator(for: .workingSet) { [weak self] error in
            if let error {
                self?.logger.error("Failed to signal working set: \(error.localizedDescription, privacy: .public)")
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
            // Bounded set: items the user has materialised. The system polls
            // this enumerator out-of-band from folder navigation so
            // materialised files reconcile without the user re-opening their
            // parent folder.
            return WorkingSetEnumerator(
                s3Lib: s3Lib,
                drive: drive,
                metadataStore: self.metadataStore
            )

        default:
            // User is navigating Finder/Files.app. Lazy direct-children
            // enumeration; remote deletions surface via `enumerateChanges`
            // when the user navigates back. Out-of-band remote deletions
            // for non-materialised items only surface on the next user
            // navigation — see issue #140 for the working-set-expansion
            // follow-up.
            return S3Enumerator(
                parent: containerItemIdentifier,
                s3Lib: s3Lib,
                notificationManager: nm,
                drive: drive,
                metadataStore: self.metadataStore
            )
        }
    }
}
