import Foundation
import FileProvider
import SotoS3
import os.log

extension S3Enumerator {
   func listS3Items(
    withS3 s3: S3,
    forDrive drive: DS3Drive,
    withPrefix prefix: String? = nil,
    recursively: Bool = true,
    withContinuationToken continuationToken: String? = nil,
    fromDate date: Date? = nil,
    withLogger logger: Logger? = nil
   ) async throws -> ([S3Item], String?) {       
       logger?.debug("Listing bucket \(drive.syncAnchor.bucket.name) for prefix \(prefix ?? "no-prefix") recursively=\(recursively)")
       
       let request = S3.ListObjectsV2Request(
            bucket: drive.syncAnchor.bucket.name,
            continuationToken: continuationToken,
            delimiter: !recursively ? String(DefaultSettings.S3.delimiter) : nil,
            encodingType: .url,
            maxKeys: DefaultSettings.S3.listBatchSize,
            prefix: prefix
       )
       
       let response = try await s3.listObjectsV2(request)
       var items: [S3Item] = []
       
       if let commonPrefixes = response.commonPrefixes {
           logger?.debug("Parsing \(commonPrefixes.count) commonPrefixes")
           
           for commonPrefix in commonPrefixes {
               guard let commonPrefix = commonPrefix.prefix?.removingPercentEncoding else {
                   continue
               }
               
               items.append(
                    S3Item(
                        identifier: NSFileProviderItemIdentifier(commonPrefix),
                        drive: drive,
                        objectMetadata: S3Item.Metadata(
                            size: 0
                        )
                    )
               )
           }
       }
       
       if let contents = response.contents {
           for object in contents {
               guard let key = object.key?.removingPercentEncoding else {
                   continue
               }
               
               if key == prefix {
                   // NOTE: Skipping the prefix itself as we don't want the folder root to be listed
                   continue
               }
               
               let s3Item = S3Item(
                    identifier: NSFileProviderItemIdentifier(key),
                    drive: drive,
                    objectMetadata: S3Item.Metadata(
                        etag: object.eTag,
                        lastModified: object.lastModified,
                        size: (object.size ?? 0) as NSNumber
                    )
               )
               
               if date != nil {
                   guard let lastModified = object.lastModified else {
                       continue
                   }
                   
                   if lastModified > date! {
                       items.append(s3Item)
                   }
               } else {
                   items.append(s3Item)
               }
           }
       }
       
       guard let isTruncated = response.isTruncated else {
           throw EnumeratorError.missingParameters
       }
       
       if !isTruncated {
           return (items, nil)
       }
       
       return (items, response.nextContinuationToken)
   }
}
