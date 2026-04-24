import DS3Lib
import Foundation
import os.log
import SwiftUI

enum SyncAnchorSelectionError: Error, LocalizedError {
    case missingBuckets
    case noBucketSelected
    case noIAMUserSelected
    case DS3ClientError
    case DS3ServerError

    var errorDescription: String? {
        switch self {
        case .missingBuckets:
            NSLocalizedString("No buckets found in server response", comment: "Missing buckets in response")
        case .noBucketSelected:
            NSLocalizedString("You need to select a bucket first", comment: "Bucket not selected")
        case .noIAMUserSelected:
            NSLocalizedString("You need to select an IAM user first", comment: "IAM not selected")
        case .DS3ClientError:
            NSLocalizedString("DS3 Client error. Please try refreshing credentials", comment: "DS3 client error")
        case .DS3ServerError:
            NSLocalizedString("DS3 Server error. Please retry later", comment: "DS3 server error")
        }
    }
}

@MainActor @Observable
class SyncAnchorSelectionViewModel {
    typealias Logger = os.Logger

    private let logger = Logger(subsystem: LogSubsystem.app, category: LogCategory.sync.rawValue)

    var project: Project
    var authentication: DS3Authentication
    var ds3Client: DS3Client
    var s3Client: DS3S3Client?

    var buckets: [Bucket] = []
    var loading: Bool = true
    var selectedIAMUser: IAMUser?
    var selectedBucket: Bucket?

    var folders: [String: [String]] = [:]
    var selectedPrefix: String?

    var error: Error?
    var authenticationError: DS3AuthenticationError?

    init(
        project: Project,
        authentication: DS3Authentication,
        buckets: [Bucket] = [],
        folders: [String: [String]] = [:]
    ) {
        self.project = project
        self.authentication = authentication
        self.selectedIAMUser = project.users.first
        self.ds3Client = DS3Client(authentication: authentication)
        self.buckets = buckets
        self.folders = folders

        if !self.buckets.isEmpty {
            self.selectedBucket = self.buckets.first
        }
    }

    func shutdownClient() {
        ds3Client.shutdown()
    }

    func loadBuckets() async {
        self.loading = true
        self.error = nil

        defer { self.loading = false }

        do {
            // Gap 1: refresh access token before any S3 call so an expired
            // token recovers transparently via the still-valid refresh cookie.
            try? await authentication.refreshIfNeeded()
            try await self.initializeClient()

            self.logger.debug("Loading buckets for project \(self.project.name)")

            guard let client = self.s3Client else { throw SyncAnchorSelectionError.DS3ClientError }
            let bucketList = try await client.listBuckets()

            if bucketList.isEmpty { throw SyncAnchorSelectionError.missingBuckets }

            let buckets = bucketList.map { Bucket(name: $0.name) }

            self.buckets = buckets

            if !self.buckets.isEmpty {
                self.selectBucket(self.buckets.first)

                await self.listFoldersForCurrentBucket()
            }
        } catch let error as DS3AuthenticationError {
            self.authenticationError = error
        } catch {
            self.logger.error("An error occurred while loading buckets \(error)")
            self.error = error
        }
    }

    func listFoldersForCurrentBucket() async {
        self.loading = true
        self.error = nil

        defer { self.loading = false }

        let start = Date()
        do {
            try? await authentication.refreshIfNeeded()
            guard let selectedBucket = self.selectedBucket else { throw SyncAnchorSelectionError.noBucketSelected }

            let prefixLabel = self.selectedPrefix?.removingPercentEncoding ?? "no-prefix"
            let clientCached = self.s3Client != nil
            self.logger.info(
                "listFolders start bucket=\(selectedBucket.name, privacy: .public) prefix=\(prefixLabel, privacy: .public) clientCached=\(clientCached, privacy: .public)"
            )

            try await self.initializeClient()

            guard let client = self.s3Client else { throw SyncAnchorSelectionError.DS3ClientError }

            let result = try await client.listObjects(
                bucket: selectedBucket.name,
                prefix: self.selectedPrefix?.removingPercentEncoding,
                delimiter: String(DefaultSettings.S3.delimiter)
            )

            self.cleanFoldersIfNeeded()

            // Filter .thumbnails/ and .trash/ from wizard folder browser (Phase 11)
            let visiblePrefixes = result.commonPrefixes.filter { S3KeyFilter.isUserVisible(key: $0, drivePrefix: self.selectedPrefix) }
            for prefix in visiblePrefixes {
                self.folders[self.selectedPrefix ?? ""]?.append(prefix)
            }

            let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)
            self.logger.info(
                "listFolders ok bucket=\(selectedBucket.name, privacy: .public) foundPrefixes=\(result.commonPrefixes.count, privacy: .public) elapsedMs=\(elapsedMs, privacy: .public)"
            )
        } catch {
            // Only the localized description is safe to log publicly —
            // `String(describing: error)` on Soto/NIO errors can leak full
            // request URLs, headers, or response bodies into the system
            // log. Keep the raw error at `.private` for on-device debug.
            let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)
            self.logger.error(
                "listFolders failed elapsedMs=\(elapsedMs, privacy: .public) error=\(error.localizedDescription, privacy: .public) raw=\(String(describing: error), privacy: .private)"
            )
            self.error = error
        }
    }

    func initializeClient(force: Bool = false) async throws {
        guard force || s3Client == nil else { return }

        try? s3Client?.shutdown()

        guard let selectedIAMUser = self.selectedIAMUser else {
            throw SyncAnchorSelectionError.noIAMUserSelected
        }

        self.logger.debug("Initializing S3Client for project \(self.project.name) and user \(selectedIAMUser.username)")

        self.s3Client = try await ds3Client.s3Client(forProject: self.project, iamUser: selectedIAMUser)
    }

    func selectIAMUser(withID id: String) async {
        guard let user = self.project.users.first(where: { $0.id == id }) else { return }

        self.selectedIAMUser = user

        // Reset bucket/folder state and reload with the new user's credentials
        self.buckets = []
        self.selectedBucket = nil
        self.selectedPrefix = nil
        self.folders = [:]
        self.s3Client = nil

        await self.loadBuckets()
    }

    func cleanFoldersIfNeeded() {
        let prefix = self.selectedPrefix ?? ""

        for key in self.folders.keys where !key.isEmpty && !prefix.hasPrefix(key) {
            self.folders.removeValue(forKey: key)
        }

        if self.folders[prefix] == nil {
            self.folders[prefix] = []
        }
    }

    func selectFolder(withPrefix prefix: String) async {
        self.selectedPrefix = prefix

        await self.listFoldersForCurrentBucket()
    }

    func selectBucket(withName name: String) async {
        guard let bucket = self.buckets.first(where: { $0.name == name }) else { return }

        self.selectedBucket = bucket
        self.selectedPrefix = nil
        self.folders = [:]

        await self.listFoldersForCurrentBucket()
    }

    func selectBucket(_ bucket: Bucket?) {
        self.selectedBucket = bucket
        self.selectedPrefix = nil
        self.folders = [:]
    }

    func shouldDisplayObjectNavigator() -> Bool {
        !self.folders.isEmpty
    }

    func getSelectedSyncAnchor() -> SyncAnchor? {
        guard let bucket = selectedBucket, let user = selectedIAMUser else { return nil }

        return SyncAnchor(
            project: project,
            IAMUser: user,
            bucket: bucket,
            prefix: selectedPrefix
        )
    }
}
