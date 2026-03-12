import Foundation
import SwiftUI
import SotoS3
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
    var s3Client: S3?
    /// Stored separately for shutdown in deinit (nonisolated context)
    nonisolated(unsafe) private var _awsClient: AWSClient?

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
   
    deinit {
        try? _awsClient?.syncShutdown()
    }
    
    @MainActor
    func loadBuckets() async {
        self.loading = true
        self.error = nil
        
        defer { self.loading = false }
        
        do {
            try await self.initializeAWSIfNecessary()
            
            self.logger.debug("Loading buckets for project \(self.project.name)")
            
            guard let s3Client = self.s3Client else { throw SyncAnchorSelectionError.DS3ClientError }
            let bucketsResponse = try await s3Client.listBuckets()
            
            guard let s3Buckets = bucketsResponse.buckets else { throw SyncAnchorSelectionError.missingBuckets }
            
            let buckets = s3Buckets.map { s3bucket in
                return Bucket(name: s3bucket.name ?? "<No name>")
            }
            
            self.buckets = buckets
            
            if !self.buckets.isEmpty {
                self.selectBucket(self.buckets.first)

                await self.listFoldersForCurrentBucket()
            }
        } catch is AWSClientError {
            self.error = SyncAnchorSelectionError.DS3ClientError
        } catch is AWSServerError {
            self.error = SyncAnchorSelectionError.DS3ServerError
        } catch let error as DS3AuthenticationError {
            self.authenticationError = error
        } catch {
            self.logger.error("An error occurred while loading buckets \(error)")
            self.error = error
        }
    }
    
    @MainActor
    func listFoldersForCurrentBucket() async {
        self.loading = true
        self.error = nil
        
        defer { self.loading = false }
        
        do {
            guard let selectedBucket = self.selectedBucket else { throw SyncAnchorSelectionError.noBucketSelected }

            self.logger.debug("Listing objects for bucket \(selectedBucket.name) and prefix \(self.selectedPrefix?.removingPercentEncoding ?? "no-prefix")")

            try await self.initializeAWSIfNecessary()

            let listObjectRequest = S3.ListObjectsV2Request(
                bucket: selectedBucket.name,
                delimiter: String(DefaultSettings.S3.delimiter),
                encodingType: .url,
                prefix: self.selectedPrefix?.removingPercentEncoding
            )
            
            guard let s3Client = self.s3Client else { throw SyncAnchorSelectionError.DS3ClientError }
            let listObjectResponse = try await s3Client.listObjectsV2(listObjectRequest)
            
            self.cleanFoldersIfNeeded()
            
            listObjectResponse.commonPrefixes?.forEach { commonPrefix in
                if let prefix = commonPrefix.prefix {
                    self.folders[self.selectedPrefix ?? ""]?.append(prefix)
                }
            }
        } catch {
            self.logger.error("An error occurred while listing objects \(error)")
            self.error = error
        }
    }
    
    func initializeAWSIfNecessary() async throws {
        guard let account = self.authentication.account else { return }

        if let existingClient = self._awsClient {
            try existingClient.syncShutdown()
        }

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

        let awsClient = AWSClient(
            credentialProvider: .static(
                accessKeyId: apiKeys.apiKey,
                secretAccessKey: secretKey
            ),
            httpClientProvider: .createNew
        )

        self._awsClient = awsClient
        self.s3Client = S3(client: awsClient, endpoint: account.endpointGateway)
    }
    
    func selectIAMUser(withID id: String) async throws {
        guard !self.project.users.isEmpty else { return }

        guard let index = self.project.users.lastIndex(where: { $0.id == id }) else { return }
        
        self.selectedIAMUser = self.project.users[index]
        
        try await self.initializeAWSIfNecessary()
    }
    
    func cleanFoldersIfNeeded() {
        let prefix = self.selectedPrefix ?? ""

        self.folders.keys.forEach { key in
            guard !key.isEmpty else { return }

            if !prefix.hasPrefix(key) {
                self.folders.removeValue(forKey: key)
            }
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
        guard !self.buckets.isEmpty else { return }

        guard let index = self.buckets.lastIndex(where: { $0.name == name }) else { return }
        
        self.selectedBucket = self.buckets[index]
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
        return !self.folders.isEmpty
    }

    func getSelectedSyncAnchor() -> SyncAnchor? {
        guard
            let selectedBucket = self.selectedBucket,
            let selectedIAMUser = self.selectedIAMUser
        else { return nil }

        return SyncAnchor(
            project: self.project,
            IAMUser: selectedIAMUser,
            bucket: selectedBucket,
            prefix: self.selectedPrefix
        )
    }
}
