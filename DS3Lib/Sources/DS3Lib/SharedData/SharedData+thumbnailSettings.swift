import Foundation
import os.log

private let thumbnailSettingsLogger = Logger(
    subsystem: LogSubsystem.app,
    category: LogCategory.thumbnail.rawValue
)

public struct ThumbnailSettings: Codable, Sendable {
    public var enabled: Bool

    public init(enabled: Bool = false) {
        self.enabled = enabled
    }
}

extension SharedData {
    public func loadThumbnailSettings(forDrive driveId: UUID) throws -> ThumbnailSettings {
        let url = try thumbnailSettingsURL()
        let allSettings = decodedAllThumbnailSettings(from: url)
        return allSettings[driveId.uuidString] ?? ThumbnailSettings()
    }

    public func saveThumbnailSettings(forDrive driveId: UUID, settings: ThumbnailSettings) throws {
        let url = try thumbnailSettingsURL()
        var allSettings = decodedAllThumbnailSettings(from: url)
        allSettings[driveId.uuidString] = settings

        let data = try JSONEncoder().encode(allSettings)
        try coordinatedWrite(data: data, to: url)
    }

    /// Returns true if a thumbnail-settings entry exists for this drive AND the
    /// underlying JSON file decodes successfully. False if the file is missing,
    /// corrupt, or contains no entry for `driveId` — all three cases trigger a
    /// re-check via the drive-setup wizard's `inspectThumbnailPrefix` call
    /// (Phase 11). Phase 13.2 Plan 07 deleted the launch-time `ThumbnailRollout`
    /// path (D-09); the wizard is now the sole rollout trigger.
    ///
    /// File-existence alone is insufficient: a corrupt JSON file would lock every
    /// drive into the persisted-disabled state forever (D-02's first-launch re-check
    /// would never re-run). Returning false on decode failure self-heals — the next
    /// rollout pass overwrites the corrupt file with a fresh per-drive verdict.
    /// Per Phase 13 D-02 + W3 fix (Plan 13-10).
    ///
    /// Uses the same coordinated read as `loadThumbnailSettings` (via
    /// `loadAllThumbnailSettings`) so it can't race with concurrent
    /// `saveThumbnailSettings` writes — a concern when multiple drives complete
    /// rollout simultaneously.
    public func hasThumbnailSettings(forDrive driveId: UUID) -> Bool {
        let url: URL
        do {
            url = try thumbnailSettingsURL()
        } catch {
            return false
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        do {
            let allSettings = try loadAllThumbnailSettings(from: url)
            return allSettings[driveId.uuidString] != nil
        } catch {
            // Corrupt or unreadable — caller treats this as never-written so the
            // rollout re-runs and overwrites the bad file with a fresh JSON.
            return false
        }
    }

    /// Internal/static testability seam for `hasThumbnailSettings`. Operates on
    /// any URL so SPM tests (which can't access the App Group container) can
    /// exercise the missing/corrupt/present cases against a temp file.
    /// **Test-only**: production code paths use the public instance method
    /// `hasThumbnailSettings(forDrive:)` which performs a coordinated read.
    /// This static seam intentionally bypasses `NSFileCoordinator` because tests
    /// run against temp-file URLs where file coordination is unavailable.
    /// Behavior matches `hasThumbnailSettings(forDrive:)` exactly:
    ///   • file missing → false
    ///   • file present but undecodable (corrupt JSON) → false (self-heal seam)
    ///   • file present, decodable, no entry for driveId → false
    ///   • file present, decodable, entry for driveId exists → true
    static func hasThumbnailSettings(forDrive driveId: UUID, atURL url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        do {
            let data = try Data(contentsOf: url)
            let allSettings = try JSONDecoder().decode([String: ThumbnailSettings].self, from: data)
            return allSettings[driveId.uuidString] != nil
        } catch {
            // Corrupt or unreadable — caller treats this as never-written so the
            // rollout re-runs and overwrites the bad file with a fresh JSON.
            return false
        }
    }

    private func decodedAllThumbnailSettings(from url: URL) -> [String: ThumbnailSettings] {
        do {
            return try loadAllThumbnailSettings(from: url)
        } catch {
            // First-run / never-saved is the common case; only log when the
            // file exists but is unreadable/corrupt so we don't spam logs on
            // every cold read.
            if FileManager.default.fileExists(atPath: url.path) {
                thumbnailSettingsLogger.error(
                    "thumbnailSettings: load failed (\(error.localizedDescription, privacy: .public)) — defaulting to empty"
                )
            }
            return [:]
        }
    }

    // MARK: - Private Helpers

    private func thumbnailSettingsURL() throws -> URL {
        try sharedContainerURL().appendingPathComponent(
            DefaultSettings.FileNames.thumbnailSettingsFileName
        )
    }

    private func loadAllThumbnailSettings(from url: URL) throws -> [String: ThumbnailSettings] {
        try coordinatedRead(from: url) { data in
            try JSONDecoder().decode([String: ThumbnailSettings].self, from: data)
        }
    }
}
