import Foundation
import os.log

extension SharedData {
    /// Errors that can occur when accessing shared data in the App Group container
    public enum SharedDataError: Error, LocalizedError {
        case cannotAccessAppGroup
        case apiKeyNotFound
        case ds3DriveNotFound
        case conversionError

        public var errorDescription: String? {
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

/// Shared data between DS3 Drive app and FileProvider extension.
/// Provides access to persisted state in the App Group container (JSON files).
/// Implemented as a singleton to ensure consistent access.
public class SharedData: @unchecked Sendable {
    private static let instance = SharedData()

    let logger = Logger(subsystem: LogSubsystem.app, category: LogCategory.metadata.rawValue)

    private init() {}

    /// Get shared data singleton instance.
    /// - Returns: the singleton instance of SharedData.
    public static func `default`() -> SharedData {
        return instance
    }
}
