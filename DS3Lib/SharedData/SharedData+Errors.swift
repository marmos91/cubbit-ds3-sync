import Foundation

extension SharedData {
    enum SharedDataError: Error {
        case cannotAccessAppGroup
        case notFound
        case apiKeyNotFound
        case ds3DriveNotFound
        case conversionError
    }
}
