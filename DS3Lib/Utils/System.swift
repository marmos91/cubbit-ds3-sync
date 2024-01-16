import Foundation

@discardableResult
public func throwErrno<T: SignedInteger>(_ block: () throws -> T) throws -> T {
    return try throwErrnoOrError { _ in return try block() }
}

@discardableResult
func throwErrnoOrError<T: SignedInteger>(_ block: (/* errorOrNil */ inout Error?) throws -> T) throws -> T {
    var errorOrNil: Error?
    
    let ret = try block(&errorOrNil)
    
    if let error = errorOrNil {
        throw error
    }
    
    if ret < 0 {
        if errno != 0 {
            let errorCode = POSIXErrorCode(rawValue: errno)
            
            if let errorCode = errorCode {
                throw POSIXError(errorCode)
            } else {
                throw POSIXError(.EINVAL)
            }
        } else {
            preconditionFailure("call to block failed with \(ret) but errno is not set")
        }
    }
    return ret
}

func realHomeDirectory() -> URL? {
    guard let pw = getpwuid(getuid()) else { return nil }
    return URL(fileURLWithFileSystemRepresentation: pw.pointee.pw_dir, isDirectory: true, relativeTo: nil)
}
