import Foundation

/// Generates S3 keys for conflict copies following the pattern:
/// `"filename (Conflict on [hostname] [YYYY-MM-DD HH-MM-SS]).ext"`
public enum ConflictNaming: Sendable {
    /// Creates a conflict copy S3 key from the original key, hostname, and date.
    ///
    /// - Parameters:
    ///   - originalKey: The original S3 object key (e.g. `"photos/report.pdf"`)
    ///   - hostname: The local machine hostname (e.g. `"amaterasu"`)
    ///   - date: The date/time of the conflict
    /// - Returns: A new S3 key with conflict suffix inserted before the extension
    public static func conflictKey(originalKey: String, hostname: String, date: Date) -> String {
        let dateStr = Self.formatDate(date)

        // Split by "/" to separate parent path from filename
        let components = originalKey.split(separator: "/", omittingEmptySubsequences: false)
        let parentPath: String
        let filename: String

        if components.count > 1 {
            parentPath = components.dropLast().joined(separator: "/") + "/"
            filename = String(components.last!)
        } else {
            parentPath = ""
            filename = originalKey
        }

        // Split filename into name and extension at the last dot
        // Hidden files (starting with ".") with no other dot are treated as having no extension
        let name: String
        let ext: String

        if let dotIndex = filename.lastIndex(of: ".") {
            let nameBeforeDot = String(filename[filename.startIndex..<dotIndex])
            if nameBeforeDot.isEmpty {
                // Hidden file like ".gitignore" -- treat entire thing as name, no extension
                name = filename
                ext = ""
            } else {
                name = nameBeforeDot
                ext = "." + String(filename[filename.index(after: dotIndex)...])
            }
        } else {
            name = filename
            ext = ""
        }

        return "\(parentPath)\(name) (Conflict on \(hostname) \(dateStr))\(ext)"
    }

    private static func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }
}
