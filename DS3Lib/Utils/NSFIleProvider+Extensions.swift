import Foundation
import FileProvider

// Extend NSFileProviderSyncAnchor to handle timestamps
extension NSFileProviderSyncAnchor {
    init(_ date: Date) {
        self.init(
            rawValue: withUnsafeBytes(of: date) {
                Data($0)
            }
        )
    }
    
    func toDate() -> Date {
        var ret = Date()
        
        _ = withUnsafeMutableBytes(of: &ret) { ptr in
            self.rawValue.copyBytes(to: ptr)
        }
        
        return ret
    }
}

// Extend NSFileProviderPage to handle S3 continuation tokens
extension NSFileProviderPage {
    init(_ continuationToken: String) {
        self.init(
            withUnsafeBytes(of: continuationToken) {
                Data($0)
            }
        )
    }

    func toContinuationToken() -> String? {
        if self == NSFileProviderPage.initialPageSortedByDate as NSFileProviderPage ||
            self == NSFileProviderPage.initialPageSortedByName as NSFileProviderPage {
            return nil
        }
        var ret: String = ""
        _ = withUnsafeMutableBytes(of: &ret) { ptr in
            self.rawValue.copyBytes(to: ptr)
        }
        return ret
    }
}
