import Foundation
import UserNotifications
import os.log
import DS3Lib

/// Listens for conflict IPC notifications from the File Provider extension
/// and presents macOS user notifications via UNUserNotificationCenter.
@MainActor
@Observable
final class ConflictNotificationHandler {
    private let logger = Logger(subsystem: LogSubsystem.app, category: LogCategory.sync.rawValue)

    /// Category identifier for conflict notifications (enables grouping)
    static let conflictCategoryIdentifier = "CONFLICT_CATEGORY"
    /// Action identifier for "Show in Finder"
    static let showInFinderActionIdentifier = "SHOW_IN_FINDER"

    /// Pending conflicts for batching (reset after delivery)
    private var pendingConflicts: [ConflictInfo] = []
    /// Debounce timer for batching
    private var batchTimer: Timer?
    /// Batch window: wait this long for more conflicts before showing notification
    private let batchDelay: TimeInterval = 2.0

    init() {
        registerNotificationCategory()
        startListening()
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
    }

    /// Request notification permission from the user (best-effort).
    func requestPermission() {
        Task { @MainActor in
            do {
                let granted = try await UNUserNotificationCenter.current().requestAuthorization(
                    options: [.alert, .sound, .badge]
                )
                logger.info("Notification permission granted: \(granted)")
            } catch {
                logger.error("Failed to request notification permission: \(error)")
            }
        }
    }

    // MARK: - Private

    /// Register the conflict notification category with "Show in Finder" action.
    private func registerNotificationCategory() {
        let showAction = UNNotificationAction(
            identifier: Self.showInFinderActionIdentifier,
            title: "Show in Finder",
            options: [.foreground]
        )

        let category = UNNotificationCategory(
            identifier: Self.conflictCategoryIdentifier,
            actions: [showAction],
            intentIdentifiers: [],
            options: []
        )

        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    /// Start listening for conflict IPC from the extension.
    private func startListening() {
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleConflictNotification(_:)),
            name: .conflictDetected,
            object: nil
        )
        logger.debug("ConflictNotificationHandler listening for conflict notifications")
    }

    @objc private func handleConflictNotification(_ notification: Notification) {
        guard let jsonString = notification.object as? String,
              let data = jsonString.data(using: .utf8),
              let info = try? JSONDecoder().decode(ConflictInfo.self, from: data) else {
            logger.error("Failed to decode conflict notification")
            return
        }

        logger.info("Received conflict notification for \(info.originalFilename, privacy: .public)")

        pendingConflicts.append(info)

        // Reset batch timer
        batchTimer?.invalidate()
        batchTimer = Timer.scheduledTimer(withTimeInterval: batchDelay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.deliverBatch()
            }
        }
    }

    /// Deliver batched conflict notifications.
    private func deliverBatch() {
        let conflicts = self.pendingConflicts
        self.pendingConflicts = []

        guard !conflicts.isEmpty else { return }

        if conflicts.count <= 3 {
            // Individual notifications for 1-3 conflicts
            for conflict in conflicts {
                showIndividualNotification(conflict)
            }
        } else {
            // Summary notification for more than 3
            showSummaryNotification(count: conflicts.count)
        }
    }

    private func showIndividualNotification(_ info: ConflictInfo) {
        let content = UNMutableNotificationContent()
        content.title = "Conflict detected"
        content.body = "\(info.originalFilename) \u{2014} Both versions saved."
        content.categoryIdentifier = Self.conflictCategoryIdentifier
        content.userInfo = ["conflictKey": info.conflictKey, "driveId": info.driveId.uuidString]
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil // Deliver immediately
        )

        UNUserNotificationCenter.current().add(request) { [weak self] error in
            if let error {
                self?.logger.error("Failed to show conflict notification: \(error)")
            }
        }
    }

    private func showSummaryNotification(count: Int) {
        let content = UNMutableNotificationContent()
        content.title = "Conflicts detected"
        content.body = "\(count) conflicts detected \u{2014} Click to view in Finder."
        content.categoryIdentifier = Self.conflictCategoryIdentifier
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "conflict-summary-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { [weak self] error in
            if let error {
                self?.logger.error("Failed to show conflict summary notification: \(error)")
            }
        }
    }
}
