import Foundation

enum AppStatus: String {
    case idle
    case syncing
    case error
    case offline
    case info
    
    func toString() -> String {
        switch self {
        case .syncing:
            return NSLocalizedString("Synchronizing", comment: "Synchronizing status")
        case .idle:
            return NSLocalizedString("Idle", comment: "Idle status")
        case .error:
            return NSLocalizedString("Error", comment: "Error status")
        case .offline:
            return NSLocalizedString("Offline", comment: "Offline status")
        case .info:
            return NSLocalizedString("Info", comment: "Info status")
        }
    }
}
