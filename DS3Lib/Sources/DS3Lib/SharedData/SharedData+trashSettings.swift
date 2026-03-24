import Foundation

/// Per-drive trash settings persisted in the App Group container.
public struct TrashSettings: Codable, Sendable {
    /// Whether trash is enabled for this drive. When disabled, deletes are permanent.
    public var enabled: Bool

    /// Number of days to retain trashed items before auto-purge. 0 means never auto-purge.
    public var retentionDays: Int

    public init(enabled: Bool = true, retentionDays: Int = DefaultSettings.Trash.defaultRetentionDays) {
        self.enabled = enabled
        self.retentionDays = retentionDays
    }
}

extension SharedData {
    /// Load trash settings for a specific drive.
    /// - Parameter driveId: The UUID of the drive.
    /// - Returns: The trash settings, or defaults if no file exists.
    public func loadTrashSettings(forDrive driveId: UUID) throws -> TrashSettings {
        let url = try trashSettingsURL()

        guard let allSettings = try? loadAllTrashSettings(from: url) else {
            return TrashSettings()
        }

        return allSettings[driveId.uuidString] ?? TrashSettings()
    }

    /// Save trash settings for a specific drive.
    /// - Parameters:
    ///   - driveId: The UUID of the drive.
    ///   - settings: The trash settings to persist.
    public func saveTrashSettings(forDrive driveId: UUID, settings: TrashSettings) throws {
        let url = try trashSettingsURL()

        var allSettings = (try? loadAllTrashSettings(from: url)) ?? [:]
        allSettings[driveId.uuidString] = settings

        let data = try JSONEncoder().encode(allSettings)
        try coordinatedWrite(data: data, to: url)
    }

    /// Check whether there is a pending empty-trash request for a given drive.
    /// - Parameter driveId: The UUID of the drive.
    /// - Returns: `true` if the flag file has an entry for this drive.
    public func hasEmptyTrashRequest(forDrive driveId: UUID) throws -> Bool {
        let url = try emptyTrashFlagURL()
        guard let flags = try? loadEmptyTrashFlags(from: url) else { return false }
        return flags[driveId.uuidString] == true
    }

    /// Request or clear an empty-trash operation for a specific drive.
    /// - Parameters:
    ///   - driveId: The UUID of the drive.
    ///   - requested: Whether to request (true) or clear (false) the flag.
    public func setEmptyTrashRequest(forDrive driveId: UUID, requested: Bool) throws {
        let url = try emptyTrashFlagURL()

        var flags = (try? loadEmptyTrashFlags(from: url)) ?? [:]

        flags[driveId.uuidString] = requested ? true : nil

        let data = try JSONEncoder().encode(flags)
        try coordinatedWrite(data: data, to: url)
    }

    // MARK: - Private Helpers

    private func trashSettingsURL() throws -> URL {
        try sharedContainerURL().appendingPathComponent(DefaultSettings.FileNames.trashSettingsFileName)
    }

    private func emptyTrashFlagURL() throws -> URL {
        try sharedContainerURL().appendingPathComponent(DefaultSettings.FileNames.emptyTrashFlagFileName)
    }

    private func loadAllTrashSettings(from url: URL) throws -> [String: TrashSettings] {
        try coordinatedRead(from: url) { data in
            try JSONDecoder().decode([String: TrashSettings].self, from: data)
        }
    }

    private func loadEmptyTrashFlags(from url: URL) throws -> [String: Bool] {
        try coordinatedRead(from: url) { data in
            try JSONDecoder().decode([String: Bool].self, from: data)
        }
    }
}
