#if os(macOS)
import AppKit
import DS3Lib
import os.log
@preconcurrency import UserNotifications

/// Posts a macOS system notification when a background update check finds a new version.
@MainActor
final class UpdateNotificationHandler {
    private let logger = Logger(subsystem: LogSubsystem.app, category: LogCategory.app.rawValue)
    private let updateManager: UpdateManager
    private var observationTask: Task<Void, Never>?

    /// Tracks the last version we notified about, so we don't spam.
    private var lastNotifiedVersion: String?

    static let updateCategoryIdentifier = "UPDATE_CATEGORY"
    static let openUpdateActionIdentifier = "OPEN_UPDATE"

    init(updateManager: UpdateManager) {
        self.updateManager = updateManager
        registerNotificationCategory()
        startObserving()
    }

    deinit {
        observationTask?.cancel()
    }

    private func registerNotificationCategory() {
        let openAction = UNNotificationAction(
            identifier: Self.openUpdateActionIdentifier,
            title: NSLocalizedString("View Update", comment: "Update notification action"),
            options: [.foreground]
        )

        let category = UNNotificationCategory(
            identifier: Self.updateCategoryIdentifier,
            actions: [openAction],
            intentIdentifiers: [],
            options: []
        )

        // Merge with existing categories (conflicts, etc.)
        Task {
            let center = UNUserNotificationCenter.current()
            var categories = await center.notificationCategories()
            categories.insert(category)
            center.setNotificationCategories(categories)
        }
    }

    private func startObserving() {
        // Poll updateManager state periodically (withObservationTracking doesn't work
        // well across actor boundaries, so we use a simple polling loop)
        observationTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self else { return }
                if self.updateManager.updateAvailable,
                   let version = self.updateManager.latestVersion,
                   version != self.lastNotifiedVersion {
                    self.lastNotifiedVersion = version
                    self.postNotification(version: version)
                }
            }
        }
    }

    private func postNotification(version: String) {
        let content = UNMutableNotificationContent()
        content.title = NSLocalizedString("Cubbit DS3 Drive", comment: "Update notification title")
        content.body = String(
            format: NSLocalizedString(
                "Version %@ is available. Click to update.",
                comment: "Update notification body"
            ),
            version
        )
        content.sound = .default
        content.categoryIdentifier = Self.updateCategoryIdentifier

        let request = UNNotificationRequest(
            identifier: "io.cubbit.DS3Drive.updateAvailable",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { [weak self] error in
            if let error {
                self?.logger.error("Failed to post update notification: \(error.localizedDescription)")
            }
        }
    }
}
#endif
