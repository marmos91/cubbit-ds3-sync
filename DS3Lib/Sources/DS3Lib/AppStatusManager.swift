import Foundation
import Observation
import os.log

/// Manages the global status of the app, displayed in the menu bar tray icon.
///
/// Enforces a minimum active duration: once the status becomes syncing/indexing,
/// it must remain active for at least `minActiveDuration` seconds before
/// transitioning to idle. This prevents the tray icon from flashing.
@Observable public final class AppStatusManager: @unchecked Sendable {
    private static let instance = AppStatusManager()

    @ObservationIgnored
    private let logger = Logger(subsystem: LogSubsystem.app, category: LogCategory.app.rawValue)

    /// Minimum time (seconds) the status must stay in syncing/indexing before
    /// it can transition to idle. Prevents rapid icon flashing.
    @ObservationIgnored
    private let minActiveDuration: TimeInterval = 3.0

    /// When the status last entered an active state (syncing/indexing).
    @ObservationIgnored
    private var lastActiveTime: Date?

    /// Timer for deferred idle transitions.
    @ObservationIgnored
    private var pendingIdleTimer: Timer?

    /// The current app status (idle, syncing, error, offline, info)
    public private(set) var status: AppStatus = .idle

    private init() {}

    /// The default singleton instance of the AppStatusManager.
    /// - Returns: the default instance of the AppStatusManager.
    public static func `default`() -> AppStatusManager {
        return instance
    }

    /// Updates the global app status.
    ///
    /// Active states (syncing/indexing) are applied immediately and reset the
    /// minimum-active timer. Idle transitions are held until `minActiveDuration`
    /// has elapsed since the last active state, preventing tray icon flicker.
    public func setStatus(_ newStatus: AppStatus) {
        pendingIdleTimer?.invalidate()
        pendingIdleTimer = nil

        switch newStatus {
        case .syncing, .indexing:
            lastActiveTime = Date()
            status = newStatus
        case .idle:
            guard let activeTime = lastActiveTime else {
                status = .idle
                return
            }
            let elapsed = Date().timeIntervalSince(activeTime)
            let remaining = minActiveDuration - elapsed
            if remaining <= 0 {
                status = .idle
                lastActiveTime = nil
            } else {
                pendingIdleTimer = Timer.scheduledTimer(withTimeInterval: remaining, repeats: false) { [weak self] _ in
                    guard let self else { return }
                    self.status = .idle
                    self.lastActiveTime = nil
                }
            }
        default:
            // error, offline, info, paused — apply immediately
            lastActiveTime = nil
            status = newStatus
        }
    }
}
