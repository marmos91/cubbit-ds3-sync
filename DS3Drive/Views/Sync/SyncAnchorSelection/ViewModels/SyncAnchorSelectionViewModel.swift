import Foundation
import SwiftUI
import SotoS3
import os.log

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

@Observable class SyncAnchorSelectionViewModel {
    typealias Logger = os.Logger
    
    private let logger: Logger = Logger(subsystem: "io.cubbit.CubbitDS3Sync", category: "SyncAnchorSelectionViewModel")
    
    var project: Project
    var authentication: DS3Authentication
    var ds3Sdk: DS3SDK
    var s3Client: S3?
    
    var buckets: [Bucket] = []
    var loading: Bool = true
    var selectedIAMUser: IAMUser?
    var selectedBucket: Bucket? = nil
    
    var folders: [String: [String]] = [:]
    var selectedPrefix: String? = nil
    
    var error: Error? = nil
    var authenticationError: DS3AuthenticationError? = nil
    
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
        
        if self.buckets.count > 0 {
            self.selectedBucket = self.buckets.first
        }
    }
   
    deinit {
        do {
            try self.s3Client?.client.syncShutdown()
        } catch {
            self.logger.error("Fatal: cannot shutdown S3 client")
        }
    }
    
    @MainActor
    func loadBuckets() async {
        self.loading = true
        self.error = nil
        
        defer { self.loading = false }
        
        do {
            try await self.initializeAWSIfNecessary()
            
            self.logger.debug("Loading buckets for project \(self.project.name)")
            
            let bucketsResponse = try await self.s3Client!.listBuckets()
            
            guard let s3Buckets = bucketsResponse.buckets else { throw SyncAnchorSelectionError.missingBuckets }
            
            let buckets = s3Buckets.map { s3bucket in
                return Bucket(name: s3bucket.name ?? "<No name>")
            }
            
            self.buckets = buckets
            
            if self.buckets.count > 0 {
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
            guard self.selectedBucket != nil else { throw SyncAnchorSelectionError.noBucketSelected }
                        
            self.logger.debug("Listing objects for bucket \(self.selectedBucket!.name) and prefix \(self.selectedPrefix?.removingPercentEncoding ?? "no-prefix")")
            
            try await self.initializeAWSIfNecessary()
            
            let listObjectRequest = S3.ListObjectsV2Request(
                bucket: self.selectedBucket!.name,
                delimiter: String(DefaultSettings.S3.delimiter),
                encodingType: .url,
                prefix: self.selectedPrefix?.removingPercentEncoding
            )
            
            let listObjectResponse = try await self.s3Client!.listObjectsV2(listObjectRequest)
            
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
        guard self.authentication.account != nil else { return }
        
        if self.s3Client != nil {
            try self.s3Client!.client.syncShutdown()
        }
        
        guard self.selectedIAMUser != nil else { throw SyncAnchorSelectionError.noIAMUserSelected }
        
        self.logger.debug("Initializing S3Client for project \(self.project.name) and user \(self.selectedIAMUser!.username)")
        
        let apiKeys = try await self.ds3Sdk.loadOrCreateDS3APIKeys(forIAMUser: self.selectedIAMUser!, ds3ProjectName: self.project.name)
        
        let awsClient = AWSClient(credentialProvider: .static(accessKeyId: apiKeys.apiKey, secretAccessKey: apiKeys.secretKey!), httpClientProvider: .createNew)
        
        self.s3Client = S3(client: awsClient, endpoint: self.authentication.account!.endpointGateway)
    }
    
    func selectIAMUser(withID id: String) async throws {
        guard self.project.users.count > 0 else { return }
        
        guard let index = self.project.users.lastIndex(where: {$0.id == id}) else { return }
        
        self.selectedIAMUser = self.project.users[index]
        
        try await self.initializeAWSIfNecessary()
    }
    
    func cleanFoldersIfNeeded() {
        let prefix = self.selectedPrefix ?? ""
        
        self.folders.keys.forEach { key in
            guard key != "" else { return }
            
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
        guard self.buckets.count > 0 else { return }
        
        guard let index = self.buckets.lastIndex(where: {$0.name == name}) else { return }
        
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
        return self.folders.count > 0
    }
    
    func getSelectedSyncAnchor() -> SyncAnchor? {
        guard 
            self.selectedBucket != nil,
            self.selectedIAMUser != nil
        else { return nil }
        
        return SyncAnchor(
            project: self.project,
            IAMUser: self.selectedIAMUser!,
            bucket: self.selectedBucket!,
            prefix: self.selectedPrefix
        )
    }
}
