import Foundation

func temporaryDirectoryURL() -> URL {
    return FileManager.default.temporaryDirectory
}

func temporaryFileURL(withTemporaryFolder temporaryURL: URL) -> URL {
    let temporaryFileURL = temporaryURL.appendingPathComponent(UUID().uuidString)
    
    if !FileManager.default.fileExists(atPath: temporaryFileURL.path) {
        FileManager.default.createFile(atPath: temporaryFileURL.path, contents: nil)
    }
    
    return temporaryFileURL
}

extension URL {
    // Gets the specified extended attribute value for the file at the URL.
    public func xattr(_ xattrName: String) throws -> Data? {
        let valueLen: ssize_t
        
        do {
            valueLen = try throwErrno { getxattr(self.path, xattrName, nil, 0, 0, 0) }
        } catch POSIXError.ENOATTR {
            return nil
        }
        
        var value = Data(capacity: valueLen)

        value.count = valueLen
        
        _ = try value.withUnsafeMutableBytes { valuePtr in
            try throwErrno { getxattr(self.path, xattrName, valuePtr.bindMemory(to: Int8.self).baseAddress, valuePtr.count, 0, 0) }
        }
        
        return value
    }

    public func set(xattr value: Data, for xattrName: String) throws {
        _ = try value.withUnsafeBytes { valuePtr in
            try throwErrno { setxattr(self.path, xattrName, valuePtr.bindMemory(to: Int8.self).baseAddress, valuePtr.count, 0, 0) }
        }
    }
}
