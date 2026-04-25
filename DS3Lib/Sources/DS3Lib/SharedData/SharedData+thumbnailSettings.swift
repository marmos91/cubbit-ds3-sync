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

    private func decodedAllThumbnailSettings(from url: URL) -> [String: ThumbnailSettings] {
        do {
            return try loadAllThumbnailSettings(from: url)
        } catch {
            // On read/decode failure, log and fall back to an empty dict so a
            // single corrupt file doesn't silently and permanently disable the
            // feature. Subsequent saveThumbnailSettings will rewrite from scratch.
            thumbnailSettingsLogger.error(
                "thumbnailSettings: load failed (\(error.localizedDescription, privacy: .public)) — defaulting to empty"
            )
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
