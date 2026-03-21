import Foundation
import os.log

/// Cross-platform version checker that polls GitHub Releases for newer versions.
/// Does NOT depend on Sparkle — pure version checking only.
/// The macOS `UpdateManager` wraps this and adds channel-specific update actions.
@Observable
@MainActor
public final class UpdateChecker {
    private let logger = Logger(subsystem: LogSubsystem.app, category: LogCategory.app.rawValue)

    /// Whether a newer version is available.
    public private(set) var updateAvailable: Bool = false
    /// The latest version tag (e.g. "2.1.0").
    public private(set) var latestVersion: String?
    /// URL to the GitHub release page.
    public private(set) var releaseURL: String?
    /// Release notes body (markdown).
    public private(set) var releaseNotes: String?
    /// The detected distribution channel.
    public let channel: DistributionChannel
    /// Whether a check is currently in progress.
    public private(set) var isChecking: Bool = false
    /// Timestamp of the last successful check.
    public private(set) var lastCheckDate: Date?

    /// nonisolated(unsafe) because `deinit` is nonisolated in Swift 6 but Task.cancel() is thread-safe.
    nonisolated(unsafe) private var periodicTask: Task<Void, Never>?
    private let userDefaults: UserDefaults?

    public init(channel: DistributionChannel = .detect()) {
        self.channel = channel
        let defaults = UserDefaults(suiteName: DefaultSettings.appGroup)
        self.userDefaults = defaults
        self.lastCheckDate = defaults?.object(forKey: DefaultSettings.UserDefaultsKeys.lastUpdateCheck) as? Date
    }

    deinit {
        periodicTask?.cancel()
    }

    /// Start periodic background checks (every 4 hours). Safe to call multiple times.
    public func startPeriodicChecks() {
        guard periodicTask == nil else { return }
        periodicTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkForUpdates()
                try? await Task.sleep(for: .seconds(DefaultSettings.Update.checkIntervalSeconds))
            }
        }
    }

    /// Stop periodic background checks.
    public func stopPeriodicChecks() {
        periodicTask?.cancel()
        periodicTask = nil
    }

    /// Manually trigger an update check.
    public func checkForUpdates() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }

        do {
            let release = try await fetchLatestRelease()
            let remoteVersion = String(release.tagName.trimmingPrefix("v"))

            let currentVersion = DefaultSettings.appVersion

            let isNewer = Self.isNewerVersion(remoteVersion, than: currentVersion)
            updateAvailable = isNewer
            latestVersion = isNewer ? remoteVersion : nil
            releaseURL = isNewer ? release.htmlURL : nil
            releaseNotes = isNewer ? release.body : nil

            if isNewer {
                logger.info("Update available: \(remoteVersion, privacy: .public) (current: \(currentVersion, privacy: .public))")
            }

            lastCheckDate = Date()
            userDefaults?.set(lastCheckDate, forKey: DefaultSettings.UserDefaultsKeys.lastUpdateCheck)
        } catch {
            logger.error("Update check failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - GitHub API

    private struct GitHubRelease: Decodable {
        let tagName: String
        let htmlURL: String
        let body: String?

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case body
        }
    }

    private func fetchLatestRelease() async throws -> GitHubRelease {
        guard let url = URL(string: DefaultSettings.Update.gitHubReleasesURL) else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }

        return try JSONDecoder().decode(GitHubRelease.self, from: data)
    }

    // MARK: - Semantic Version Comparison

    /// Returns true if `remote` is semantically newer than `current`.
    static func isNewerVersion(_ remote: String, than current: String) -> Bool {
        let remoteParts = remote.split(separator: ".").compactMap { Int($0) }
        let currentParts = current.split(separator: ".").compactMap { Int($0) }

        let maxLength = max(remoteParts.count, currentParts.count)
        for index in 0..<maxLength {
            let remoteComponent = index < remoteParts.count ? remoteParts[index] : 0
            let currentComponent = index < currentParts.count ? currentParts[index] : 0
            if remoteComponent > currentComponent { return true }
            if remoteComponent < currentComponent { return false }
        }
        return false
    }
}
