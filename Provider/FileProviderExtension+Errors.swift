import Foundation
import SotoS3
import FileProvider

// TODO: Improve this
enum FileProviderExtensionError: Error {
    case disabled
    case notImplemented
    case skipped
    case unableToOpenFile
    case s3ItemParseFailed
    case fatal
    case parseError
    case fileNotFound
    
    func toPresentableError() -> NSError {
        switch self {
        case FileProviderExtensionError.disabled:
            return NSError(domain: NSFileProviderErrorDomain, code: NSURLErrorResourceUnavailable, userInfo: [NSLocalizedDescriptionKey: "This feature is not supported"])
        case FileProviderExtensionError.notImplemented:
            return NSError(domain: NSFileProviderErrorDomain, code: NSFeatureUnsupportedError, userInfo: [NSLocalizedDescriptionKey: "This feature is not implemented"])
        case FileProviderExtensionError.skipped:
            return NSError(domain: NSFileProviderErrorDomain, code: NSUserCancelledError, userInfo: [NSLocalizedDescriptionKey: "This item was skipped"])
        case FileProviderExtensionError.unableToOpenFile:
            return NSError(domain: NSFileProviderErrorDomain, code: NSFileReadUnknownError, userInfo: [NSLocalizedDescriptionKey: "Unable to open file"])
        case FileProviderExtensionError.s3ItemParseFailed:
            return NSError(domain: NSFileProviderErrorDomain, code: NSFileReadUnknownError, userInfo: [NSLocalizedDescriptionKey: "Unable to parse S3 item"])
        case FileProviderExtensionError.fatal:
            return NSError(domain: NSFileProviderErrorDomain, code: NSFileReadUnknownError, userInfo: [NSLocalizedDescriptionKey: "Fatal error"])
        case FileProviderExtensionError.parseError:
            return NSError(domain: NSFileProviderErrorDomain, code: NSFileReadUnknownError, userInfo: [NSLocalizedDescriptionKey: "Parse error"])
        case FileProviderExtensionError.fileNotFound:
            return NSError(domain: NSFileProviderErrorDomain, code: NSFileReadNoSuchFileError, userInfo: [NSLocalizedDescriptionKey: "File not found"])
        }
    }
}

extension S3ErrorType {
    func toPresentableError() -> NSError {
        return NSError(domain: NSFileProviderErrorDomain, code: NSFileReadUnknownError, userInfo: nil)
    }
}
