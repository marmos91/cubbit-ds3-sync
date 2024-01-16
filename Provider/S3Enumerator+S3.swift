import Foundation
import FileProvider
import SotoS3

extension S3Enumerator {
   func listS3Items(
    withS3 s3: S3,
    forDrive drive: DS3Drive,
    withPrefix prefix: String? = nil,
    withContinuationToken continuationToken: String? = nil,
    fromDate date: Date? = nil
   ) async throws -> ([S3Item]?, String?) {
       let request = S3.ListObjectsV2Request(
            bucket: drive.syncAnchor.bucket.name,
            continuationToken: continuationToken,
            encodingType: .url,
            maxKeys: DefaultSettings.S3.listBatchSize,
            prefix: prefix
       )
       
       let response = try await s3.listObjectsV2(request)
       var items: [S3Item] = []
       
       guard let contents = response.contents else {
           // If no objects are returned, we are done
           return (nil, nil)
       }
       
       for object in contents {
           guard let key = object.key?.removingPercentEncoding else {
               continue
           }
           
           if object.key == prefix {
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
       
       guard let isTruncated = response.isTruncated else {
           throw EnumeratorError.missingParameters
       }
       
       if !isTruncated {
           return (items, nil)
       }
       
       return (items, response.nextContinuationToken)
   }
}
