import Foundation
import SwiftUI
import os.log
import DS3Lib

enum SyncAnchorSelectionError: Error, LocalizedError {
    case missingBuckets
    case noBucketSelected
    case noIAMUserSelected
    case DS3ClientError
    case DS3ServerError

    var errorDescription: String? {
        switch self {
        case .missingBuckets:
            return NSLocalizedString("No buckets found in server response", comment: "Missing buckets in response")
        case .noBucketSelected:
            return NSLocalizedString("You need to select a bucket first", comment: "Bucket not selected")
        case .noIAMUserSelected:
            return NSLocalizedString("You need to select an IAM user first", comment: "IAM not selected")
        case .DS3ClientError:
            return NSLocalizedString("DS3 Client error. Please try refreshing credentials", comment: "DS3 client error")
        case .DS3ServerError:
            return NSLocalizedString("DS3 Server error. Please retry later", comment: "DS3 server error")
        }
    }
}

@MainActor @Observable class SyncAnchorSelectionViewModel {
    typealias Logger = os.Logger

    private let logger: Logger = Logger(subsystem: LogSubsystem.app, category: LogCategory.sync.rawValue)

    var project: Project
    var authentication: DS3Authentication
    var ds3Sdk: DS3SDK
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
        self.ds3Sdk = DS3SDK(withAuthentication: authentication)
        self.buckets = buckets
        self.folders = folders

        if !self.buckets.isEmpty {
            self.selectedBucket = self.buckets.first
        }
    }

    func shutdownClient() {
        try? s3Client?.shutdown()
    }

    func loadBuckets() async {
        self.loading = true
        self.error = nil

        defer { self.loading = false }

        do {
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

        do {
            guard let selectedBucket = self.selectedBucket else { throw SyncAnchorSelectionError.noBucketSelected }

            self.logger.debug("Listing objects for bucket \(selectedBucket.name) and prefix \(self.selectedPrefix?.removingPercentEncoding ?? "no-prefix")")

            try await self.initializeClient()

            guard let client = self.s3Client else { throw SyncAnchorSelectionError.DS3ClientError }

            let result = try await client.listObjects(
                bucket: selectedBucket.name,
                prefix: self.selectedPrefix?.removingPercentEncoding,
                delimiter: String(DefaultSettings.S3.delimiter)
            )

            self.cleanFoldersIfNeeded()

            for prefix in result.commonPrefixes {
                self.folders[self.selectedPrefix ?? ""]?.append(prefix)
            }
        } catch {
            self.logger.error("An error occurred while listing objects \(error)")
            self.error = error
        }
    }

    func initializeClient(force: Bool = false) async throws {
        guard force || s3Client == nil else { return }
        guard let account = self.authentication.account else { return }

        try? s3Client?.shutdown()

        guard let selectedIAMUser = self.selectedIAMUser else {
            throw SyncAnchorSelectionError.noIAMUserSelected
        }

        self.logger.debug("Initializing S3Client for project \(self.project.name) and user \(selectedIAMUser.username)")

        let apiKeys = try await self.ds3Sdk.loadOrCreateDS3APIKeys(
            forIAMUser: selectedIAMUser,
            ds3ProjectName: self.project.name
        )

        guard let secretKey = apiKeys.secretKey else {
            throw SyncAnchorSelectionError.DS3ClientError
        }

        self.s3Client = DS3S3Client(
            accessKeyId: apiKeys.apiKey,
            secretAccessKey: secretKey,
            endpoint: account.endpointGateway
        )
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
