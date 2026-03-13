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
        let dateStr = formatDate(date)

        // Separate parent path from filename
        let nsKey = originalKey as NSString
        let parentPath = nsKey.deletingLastPathComponent
        let filename = nsKey.lastPathComponent

        // Split filename into name and extension
        // Hidden files (starting with ".") with no other dot are treated as having no extension
        let nsFilename = filename as NSString
        let rawExt = nsFilename.pathExtension
        let isHiddenWithoutExt = filename.hasPrefix(".") && nsFilename.deletingPathExtension.isEmpty

        let name: String
        let ext: String

        if rawExt.isEmpty || isHiddenWithoutExt {
            name = filename
            ext = ""
        } else {
            name = nsFilename.deletingPathExtension
            ext = rawExt
        }

        let suffix = " (Conflict on \(hostname) \(dateStr))"
        let newFilename = ext.isEmpty ? "\(name)\(suffix)" : "\(name)\(suffix).\(ext)"

        if parentPath.isEmpty || parentPath == "." {
            return newFilename
        }

        return parentPath + "/\(newFilename)"
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    private static func formatDate(_ date: Date) -> String {
        dateFormatter.string(from: date)
    }
}
