import Foundation

enum FileProviderExtensionError: Error {
    case disabled
    case notImplemented
    case skipped
    case unableToOpenFile
    case s3ItemParseFailed
    case fatal
    case parseError
    case fileNotFound
}
