import Foundation
import SwiftUI
import SotoS3
import os.log

@Observable class SyncAnchorSelectionViewModel {
    typealias Logger = os.Logger
    
    private let logger: Logger = Logger(subsystem: "io.cubbit.CubbitDS3Sync", category: "SyncAnchorSelectionViewModel")
    
    var project: Project
    var authentication: DS3Authentication
    var ds3Sdk: DS3SDK
    var s3Client: S3?
    
    var buckets: [Bucket] = []
    var loading: Bool = false
    var selectedIAMUser: IAMUser?
    var selectedBucket: Bucket? = nil
    
    var folders: [String: [String]] = [:]
    var selectedPrefix: String? = nil
    
    var error: Error? = nil
    
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
        
        defer { self.loading = false }
        
        do {
            // TODO: Improve errors
          
            await self.initializeAWSIfNecessary()
            
            let bucketsResponse = try await self.s3Client!.listBuckets()
            
            guard let s3Buckets = bucketsResponse.buckets else { fatalError("Cannot find buckets inside bucket response") }
            
            let buckets = s3Buckets.map { s3bucket in
                return Bucket(name: s3bucket.name ?? "<No name>")
            }
            
            self.buckets = buckets
            
            if self.buckets.count > 0 {
                self.selectBucket(self.buckets.first)
                
                await self.listFoldersForCurrentBucket()
            }
        } catch {
            self.error = error
        }
    }
    
    @MainActor
    func listFoldersForCurrentBucket() async {
        self.loading = true
        
        defer { self.loading = false }
        
        do {
            // TODO: Improve errors
            
            guard self.selectedBucket != nil else { fatalError("You need to select a Bucket before listing folders") }
                        
            self.logger.debug("Listing objects for bucket \(self.selectedBucket!.name) and prefix \(self.selectedPrefix?.removingPercentEncoding ?? "no-prefix")")
            
            await self.initializeAWSIfNecessary()
            
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
    
    func initializeAWSIfNecessary() async {
        guard self.s3Client == nil else { return }
        guard self.authentication.account != nil else { return }
        
        do {
            // TODO: Improve error
            guard self.selectedIAMUser != nil else { fatalError("You need to select a IAM user") }
            
            let apiKeys = try await self.ds3Sdk.loadOrCreateDS3APIKeys(forIAMUser: self.selectedIAMUser!, ds3ProjectName: self.project.name)
            
            let awsClient = AWSClient(credentialProvider: .static(accessKeyId: apiKeys.apiKey, secretAccessKey: apiKeys.secretKey!), httpClientProvider: .createNew)
            
            self.s3Client = S3(client: awsClient, endpoint: self.authentication.account!.endpointGateway)
        } catch {
            self.logger.error("An error occurred while initializing AWS \(error)")
            self.error = error
        }
    }
    
    func selectIAMUser(withID id: String) {
        guard self.project.users.count > 0 else { return }
        
        guard let index = self.project.users.lastIndex(where: {$0.id == id}) else { return }
        
        self.selectedIAMUser = self.project.users[index]
        
        Task {
            await self.initializeAWSIfNecessary()
        }
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
    
    func selectFolder(withPrefix prefix: String) {
        self.selectedPrefix = prefix
        
        Task {
            await self.listFoldersForCurrentBucket()
        }
    }
    
    func selectBucket(withName name: String) {
        guard self.buckets.count > 0 else { return }
        
        guard let index = self.buckets.lastIndex(where: {$0.name == name}) else { return }
        
        self.selectedBucket = self.buckets[index]
        self.selectedPrefix = nil
        self.folders = [:]
        
        Task {
            await self.listFoldersForCurrentBucket()
        }
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
