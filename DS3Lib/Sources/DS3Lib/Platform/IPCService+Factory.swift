import Foundation

/// Returns the platform-appropriate ``IPCService`` implementation.
///
/// On macOS this returns a ``MacOSIPCService`` backed by `DistributedNotificationCenter`.
/// On iOS this returns an ``IOSIPCService`` backed by Darwin notifications + App Group files.
public func makeDefaultIPCService() -> any IPCService {
    #if os(macOS)
        return MacOSIPCService()
    #elseif os(iOS)
        return IOSIPCService()
    #endif
}
