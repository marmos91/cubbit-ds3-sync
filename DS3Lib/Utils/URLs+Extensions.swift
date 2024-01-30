import Foundation

/// Returns a unique temporary file URL in the given temporary folder. The filename is a UUID generated randomly.
/// - Parameter temporaryURL: the temporary folder URL to use
/// - Returns: the temporary file URL
func temporaryFileURL(
    withTemporaryFolder temporaryURL: URL
) throws -> URL {
    let temporaryFileURL = temporaryURL.appendingPathComponent(UUID().uuidString)
    
    if !FileManager.default.fileExists(atPath: temporaryFileURL.path) {
        FileManager.default.createFile(atPath: temporaryFileURL.path, contents: nil)
    }
    
    return temporaryFileURL
}
