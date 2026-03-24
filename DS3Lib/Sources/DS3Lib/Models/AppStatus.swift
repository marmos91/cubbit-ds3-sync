import Foundation

/// The status of the app. It is used to display the current status of the app in the tray menu UI.
public enum AppStatus: String, Sendable {
    /// The app is idle. It is not performing any operation.
    case idle

    /// The app is synchronizing (performing transfers)
    case syncing

    /// The app is indexing (scanning/listing remote files)
    case indexing

    /// The app is in error state. The user should perform an action to fix the error.
    case error

    /// The app is offline. It is not connected to the internet.
    case offline

    /// The app is displaying some information to the user (like a CTA).
    case info

    /// The app is paused. No new transfers will be started.
    case paused

    public func toString() -> String {
        switch self {
        case .syncing:
            NSLocalizedString("Synchronizing", comment: "Synchronizing status")
        case .indexing:
            NSLocalizedString("Indexing", comment: "Indexing status")
        case .idle:
            NSLocalizedString("Idle", comment: "Idle status")
        case .error:
            NSLocalizedString("Error", comment: "Error status")
        case .offline:
            NSLocalizedString("Offline", comment: "Offline status")
        case .info:
            NSLocalizedString("Info", comment: "Info status")
        case .paused:
            NSLocalizedString("Paused", comment: "Paused status")
        }
    }
}
