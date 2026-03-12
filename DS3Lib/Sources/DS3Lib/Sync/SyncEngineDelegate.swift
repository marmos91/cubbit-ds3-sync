import Foundation

/// Callback protocol for SyncEngine status events.
/// Implementors receive notifications when sync completes, enters error state, or recovers.
public protocol SyncEngineDelegate: AnyObject, Sendable {
    /// Called after a successful reconciliation cycle.
    func syncEngineDidComplete(driveId: UUID)

    /// Called when the engine enters error state (3+ consecutive failures).
    func syncEngineDidEnterErrorState(driveId: UUID, error: Error)

    /// Called when a successful reconciliation follows a previous failure, indicating recovery.
    func syncEngineDidRecoverFromError(driveId: UUID)
}
