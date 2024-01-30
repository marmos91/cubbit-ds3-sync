import Foundation
import os.log

extension SharedData {
    enum SharedDataError: Error, LocalizedError {
        case cannotAccessAppGroup
        case apiKeyNotFound
        case ds3DriveNotFound
        case conversionError
        
        var errorDescription: String? {
            switch self {
            case .cannotAccessAppGroup:
                return NSLocalizedString("Cannot access shared app group.", comment: "Cannot access shared app group.")
            case .apiKeyNotFound:
                return NSLocalizedString("API key not found.", comment: "")
            case .conversionError:
                return NSLocalizedString("Conversion error.", comment: "")
            case .ds3DriveNotFound:
                return NSLocalizedString("DS3 drive not found.", comment: "")
            }
        }
    }
}

/// Shared data between DS3Sync app and FileProvider extension. It is used to get access to common resources. It is implemented like singleton.
class SharedData {
    private static var instance: SharedData?
    
    let logger = Logger(subsystem: "io.cubbit.CubbitDS3Sync.ds3Lib", category: "SharedData")
    
    private init() {}
    
    /// Get shared data instance.
    static func `default`() -> SharedData {
        if instance == nil {
            instance = SharedData()
        }
        
        return instance!
    }
}
