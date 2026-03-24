#if os(macOS)
    import AppKit
    import DS3Lib
    import os.log

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
