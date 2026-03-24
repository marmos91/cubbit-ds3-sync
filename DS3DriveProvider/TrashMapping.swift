import Foundation
import DS3Lib

/// Thread-safe local mapping of trash keys to original keys.
/// Stored as a JSON file in the App Group container so it persists
/// across extension restarts. Avoids expensive S3 HEAD requests
/// in the TrashS3Enumerator.
actor TrashMapping {
    static let shared = TrashMapping()

    private var mapping: [String: TrashEntry] = [:]
    private var loaded = false

    struct TrashEntry: Codable {
        let originalKey: String
        let trashedAt: Date
        let size: Int64
    }

    private var fileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: DefaultSettings.appGroup)?
            .appendingPathComponent("trash-mapping.json")
    }

    /// Records a trash operation: trashKey → originalKey mapping.
    func record(trashKey: String, originalKey: String, size: Int64) {
        loadIfNeeded()
        mapping[trashKey] = TrashEntry(
            originalKey: originalKey,
            trashedAt: Date(),
            size: size
        )
        save()
    }

    /// Removes a mapping (after restore or permanent delete).
    func remove(trashKey: String) {
        loadIfNeeded()
        mapping.removeValue(forKey: trashKey)
        save()
    }

    /// Looks up the original key for a trash key.
    func originalKey(forTrashKey trashKey: String) -> String? {
        loadIfNeeded()
        return mapping[trashKey]?.originalKey
    }

    /// Gets the full entry for a trash key.
    func entry(forTrashKey trashKey: String) -> TrashEntry? {
        loadIfNeeded()
        return mapping[trashKey]
    }

    /// Removes all mappings (e.g., after emptying trash).
    func removeAll() {
        mapping.removeAll()
        save()
    }

    // MARK: - Persistence

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let url = fileURL, FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            mapping = try JSONDecoder().decode([String: TrashEntry].self, from: data)
        } catch {
            mapping = [:]
        }
    }

    private func save() {
        guard let url = fileURL else { return }
        do {
            let data = try JSONEncoder().encode(mapping)
            try data.write(to: url, options: .atomic)
        } catch {
            // Best effort — mapping will be rebuilt on next trash operation
        }
    }
}
