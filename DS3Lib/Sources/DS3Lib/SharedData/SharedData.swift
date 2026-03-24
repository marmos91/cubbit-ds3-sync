import Foundation
import os.log

extension SharedData {
    /// Errors that can occur when accessing shared data in the App Group container
    public enum SharedDataError: Error, LocalizedError {
        case cannotAccessAppGroup
        case apiKeyNotFound
        case ds3DriveNotFound
        case conversionError

        public var errorDescription: String? {
            switch self {
            case .cannotAccessAppGroup:
                return NSLocalizedString("Cannot access shared app group.", comment: "Cannot access shared app group.")
            case .apiKeyNotFound:
                return NSLocalizedString("API key not found.", comment: "")
            case .conversionError:
                return NSLocalizedString("Conversion error.", comment: "")
            case .ds3DriveNotFound:
                return NSLocalizedString("DS3 drive not found.", comment: "")
            }
        }
    }
}

/// Shared data between DS3 Drive app and FileProvider extension.
/// Provides access to persisted state in the App Group container (JSON files).
/// Implemented as a singleton to ensure consistent access.
public class SharedData: @unchecked Sendable {
    private static let instance = SharedData()

    let logger = Logger(subsystem: LogSubsystem.app, category: LogCategory.metadata.rawValue)

    private init() {
        // Singleton
    }

    /// Get shared data singleton instance.
    /// - Returns: the singleton instance of SharedData.
    public static func `default`() -> SharedData {
        return instance
    }

    // MARK: - App Group Container

    func sharedContainerURL() throws -> URL {
        guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: DefaultSettings.appGroup) else {
            throw SharedDataError.cannotAccessAppGroup
        }
        return url
    }

    // MARK: - Coordinated File I/O

    func coordinatedWrite(data: Data, to fileURL: URL) throws {
        let coordinator = NSFileCoordinator()
        var coordinatorError: NSError?
        var writeError: Error?

        coordinator.coordinate(writingItemAt: fileURL, options: .forReplacing, error: &coordinatorError) { url in
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                writeError = error
            }
        }

        if let coordinatorError { throw coordinatorError }
        if let writeError { throw writeError }
    }

    func coordinatedWriteString(_ string: String, to fileURL: URL) throws {
        let coordinator = NSFileCoordinator()
        var coordinatorError: NSError?
        var writeError: Error?

        coordinator.coordinate(writingItemAt: fileURL, options: .forReplacing, error: &coordinatorError) { url in
            do {
                try string.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                writeError = error
            }
        }

        if let coordinatorError { throw coordinatorError }
        if let writeError { throw writeError }
    }

    func coordinatedRead<T>(from fileURL: URL, decode: (Data) throws -> T) throws -> T {
        let coordinator = NSFileCoordinator()
        var coordinatorError: NSError?
        var result: Result<T, Error>?

        coordinator.coordinate(readingItemAt: fileURL, options: [], error: &coordinatorError) { url in
            do {
                let data = try Data(contentsOf: url)
                result = .success(try decode(data))
            } catch {
                result = .failure(error)
            }
        }

        if let coordinatorError { throw coordinatorError }

        switch result {
        case .success(let value):
            return value
        case .failure(let error):
            throw error
        case .none:
            throw SharedDataError.cannotAccessAppGroup
        }
    }

    func coordinatedDelete(at fileURL: URL) throws {
        let coordinator = NSFileCoordinator()
        var coordinatorError: NSError?
        var deleteError: Error?

        coordinator.coordinate(writingItemAt: fileURL, options: .forDeleting, error: &coordinatorError) { url in
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                deleteError = error
            }
        }

        if let coordinatorError { throw coordinatorError }
        if let deleteError { throw deleteError }
    }

    func coordinatedReadString(from fileURL: URL) throws -> String {
        let coordinator = NSFileCoordinator()
        var coordinatorError: NSError?
        var result: Result<String, Error>?

        coordinator.coordinate(readingItemAt: fileURL, options: [], error: &coordinatorError) { url in
            do {
                result = .success(try String(contentsOf: url, encoding: .utf8))
            } catch {
                result = .failure(error)
            }
        }

        if let coordinatorError { throw coordinatorError }

        switch result {
        case .success(let value):
            return value
        case .failure(let error):
            throw error
        case .none:
            throw SharedDataError.cannotAccessAppGroup
        }
    }
}
