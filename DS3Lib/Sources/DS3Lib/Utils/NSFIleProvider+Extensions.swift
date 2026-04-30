import FileProvider
import Foundation

/// Bridges S3 `ListObjectsV2` continuation tokens to `NSFileProviderPage`.
public extension NSFileProviderPage {
    init(_ continuationToken: String) {
        if let data = continuationToken.data(using: .utf8) {
            self.init(rawValue: data)
        } else {
            self.init(rawValue: Data())
        }
    }

    func toContinuationToken() -> String? {
        if self == NSFileProviderPage.initialPageSortedByDate as NSFileProviderPage ||
            self == NSFileProviderPage.initialPageSortedByName as NSFileProviderPage {
            return nil
        }
        if let retString = String(data: self.rawValue, encoding: .utf8), !retString.isEmpty {
            return retString
        }
        return nil
    }
}
