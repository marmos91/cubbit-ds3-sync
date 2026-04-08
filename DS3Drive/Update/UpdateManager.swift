#if os(macOS)
    import AppKit
    import DS3Lib
    import os.log
    import UserNotifications

    /// macOS-specific update manager that wraps `UpdateChecker` and adds channel-appropriate
    /// update actions. For direct-download, opens the GitHub release page (Sparkle integration
    /// can be layered on later). For Homebrew, copies the upgrade command to clipboard.
    @Observable
    @MainActor
    final class UpdateManager {
        private let logger = Logger(subsystem: LogSubsystem.app, category: LogCategory.app.rawValue)

        private let updateChecker: UpdateChecker

        /// Convenience accessors
        var updateAvailable: Bool {
            updateChecker.updateAvailable
        }
        var latestVersion: String? {
            updateChecker.latestVersion
        }
        var releaseURL: String? {
            updateChecker.releaseURL
        }
        var isChecking: Bool {
            updateChecker.isChecking
        }
        var channel: DistributionChannel {
            updateChecker.channel
        }
        var lastCheckDate: Date? {
            updateChecker.lastCheckDate
        }
        var lastResult: UpdateCheckResult? {
            updateChecker.lastResult
        }

        /// Toast message shown briefly after a channel-specific action.
        var toastMessage: String?

        init(updateChecker: UpdateChecker = UpdateChecker()) {
            self.updateChecker = updateChecker
        }

        /// Start periodic update checks. Call once at app launch.
        func startPeriodicChecks() {
            updateChecker.startPeriodicChecks()
        }

        /// Stop periodic update checks.
        func stopPeriodicChecks() {
            updateChecker.stopPeriodicChecks()
        }

        /// Manually check for updates.
        func checkForUpdates() async {
            await updateChecker.checkForUpdates()
        }

        /// Manually check for updates AND post a UNUserNotification with the
        /// result (Plan 05-15 Gap 26). Round 1 (Plan 05-10) only surfaced the
        /// result via an in-tray `.alert`, which the user never saw when the
        /// tray closed before the check returned. System notifications
        /// survive tray dismissal so the user always gets confirmation.
        func checkForUpdatesAndNotify() async {
            await updateChecker.checkForUpdates()
            await postUpdateCheckNotification(for: updateChecker.lastResult)
        }

        /// Posts a local system notification describing the result of a
        /// manual update check. Best-effort: failures are logged but do not
        /// crash the app.
        private func postUpdateCheckNotification(for result: UpdateCheckResult?) async {
            guard let result else { return }

            let content = UNMutableNotificationContent()

            switch result {
            case let .upToDate(version):
                content.title = NSLocalizedString(
                    "updates.notification.upToDateTitle",
                    value: "DS3 Drive is up to date",
                    comment: "Update check system notification — up to date title"
                )
                content.body = String(
                    format: NSLocalizedString(
                        "updates.notification.upToDateBody",
                        value: "You're running version %@, the latest available.",
                        comment: "Update check system notification — up to date body"
                    ),
                    version
                )

            case let .updateAvailable(version):
                content.title = NSLocalizedString(
                    "updates.notification.availableTitle",
                    value: "Update available",
                    comment: "Update check system notification — update available title"
                )
                content.body = String(
                    format: NSLocalizedString(
                        "updates.notification.availableBody",
                        value: "Version %@ is available. Open Preferences to install.",
                        comment: "Update check system notification — update available body"
                    ),
                    version
                )

            case let .failed(message):
                content.title = NSLocalizedString(
                    "updates.notification.failedTitle",
                    value: "Couldn't check for updates",
                    comment: "Update check system notification — failure title"
                )
                content.body = message
            }

            content.sound = .default

            let request = UNNotificationRequest(
                identifier: "io.cubbit.DS3Drive.updateCheck.\(UUID().uuidString)",
                content: content,
                trigger: nil
            )

            do {
                try await UNUserNotificationCenter.current().add(request)
                logger.info("Update check notification delivered")
            } catch {
                logger.error("Failed to deliver update check notification: \(error.localizedDescription)")
            }
        }

        /// Perform the channel-appropriate update action.
        func installUpdate() {
            switch channel {
            case .directDownload:
                guard let urlString = releaseURL, let url = URL(string: urlString) else { return }
                NSWorkspace.shared.open(url)

            case .homebrew:
                let command = "brew upgrade cubbit-ds3-drive"
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                toastMessage = "Copied: \(command)"
                Task {
                    try? await Task.sleep(for: .seconds(3))
                    toastMessage = nil
                }

            case .testFlight:
                if let url = URL(string: "itms-beta://") { NSWorkspace.shared.open(url) }

            case .appStore:
                if let url = URL(string: "macappstore://apps.apple.com") { NSWorkspace.shared.open(url) }
            }
        }

        /// Label text for the tray menu update item.
        var updateMenuTitle: String {
            if let version = latestVersion {
                return String(
                    format: NSLocalizedString(
                        "Update Available (%@)",
                        comment: "Tray menu update available with version"
                    ),
                    version
                )
            }
            return NSLocalizedString("Check for Updates", comment: "Tray menu check for updates")
        }
    }
#endif
