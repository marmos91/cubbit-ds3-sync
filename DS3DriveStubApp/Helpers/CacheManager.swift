#if os(iOS)
import Foundation
import DS3Lib

/// Utility for calculating and clearing the App Group shared container cache.
enum CacheManager {
    /// Calculates the total size of all files in the App Group shared container.
    /// - Returns: Total size in bytes.
    static func calculateCacheSize() async -> Int64 {
        await Task.detached {
            _calculateCacheSizeSync()
        }.value
    }

    private static func _calculateCacheSizeSync() -> Int64 {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: DefaultSettings.appGroup
        ) else { return 0 }

        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: containerURL,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var totalSize: Int64 = 0

        for case let fileURL as URL in enumerator {
            guard let resourceValues = try? fileURL.resourceValues(
                forKeys: [.fileSizeKey, .isRegularFileKey]
            ),
                resourceValues.isRegularFile == true,
                let fileSize = resourceValues.fileSize
            else { continue }

            totalSize += Int64(fileSize)
        }

        return totalSize
    }

    /// Formats a byte count into a human-readable string.
    /// - Parameter bytes: The number of bytes.
    /// - Returns: A formatted string (e.g. "12.3 GB", "45 MB", "128 KB").
    static func formatSize(_ bytes: Int64) -> String {
        if bytes >= 1_073_741_824 {
            let gb = Double(bytes) / 1_073_741_824.0
            return String(format: "%.1f GB", gb)
        } else if bytes >= 1_048_576 {
            let mb = bytes / 1_048_576
            return "\(mb) MB"
        } else if bytes >= 1024 {
            let kb = bytes / 1024
            return "\(kb) KB"
        } else {
            return "0 KB"
        }
    }

    /// Removes all files in the App Group shared container, preserving
    /// the directory structure and essential subdirectories (e.g. `ipc/`).
    static func clearCache() async throws {
        try await Task.detached {
            try _clearCacheSync()
        }.value
    }

    private static func _clearCacheSync() throws {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: DefaultSettings.appGroup
        ) else { return }

        let fm = FileManager.default

        // Directories to preserve (essential for IPC and runtime)
        let preservedDirectories: Set<String> = ["ipc", "Library"]

        let contents = try fm.contentsOfDirectory(
            at: containerURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        )

        for itemURL in contents {
            let resourceValues = try? itemURL.resourceValues(forKeys: [.isDirectoryKey])
            let isDirectory = resourceValues?.isDirectory ?? false
            let name = itemURL.lastPathComponent

            // Skip preserved directories
            if isDirectory && preservedDirectories.contains(name) {
                continue
            }

            try fm.removeItem(at: itemURL)
        }
    }
}
#endif
